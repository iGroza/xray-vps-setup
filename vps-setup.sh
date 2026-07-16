#!/bin/bash

set -e

export GIT_BRANCH="main"
export GIT_REPO="igroza/xray-vps-setup"
export XRAY_VERSION="26.6.27"

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Install idn 
apt-get update
apt-get install idn sudo dnsutils -y 

# Read domain input
read -ep "Enter your domain:"$'\n' input_domain

export VLESS_DOMAIN=$(echo $input_domain | idn)

SERVER_IPS=($(hostname -I))

RESOLVED_IP=$(dig +short $VLESS_DOMAIN | tail -n1)

if [ -z "$RESOLVED_IP" ]; then
  echo "Warning: Domain has no DNS record"
  read -ep "Are you sure? That domain has no DNS record. If you didn't add that you will have to restart xray and caddy by yourself [y/N]"$'\n' prompt_response
  if [[ "$prompt_response" =~ ^([yY])$ ]]; then
    echo "Ok, proceeding without DNS verification"
  else 
    echo "Come back later"
    exit 1
  fi
else
  MATCH_FOUND=false
  for server_ip in "${SERVER_IPS[@]}"; do
    if [ "$RESOLVED_IP" == "$server_ip" ]; then
      MATCH_FOUND=true
      break
    fi
  done
  
  if [ "$MATCH_FOUND" = true ]; then
    echo "✓ DNS record points to this server ($RESOLVED_IP)"
  else
    echo "Warning: DNS record exists but points to different IP"
    echo "  Domain resolves to: $RESOLVED_IP"
    echo "  This server's IPs: ${SERVER_IPS[*]}"
    read -ep "Continue anyway? [y/N]"$'\n' prompt_response
    if [[ "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Ok, proceeding"
    else 
      echo "Come back later"
      exit 1
    fi
  fi
fi

# URL-encoded remark for the share link: "🇩🇪 <domain>"
# (%F0%9F%87%A9%F0%9F%87%AA is the 🇩🇪 emoji, %20 space)
export XRAY_REMARK_ENC="%F0%9F%87%A9%F0%9F%87%AA%20$VLESS_DOMAIN"

read -ep "Do you want to install marzban? [y/N] "$'\n' marzban_input

if [[ "${marzban_input,,}" == "y" ]]; then
  read -ep "Do you want setup telegram bot for Marzban? [y/N] "$'\n' configure_tg_bot
  if [[ ${configure_tg_bot,,} == "y" ]]; then
    # Read bot token input
    read -ep "Enter your telegram bot token:"$'\n' input_telegram_api_token
    export TELEGRAM_API_TOKEN=$(echo $input_telegram_api_token | idn)

    # Read user id input
    read -ep "Enter your telegram user id, use @userinfobot:"$'\n' input_telegram_admin_id
    export TELEGRAM_ADMIN_ID=$(echo $input_telegram_admin_id | idn)
  fi
fi

# Custom xray port
read -ep "Enter your custom xray port. Default 433, can't use ports: 80, 4123:"$'\n' input_xray_port

while [[ "$input_xray_port" -eq "80" || "input_xray_port" -eq "4123" ]]; do
  read -ep "No, ssh can't use $input_xray_port as port, write again:"$'\n' input_xray_port
done

if [[ -n "$input_xray_port" ]]; then
  export XRAY_PORT=$input_xray_port
else
  export XRAY_PORT=433
fi

read -ep "Do you want to configure server security? Do this on first run only. [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  # Read SSH port
  read -ep "Enter SSH port. Default 22, can't use ports: 80, $input_xray_port and 4123:"$'\n' input_ssh_port

  while [[ "$input_ssh_port" -eq "80" || "$input_ssh_port" -eq "$input_xray_port" || "$input_ssh_port" -eq "4123" ]]; do
    read -ep "No, ssh can't use $input_ssh_port as port, write again:"$'\n' input_ssh_port
  done
  # Read SSH Pubkey
  read -ep "Enter SSH public key:"$'\n' input_ssh_pbk
  echo "$input_ssh_pbk" > ./test_pbk
  ssh-keygen -l -f ./test_pbk
  PBK_STATUS=$(echo $?)
  if [ "$PBK_STATUS" -eq 255 ]; then
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    exit
  fi
  rm ./test_pbk
fi

read -ep "Do you want to install WARP and use it on russian websites? [y/N] "$'\n' configure_warp_input
if [[ ${configure_warp_input,,} == "y" ]]; then
  if ! curl -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
    echo "Warp can't be used"
    configure_warp_input="n"
  fi
fi

# Check congestion protocol
if sysctl net.ipv4.tcp_congestion_control | grep bbr; then
    echo "BBR is already used"
else
    echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
    echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
    sysctl -p > /dev/null
    echo "Enabled BBR"
fi

export ARCH=$(dpkg --print-architecture)

yq_install() {
  # Remove Python yq if installed to avoid conflicts
  pip3 uninstall yq -y 2>/dev/null || true
  apt-get remove yq -y 2>/dev/null || true
  
  wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$ARCH -O /usr/bin/yq && chmod +x /usr/bin/yq
  
  # Verify we have the correct yq (mikefarah's version)
  if ! /usr/bin/yq --version 2>&1 | grep -q "mikefarah"; then
    echo "Error: Wrong yq version installed"
    exit 1
  fi
}

yq_install

docker_install() {
  curl -fsSL https://get.docker.com | sh
}

if ! command -v docker 2>&1 >/dev/null; then
    docker_install
fi

# Generate values for XRay
export SSH_USER=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 8; echo)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}
export ROOT_LOGIN="yes"
export IP_CADDY=$(hostname -I | cut -d' ' -f1)
export CADDY_BASIC_AUTH=$(docker run --rm caddy caddy hash-password --plaintext $SSH_USER_PASS)
# xray >= 25.4.30 prints "PrivateKey:", newer builds print "Password (PublicKey):"
# instead of "Public key:", so match by label and take the last field
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:$XRAY_VERSION x25519 | grep -i '^PrivateKey' | awk '{print $NF}')
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:$XRAY_VERSION x25519 -i $XRAY_PIK | grep -iE '^(Password|Public key)' | awk '{print $NF}')
export XRAY_SID=$(openssl rand -hex 8)
export XRAY_UUID=$(docker run --rm ghcr.io/xtls/xray-core:$XRAY_VERSION uuid)

