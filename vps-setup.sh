#!/bin/bash

set -e

export GIT_BRANCH="main"
export GIT_REPO="igroza/xray-vps-setup"
export XRAY_VERSION="26.10.31"

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Install idn
apt-get update
apt-get install idn sudo dnsutils wamerican -y

# Select install mode
echo "What do you want to install?"
echo "  1) xray (standalone)"
echo "  2) marzban (panel)"
echo "  3) marzban-node (node for existing panel)"
read -ep "Enter choice [1/2/3]: "$'\n' install_choice

export INSTALL_MODE="xray"
case "$install_choice" in
  2) export INSTALL_MODE="marzban" ;;
  3) export INSTALL_MODE="node" ;;
esac

# Read domain input
read -ep "Enter your domain:"$'\n' input_domain

export VLESS_DOMAIN=$(echo $input_domain | idn)

SERVER_IPS=($(hostname -I))

RESOLVED_IP=$(dig +short $VLESS_DOMAIN | tail -n1)

if [ -z "$RESOLVED_IP" ]; then
  echo "Warning: Domain has no DNS record"
  read -ep "Are you sure? That domain has no DNS record. If you didn't add that you will have to restart xray and angie by yourself [y/N]"$'\n' prompt_response
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

# URL-encoded remark for the share link: "🏴‍☠️ <domain>"
# (%F0%9F%8F%B4%E2%80%8D%E2%98%A0%EF%B8%8F is the 🏴‍☠️ emoji, %20 space)
export XRAY_REMARK_ENC="%F0%9F%8F%B4%E2%80%8D%E2%98%A0%EF%B8%8F%20$VLESS_DOMAIN"

if [[ "$INSTALL_MODE" == "node" ]]; then
  read -ep "Enter marzban panel domain (e.g. panel.example.com):"$'\n' PANEL_DOMAIN
  export PANEL_DOMAIN
  read -ep "Enter panel admin username:"$'\n' PANEL_USER
  export PANEL_USER
  read -s -ep "Enter panel admin password:"$'\n' PANEL_PASS
  export PANEL_PASS
  echo
fi

if [[ "$INSTALL_MODE" == "marzban" ]]; then
  marzban_input="y"
else
  marzban_input="n"
fi

export TELEGRAM_API_TOKEN=""
export TELEGRAM_ADMIN_ID=""
if [[ "$INSTALL_MODE" == "marzban" ]]; then
  read -ep "Do you want to setup a Telegram bot for Marzban? [y/N] "$'\n' configure_tg_bot
  if [[ ${configure_tg_bot,,} == "y" ]]; then
    read -ep "Enter your Telegram bot token:"$'\n' input_telegram_api_token
    export TELEGRAM_API_TOKEN=$(echo "$input_telegram_api_token" | tr -d '[:space:]')
    read -ep "Enter your Telegram user id (use @userinfobot):"$'\n' input_telegram_admin_id
    export TELEGRAM_ADMIN_ID=$(echo "$input_telegram_admin_id" | tr -d '[:space:]')
  fi
fi

# Xray ports: XHTTP+REALITY on $XRAY_PORT (443 recommended: xray-core >= 26.3.27 warns that
# non-443 REALITY ports get the IP blocked easily), TCP+Vision+REALITY on $VISION_PORT.
# 80 is Angie's ACME/redirect listener, 4123 the local Angie REALITY target.
export VISION_PORT=8443
read -ep "Enter xray port. Default 443, can't use ports: 80, 4123 and $VISION_PORT:"$'\n' input_xray_port
while [[ -n "$input_xray_port" && ( "$input_xray_port" -eq "80" || "$input_xray_port" -eq "4123" || "$input_xray_port" -eq "$VISION_PORT" ) ]]; do
  read -ep "No, xray can't use $input_xray_port as port, write again:"$'\n' input_xray_port
