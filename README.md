# xray-vps-setup

---

Fork includes:

- Xray listens on `433` by default (configurable at install time, `443` works too) to dodge port-based RU blocks
- VLESS-gRPC-REALITY transport instead of TCP-Vision, `firefox` uTLS fingerprint
- Telegram bot for Marzban (token + admin id asked at install time)
- Xray-core pinned to `26.6.27` for both the standalone container and the Marzban core
- Default client config name: `🏴‍☠️ <domain> | <marzban username>` (Marzban) / `🏴‍☠️ <domain>` (plain xray)
- Tested on [cherryservers.com](https://www.cherryservers.com/pricing/virtual-servers) (Ubuntu 22.04)

> [!NOTE]
> Начиная с Xray-core 26.3.27 ядро пишет предупреждение, что REALITY на не-443 порту легче детектится и «easily gets the server IP blocked». Порт 433 остаётся дефолтом форка, но при установке можно указать 443, если он свободен.

---

VLESS со своим доменом. А что еще нужно для счастья?  

> [!IMPORTANT]
> Дайте секс

В данном варианте VLESS слушает на 433 (или выбранном порту) и принимате все запросы, делая запрос на локальный Angie(форк nginx) только для сертификатов. В таком варианте задержка будет меньше, чем в варианте с Caddy/NGINX перед VLESS, где происходит множество лишних запросов. 
## Скрипт

- Установит Xray/Marzban на ваш выбор. Для маскировки страницы используется [Conflunce](https://github.com/Jolymmiles/confluence-marzban-home)
- На ваше усмотрение настроит:
- - Iptables, запретив все подключения, кроме SSH, 80 и порта Xray.
- - Создаст пользователя для подключения, запретив вход от рута
- - Добавит этому пользователю ключ для SSH, запретив вход по паролю
- - Настроит WARP для ру-сайтов.  
```bash
tmux
bash <(wget -qO- https://raw.githubusercontent.com/iGroza/xray-vps-setup/refs/heads/main/vps-setup.sh)
```

## Плейбук

[Ansible-galaxy](https://galaxy.ansible.com/ui/standalone/roles/Akiyamov/xray-vps-setup/install/)
```yaml
- name: Setup vps 
  hosts: some_host
  roles:
    - Akiyamov.xray-vps-setup  
  vars:
    domain: example.com # домен, уровень неважен
    setup_variant: marzban # marzban or xray
    setup_warp: false # true or false
    xray_port: 433 # опционально, порт VLESS Reality (дефолт 433)
    xray_version: "26.6.27" # опционально, версия Xray-core
    TELEGRAM_API_TOKEN: "" # опционально, токен бота для Marzban
    TELEGRAM_ADMIN_ID: "" # опционально, telegram id админа
```

## Добавляем подписку и поддержку Mihomo

```
bash <(wget -qO- https://github.com/legiz-ru/marz-sub/raw/main/marz-sub.sh)
```
После этого сделайте `docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d` 


## Ручная установка

Описана [здесь](https://github.com/Akiyamov/xray-vps-setup/blob/main/install_in_docker.md).  

## Почему не <strike>nginx</strike>caddy, haproxy, 3x-ui, x-ui, sing-box...

<strike>Caddy</strike> Angie сам получит сертификаты, поэтому нам не придется их получать через `acme.sh` или `certbot`.  
3X-ui мерзотная панель.  
Sing-box не очень.  
XHTTP позже, а больше не надо. Уже точно. 

## Связь
Issues, PR ну или мой [тг](https://t.me/Akiyamov).