if [[ -z "$XRAY_PIK" || -z "$XRAY_PBK" || -z "$XRAY_UUID" ]]; then
  echo "Error: failed to generate Reality keypair or UUID"
  exit 1
fi
export XRAY_CFG="/usr/local/etc/xray/config.json"

# Install marzban
xray_setup() {
  mkdir -p /opt/xray-vps-setup
  cd /opt/xray-vps-setup
  if [[ "${marzban_input,,}" == "y" ]]; then
    export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 42; echo)
    export MARZBAN_PATH=$(openssl rand -hex 21)
    export MARZBAN_SUB_PATH=$(openssl rand -hex 21)
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose | envsubst > ./docker-compose.yml
    yq eval \
    '.services.marzban.image = "gozargah/marzban:v0.8.4" |
     .services.marzban.container_name = "marzban" |
     .services.marzban.restart = "always" |
     .services.marzban.env_file = "./marzban/.env" |
     .services.marzban.network_mode = "host" | 
     .services.marzban.volumes[0] = "./marzban_lib:/var/lib/marzban" | 
     .services.marzban.volumes[1] = "./marzban/xray_config.json:/code/xray_config.json" |
     .services.marzban.volumes[2] = "./marzban/templates:/var/lib/marzban/templates" |
     .services.caddy.volumes[2] = "./marzban_lib:/run/marzban"' -i /opt/xray-vps-setup/docker-compose.yml
    mkdir -p marzban caddy
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/marzban | envsubst > ./marzban/.env
    mkdir -p /opt/xray-vps-setup/marzban/templates/home
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/confluence_page | envsubst > ./marzban/templates/home/index.html
    export CADDY_REVERSE="reverse_proxy * unix//run/marzban/marzban.socket"
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/caddy" | envsubst > ./caddy/Caddyfile
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray" | envsubst > ./marzban/xray_config.json
    # Marzban's image bundles an older Xray core; extract the pinned $XRAY_VERSION
    # binary into its volume and point XRAY_EXECUTABLE_PATH (in marzban/.env) at it.
    # Reality config carries an explicit publicKey so Marzban never parses `xray x25519`
    # output (its v0.8.4 parser breaks on the newer "Password (PublicKey)" format).
    mkdir -p /opt/xray-vps-setup/marzban_lib/xray-core
    XRAY_CID=$(docker create ghcr.io/xtls/xray-core:$XRAY_VERSION)
    docker cp $XRAY_CID:/usr/local/bin/xray /opt/xray-vps-setup/marzban_lib/xray-core/xray
    docker rm $XRAY_CID > /dev/null
    chmod +x /opt/xray-vps-setup/marzban_lib/xray-core/xray
  else
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose | envsubst > ./docker-compose.yml
    mkdir -p /opt/xray-vps-setup/caddy/templates
    yq eval \
    '.services.xray.image = "ghcr.io/xtls/xray-core:" + strenv(XRAY_VERSION) |
    .services.xray.container_name = "xray" |
    .services.xray.user = "root" |
    .services.xray.command = "run -c /etc/xray/config.json" |
    .services.xray.restart = "always" | 
    .services.xray.network_mode = "host" | 
    .services.caddy.volumes[2] = "./caddy/templates:/srv" |
    .services.xray.volumes[0] = "./xray:/etc/xray"' -i /opt/xray-vps-setup/docker-compose.yml
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/confluence_page | envsubst > ./caddy/templates/index.html
    export CADDY_REVERSE="root * /srv
    file_server"
    mkdir -p xray caddy
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray" | envsubst > ./xray/config.json
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/caddy" | envsubst > ./caddy/Caddyfile
  fi
}