done
export XRAY_PORT=${input_xray_port:-443}
# ":port" for URLs when not on 443
export XRAY_PORT_SUFFIX=""
if [[ "$XRAY_PORT" != "443" ]]; then
  export XRAY_PORT_SUFFIX=":$XRAY_PORT"
fi

read -ep "Do you want to create a user to connect to server as non-root and forbid root access? Do this on first run only. [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  # Read SSH port
  read -ep "Enter SSH port. Default 22, can't use ports: 80, $XRAY_PORT, $VISION_PORT and 4123:"$'\n' input_ssh_port

  while [[ -n "$input_ssh_port" && ( "$input_ssh_port" -eq "80" || "$input_ssh_port" -eq "$XRAY_PORT" || "$input_ssh_port" -eq "$VISION_PORT" || "$input_ssh_port" -eq "4123" ) ]]; do
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

configure_warp_input="n"
if [[ "$INSTALL_MODE" != "node" ]]; then
  read -ep "Do you want to install WARP and use it on russian websites? [y/N] "$'\n' configure_warp_input
  if [[ ${configure_warp_input,,} == "y" ]]; then
    if ! curl -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
      echo "Warp can't be used"
      configure_warp_input="n"
    fi
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

# Download the pinned Xray-core release into $1 (used by marzban and node)
xray_core_download() {
  apt install zip unzip -y
  mkdir -p "$1"
  if [[ "$ARCH" == "amd64" ]]; then
    wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/Xray-linux-64.zip
  elif [[ "$ARCH" == "arm64" ]]; then
    wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/v$XRAY_VERSION/Xray-linux-arm64-v8a.zip
  else
    echo "Unsupported architecture: $ARCH"
    exit 1
  fi
  unzip -qo /tmp/xray.zip -d "$1"
  rm -f /tmp/xray.zip
}

# Generate values for XRay
export SSH_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}
if [[ "$INSTALL_MODE" != "node" ]]; then
  # xray >= 25.4.30 prints "PrivateKey:", newer builds print "Password (PublicKey):"
  # instead of "Public key:", so match by label and take the last field
  export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:$XRAY_VERSION x25519 | grep -i '^PrivateKey' | awk '{print $NF}')
  export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:$XRAY_VERSION x25519 -i $XRAY_PIK | grep -iE '^(Password|Public key)' | awk '{print $NF}')
  # several shortIds so different clients don't share one; Marzban picks one per link
  export XRAY_SID=$(openssl rand -hex 8)
  export XRAY_SID2=$(openssl rand -hex 4)
  export XRAY_SID3=$(openssl rand -hex 6)
  export XHTTP_PATH=$(openssl rand -hex 8)
  export XRAY_UUID=$(docker run --rm ghcr.io/xtls/xray-core:$XRAY_VERSION uuid)

  if [[ -z "$XRAY_PIK" || -z "$XRAY_PBK" || -z "$XRAY_UUID" ]]; then
    echo "Error: failed to generate Reality keypair or UUID"
    exit 1
  fi
fi

# Install marzban
xray_setup() {
  mkdir -p /opt/xray-vps-setup
  cd /opt/xray-vps-setup
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/confluence" | envsubst > ./index.html
  if [[ "${marzban_input,,}" == "y" ]]; then
    mkdir -p /opt/xray-vps-setup/marzban
    export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
    export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 42; echo)
    export MARZBAN_PATH=$(openssl rand -hex 21)
    export MARZBAN_SUB_PATH=$(openssl rand -hex 21)
    # Marzban's image bundles an older Xray core; run the pinned release instead
    # (mounted at /code/xray-core, XRAY_EXECUTABLE_PATH in marzban/.env points at it)
    xray_core_download /opt/xray-vps-setup/xray-core
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose-marzban | envsubst > ./docker-compose.yml
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/marzban | envsubst > ./marzban/.env
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/angie-marzban" | envsubst '$VLESS_DOMAIN $XRAY_PORT_SUFFIX $MARZBAN_SUB_PATH' > ./angie.conf
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray" | envsubst > ./marzban/xray_config.json
  else
    mkdir -p /opt/xray-vps-setup/xray
    wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose-xray | envsubst > ./docker-compose.yml
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray" | envsubst > ./xray/config.json
    wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/angie" | envsubst '$VLESS_DOMAIN $XRAY_PORT_SUFFIX' > ./angie.conf
  fi
}