xray_setup

sshd_edit() {
  grep -r Port /etc/ssh -l | xargs -n 1 sed -i -e "/Port /c\Port $SSH_PORT"
  grep -r PasswordAuthentication /etc/ssh -l | xargs -n 1 sed -i -e "/PasswordAuthentication /c\PasswordAuthentication no"
  grep -r PermitRootLogin /etc/ssh -l | xargs -n 1 sed -i -e "/PermitRootLogin /c\PermitRootLogin no"
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  useradd $SSH_USER -s /bin/bash
  usermod -aG sudo $SSH_USER
  echo $SSH_USER:$SSH_USER_PASS | chpasswd
  mkdir -p /home/$SSH_USER/.ssh
  touch /home/$SSH_USER/.ssh/authorized_keys
  echo $input_ssh_pbk >> /home/$SSH_USER/.ssh/authorized_keys
  chmod 700 /home/$SSH_USER/.ssh/
  chmod 600 /home/$SSH_USER/.ssh/authorized_keys
  chown $SSH_USER:$SSH_USER -R /home/$SSH_USER
  usermod -aG docker $SSH_USER
}

debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF

# Configure iptables
edit_iptables() {
  apt-get install iptables-persistent netfilter-persistent -y
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport $SSH_PORT -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport $XRAY_PORT -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -P INPUT DROP
  netfilter-persistent save
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  add_user
  sshd_edit
  edit_iptables
fi

# WARP Install function
warp_install() {
  apt install gpg -y
  echo "If this fails then warp won't be added to routing and everything will work without it"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  apt update 
  apt install cloudflare-warp -y
  
  echo "y" | warp-cli registration new
  export TRY_WARP=$(echo $?)
  if [[ $TRY_WARP != 0 ]]; then
    echo "Couldn't connect to WARP"
    exit 0
  else
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect
    if [[ "${marzban_input,,}" == "y" ]]; then
      export XRAY_CONFIG_WARP="/opt/xray-vps-setup/marzban/xray_config.json"
    else
      export XRAY_CONFIG_WARP="/opt/xray-vps-setup/xray/config.json"
    fi
    yq eval \
    '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' \
    -i $XRAY_CONFIG_WARP
    yq eval \
    '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.xn--$", "regexp:.*\\.ru$", "regexp:.*\\.su$"]}' \
    -i $XRAY_CONFIG_WARP
    docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
  fi
}

end_script() {
  if [[ ${configure_warp_input,,} == "y" ]]; then
    warp_install
  fi
  
  if [[ "${marzban_input,,}" == "y" ]]; then
    docker run -v /opt/xray-vps-setup/caddy/Caddyfile:/opt/xray-vps-setup/Caddyfile --rm caddy caddy fmt --overwrite /opt/xray-vps-setup/Caddyfile
    docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

    # Default config name shown in client apps: "🇩🇪 <domain> | <marzban username>".
    # Marzban creates the default host ("🚀 Marz ({USERNAME}) ...") on first start,
    # rename it once the row appears, then restart so the in-memory hosts reload.
    cat > /opt/xray-vps-setup/marzban_lib/set_default_host.py <<'PYEOF'
import sqlite3, sys
remark = sys.argv[1]
con = sqlite3.connect('/var/lib/marzban/db.sqlite3')
cur = con.cursor()
try:
    cur.execute("SELECT COUNT(*) FROM hosts WHERE remark = ?", (remark,))
    if cur.fetchone()[0]:
        print(1)
    else:
        cur.execute("UPDATE hosts SET remark = ?, fingerprint = 'firefox' WHERE remark LIKE '%Marz%'", (remark,))
        con.commit()
        print(1 if cur.rowcount else 0)
except sqlite3.OperationalError:
    print(0)
PYEOF
    echo "Waiting for Marzban to create the default host..."
    REMARK_SET=0
    for _ in $(seq 1 60); do
      REMARK_SET=$(docker exec marzban python3 /var/lib/marzban/set_default_host.py "🇩🇪 $VLESS_DOMAIN | {USERNAME}" 2>/dev/null || echo 0)
      if [ "$REMARK_SET" = "1" ]; then break; fi
      sleep 2
    done
    rm -f /opt/xray-vps-setup/marzban_lib/set_default_host.py
    if [ "$REMARK_SET" = "1" ]; then
      docker restart marzban > /dev/null
    else
      echo "Warning: couldn't rename the default host, set it in the panel: Host Settings"
    fi

    final_msg="Marzban panel location: https://$VLESS_DOMAIN:$XRAY_PORT/$MARZBAN_PATH/
User: xray_admin
Password: $MARZBAN_PASS
    "
    if [[ ${configure_ssh_input,,} == "y" ]]; then
      echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
    fi
  else
    docker run -v /opt/xray-vps-setup/caddy/Caddyfile:/opt/xray-vps-setup/Caddyfile --rm caddy caddy fmt --overwrite /opt/xray-vps-setup/Caddyfile
    docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

    xray_config=$(wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray_outbound" | envsubst)
    singbox_config=$(wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/sing_box_outbound" | envsubst)

    final_msg="Clipboard string format:
vless://$XRAY_UUID@$VLESS_DOMAIN:$XRAY_PORT?type=grpc&serviceName=api.v1.telemetry.EventStream&mode=gun&security=reality&pbk=$XRAY_PBK&fp=firefox&sni=$VLESS_DOMAIN&sid=$XRAY_SID&encryption=none#$XRAY_REMARK_ENC

XRay outbound config:
$xray_config

Sing-box outbound config:
$singbox_config

Plain data:
PBK: $XRAY_PBK, SID: $XRAY_SID, UUID: $XRAY_UUID
    "    
  fi

  # caddy:latest was only used for hash-password/fmt (compose runs caddy:2.9);
  # the pinned xray image stays in use by the xray variant, drop it for marzban only
  if [[ "${marzban_input,,}" == "y" ]]; then
    docker rmi ghcr.io/xtls/xray-core:$XRAY_VERSION caddy:latest || true
  else
    docker rmi caddy:latest || true
  fi
  clear
  echo "$final_msg"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  fi
}

end_script
set +e