node_setup() {
  mkdir -p /opt/xray-vps-setup
  cd /opt/xray-vps-setup
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/confluence" | envsubst > ./index.html
  xray_core_download /opt/xray-vps-setup/xray-core
  # Placeholder - will be replaced with panel cert by node_api_setup
  touch ./ssl_client_cert.pem
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/compose-node" | envsubst > ./docker-compose.yml
  wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/angie" | envsubst '$VLESS_DOMAIN $XRAY_PORT_SUFFIX' > ./angie.conf
}

node_api_setup() {
  echo "Connecting to panel at https://$PANEL_DOMAIN..."
  TOKEN=$(curl -sf -X POST "https://$PANEL_DOMAIN/api/admin/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$PANEL_USER" \
    --data-urlencode "password=$PANEL_PASS" \
    | yq '.access_token')

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Failed to authenticate with panel. Check credentials and panel availability."
    exit 1
  fi

  echo "Fetching SSL client certificate from panel..."
  CERT_HTTP=$(curl -s -o /tmp/node_settings.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/node/settings" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$CERT_HTTP" != "200" ]]; then
    echo "Failed to fetch node settings (HTTP $CERT_HTTP):"
    cat /tmp/node_settings.json
    exit 1
  fi
  python3 -c "import json,sys; print(json.load(open('/tmp/node_settings.json'))['certificate'], end='')" \
    > /opt/xray-vps-setup/ssl_client_cert.pem

  NODE_IP=$(hostname -I | awk '{print $1}')
  NODE_NAME=$(hostname)

  echo "Creating node '$NODE_NAME' ($NODE_IP) on panel..."
  NODE_HTTP=$(curl -s -o /tmp/node_response.json -w "%{http_code}" \
    -X POST "https://$PANEL_DOMAIN/api/node" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$NODE_NAME\",\"address\":\"$NODE_IP\",\"port\":62001,\"api_port\":62002,\"add_as_new_host\":false}" || echo "000")
  if [[ "$NODE_HTTP" == "200" ]]; then
    NODE_ID=$(cat /tmp/node_response.json | yq '.id')
    echo "Node created with ID: $NODE_ID"
  elif [[ "$NODE_HTTP" == "409" ]]; then
    echo "Node already exists on panel, reusing..."
    NODES_HTTP=$(curl -s -o /tmp/nodes_list.json -w "%{http_code}" \
      "https://$PANEL_DOMAIN/api/nodes" \
      -H "Authorization: Bearer $TOKEN" || echo "000")
    if [[ "$NODES_HTTP" != "200" ]]; then
      echo "Failed to fetch nodes list (HTTP $NODES_HTTP):"
      cat /tmp/nodes_list.json
      exit 1
    fi
    NODE_ID=$(python3 -c "import json,sys; nodes=json.load(open('/tmp/nodes_list.json')); print(next(str(n['id']) for n in nodes if n['address']=='$NODE_IP'))")
    echo "Existing node ID: $NODE_ID"
  else
    echo "Failed to create node (HTTP $NODE_HTTP):"
    cat /tmp/node_response.json
    exit 1
  fi

  echo "Updating xray config serverNames with node domain..."
  CONFIG_HTTP=$(curl -s -o /tmp/xray_config.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/core/config" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$CONFIG_HTTP" != "200" ]]; then
    echo "Failed to fetch xray config (HTTP $CONFIG_HTTP):"
    cat /tmp/xray_config.json
    exit 1
  fi

  export NODE_DOMAIN="$VLESS_DOMAIN"
  cat > /tmp/update_servernames.py << 'PYEOF'
import json, os
with open('/tmp/xray_config.json') as f:
    config = json.load(f)
node_domain = os.environ['NODE_DOMAIN']
for inbound in config.get('inbounds', []):
    stream = inbound.get('streamSettings', {})
    reality = stream.get('realitySettings', {})
    if 'serverNames' in reality and node_domain not in reality['serverNames']:
        reality['serverNames'].append(node_domain)
print(json.dumps(config))
PYEOF
  python3 /tmp/update_servernames.py > /tmp/xray_config_updated.json \
    || { echo "Failed to process xray config JSON"; exit 1; }
  curl -s -o /dev/null \
    -X PUT "https://$PANEL_DOMAIN/api/core/config" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @/tmp/xray_config_updated.json || true
  echo "serverNames updated."

  echo "Fetching inbounds and current hosts..."
  INBOUNDS_HTTP=$(curl -s -o /tmp/marzban_inbounds.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/inbounds" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$INBOUNDS_HTTP" != "200" ]]; then
    echo "Failed to fetch inbounds (HTTP $INBOUNDS_HTTP):"
    cat /tmp/marzban_inbounds.json
    exit 1
  fi
  HOSTS_HTTP=$(curl -s -o /tmp/marzban_hosts.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/hosts" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$HOSTS_HTTP" != "200" ]]; then
    echo "Failed to fetch hosts (HTTP $HOSTS_HTTP):"
    cat /tmp/marzban_hosts.json
    exit 1
  fi

  export HOST_NODE_NAME="$NODE_NAME"
  export HOST_PANEL_USER="$PANEL_USER"
  cat > /tmp/update_hosts.py << 'PYEOF'
import json, os
with open('/tmp/marzban_hosts.json') as f:
    hosts = json.load(f)
with open('/tmp/marzban_inbounds.json') as f:
    inbounds = json.load(f)
node_domain = os.environ['NODE_DOMAIN']
node_name = os.environ['HOST_NODE_NAME']
panel_user = os.environ['HOST_PANEL_USER']
inbound_info = {}
for protocol, inbound_list in inbounds.items():
    for inbound in inbound_list:
        tag = inbound.get('tag', '')
        network = inbound.get('network', 'tcp')
        inbound_info[tag] = {'protocol': protocol, 'network': network}
for inbound_tag, host_list in hosts.items():
    info = inbound_info.get(inbound_tag, {})
    protocol = info.get('protocol', inbound_tag)
    transport = info.get('network', 'tcp')
    remark = f'🏴‍☠️ {node_domain} | {{USERNAME}}'
    host_list.append({
        'remark': remark,
        'address': node_domain,
        'port': None,
        'sni': node_domain,
        'host': None,
        'path': None,
        'security': 'inbound_default',
        'alpn': '',
        'fingerprint': 'firefox',
        'allowinsecure': None,
        'is_disabled': None,
        'mux_enable': None,
        'fragment_setting': None,
        'noise_setting': None,
        'random_user_agent': None,
        'use_sni_as_host': None,
    })
print(json.dumps(hosts))
PYEOF
  python3 /tmp/update_hosts.py > /tmp/marzban_hosts_updated.json \
    || { echo "Failed to process hosts JSON"; exit 1; }
  curl -s -o /dev/null \
    -X PUT "https://$PANEL_DOMAIN/api/hosts" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @/tmp/marzban_hosts_updated.json || true
  echo "Panel hosts updated."

  echo "Panel configuration complete!"
}

if [[ "$INSTALL_MODE" == "node" ]]; then
  node_setup
else
  xray_setup
fi

sshd_edit() {
  wget -qO- https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/00-disable-password | envsubst > /etc/ssh/sshd_config.d/00-disable-password.conf
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
apt-get install iptables-persistent netfilter-persistent -y

edit_iptables_node() {
  PANEL_IP=$(dig +short $PANEL_DOMAIN | tail -n1)
  iptables -A INPUT -s $PANEL_IP -p tcp -m tcp --dport 62001 -j ACCEPT
  iptables -A INPUT -s $PANEL_IP -p tcp -m tcp --dport 62002 -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 62001 -j REJECT --reject-with tcp-reset
  iptables -A INPUT -p tcp -m tcp --dport 62002 -j REJECT --reject-with tcp-reset
}

# Configure iptables
edit_iptables() {
  iptables -A INPUT -p icmp -j ACCEPT
  iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
  iptables -A INPUT -p tcp -m state --state NEW -m tcp --dport $SSH_PORT -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport $XRAY_PORT -j ACCEPT
  iptables -A INPUT -p tcp -m tcp --dport $VISION_PORT -j ACCEPT
  iptables -A INPUT -i lo -j ACCEPT
  iptables -A OUTPUT -o lo -j ACCEPT
  iptables -P INPUT DROP
}
if [[ "$INSTALL_MODE" == "node" ]]; then
  edit_iptables_node
fi
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  add_user
  sshd_edit
  edit_iptables
fi
netfilter-persistent save

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

block_ru_routing() {
  if [[ "${marzban_input,,}" == "y" ]]; then
    local cfg="/opt/xray-vps-setup/marzban/xray_config.json"
  else
    local cfg="/opt/xray-vps-setup/xray/config.json"
  fi
  yq eval \
  '.routing.rules += {"outboundTag": "block", "ip": ["geoip:ru"], "domain": ["geosite:category-ru", "regexp:.*\\.ru$", "regexp:.*\\.su$", "regexp:.*\\.xn--p1ai$"]}' \
  -i "$cfg"
}

end_script() {
  if [[ "$INSTALL_MODE" != "node" ]]; then
    if [[ ${configure_warp_input,,} == "y" ]]; then
      warp_install
    else
      block_ru_routing
    fi
  fi

  if [[ "$INSTALL_MODE" == "node" ]]; then
    node_api_setup
  fi

  docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

  if [[ "$INSTALL_MODE" == "marzban" ]]; then
    echo "Waiting for marzban to start..."
    sleep 5
    if docker exec marzban marzban-cli admin import-from-env; then
      # admin now lives in the DB; Marzban itself discourages keeping SUDO_* in .env
      sed -i '/^SUDO_USERNAME\|^SUDO_PASSWORD/d' /opt/xray-vps-setup/marzban/.env
    else
      echo "Warning: admin import failed - run 'docker exec marzban marzban-cli admin import-from-env' manually"
    fi

    # Marzban creates the default host ("🚀 Marz ({USERNAME}) ...") with address {SERVER_IP};
    # point it at the domain and name it "🏴‍☠️ <domain> | <marzban username>".
    # Angie only serves the panel on the Reality port, so talk to Marzban directly on 127.0.0.1:8000.
    echo "Updating panel default host with domain $VLESS_DOMAIN..."
    PANEL_API="http://127.0.0.1:8000"
    PANEL_TOKEN=""
    for _ in $(seq 1 30); do
      PANEL_TOKEN=$(curl -sf -X POST "$PANEL_API/api/admin/token" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "username=$MARZBAN_USER" \
        --data-urlencode "password=$MARZBAN_PASS" \
        | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")
      if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then break; fi
      sleep 2
    done
    if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then
      PHOSTS_HTTP=$(curl -s -o /tmp/panel_hosts.json -w "%{http_code}" \
        "$PANEL_API/api/hosts" \
        -H "Authorization: Bearer $PANEL_TOKEN" || echo "000")
      if [[ "$PHOSTS_HTTP" == "200" ]]; then
        export PANEL_HOST_DOMAIN="$VLESS_DOMAIN"
        python3 << 'PYEOF' > /tmp/panel_hosts_updated.json
import json, os
with open('/tmp/panel_hosts.json') as f:
    hosts = json.load(f)
domain = os.environ['PANEL_HOST_DOMAIN']
for tag, host_list in hosts.items():
    for host in host_list:
        # XHTTP host first in the subscription (resilience), Vision marked ⚡ (speed)
        suffix = ' ⚡' if 'VISION' in tag.upper() else ''
        host['remark'] = f'🏴‍☠️ {domain}{suffix} | {{USERNAME}}'
        host['address'] = domain
        host['sni'] = domain
        host['fingerprint'] = 'firefox'
        host['mux_enable'] = False
print(json.dumps(hosts))
PYEOF
        curl -s -o /dev/null \
          -X PUT "$PANEL_API/api/hosts" \
          -H "Authorization: Bearer $PANEL_TOKEN" \
          -H "Content-Type: application/json" \
          -d @/tmp/panel_hosts_updated.json || true
        rm -f /tmp/panel_hosts.json /tmp/panel_hosts_updated.json
        echo "Panel host updated."
      else
        echo "Warning: could not fetch panel hosts (HTTP $PHOSTS_HTTP) - update address/SNI manually"
      fi
    else
      echo "Warning: could not authenticate to panel API - update default host address/SNI to $VLESS_DOMAIN manually"
    fi
  fi

  if [[ "$INSTALL_MODE" == "node" ]]; then
    final_msg="Marzban node installed!
Node: $(hostname)
Node domain: $VLESS_DOMAIN
Panel: https://$PANEL_DOMAIN
Node service port: 62001
    "
  elif [[ "${marzban_input,,}" == "y" ]]; then
    final_msg="Marzban is managed through the Telegram bot. The web dashboard is NOT exposed to the internet;
to open it, tunnel: ssh -L 8000:127.0.0.1:8000 <user>@$VLESS_DOMAIN  then visit http://127.0.0.1:8000/$MARZBAN_PATH/
User: $MARZBAN_USER
Password: $MARZBAN_PASS
Subscription base: https://$VLESS_DOMAIN$XRAY_PORT_SUFFIX/$MARZBAN_SUB_PATH/
    "
  else
    xray_config=$(wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/xray_outbound" | envsubst)
    singbox_config=$(wget -qO- "https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/sing_box_outbound" | envsubst)

    final_msg="Clipboard string format (XHTTP + REALITY, primary):
vless://$XRAY_UUID@$VLESS_DOMAIN:$XRAY_PORT?type=xhttp&path=%2F$XHTTP_PATH&mode=stream-one&security=reality&pbk=$XRAY_PBK&fp=firefox&sni=$VLESS_DOMAIN&sid=$XRAY_SID&spx=%2F&encryption=none#$XRAY_REMARK_ENC

Clipboard string format (TCP + Vision + REALITY, fastest):
vless://$XRAY_UUID@$VLESS_DOMAIN:$VISION_PORT?type=tcp&security=reality&pbk=$XRAY_PBK&fp=firefox&sni=$VLESS_DOMAIN&sid=$XRAY_SID&spx=%2F&flow=xtls-rprx-vision&encryption=none#$XRAY_REMARK_ENC%20%E2%9A%A1

XRay outbound config (XHTTP):
$xray_config

Sing-box outbound config (Vision; sing-box has no XHTTP):
$singbox_config

Plain data:
PBK: $XRAY_PBK, SID: $XRAY_SID, UUID: $XRAY_UUID
    "
  fi

  # the xray image was only needed for key generation in the marzban variant
  if [[ "${marzban_input,,}" == "y" ]]; then
    docker rmi ghcr.io/xtls/xray-core:$XRAY_VERSION > /dev/null 2>&1 || true
  fi

  clear
  echo "$final_msg"
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
  fi
}

end_script
set +e
