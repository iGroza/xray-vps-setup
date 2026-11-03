# xray-vps-setup

---

Fork includes:

- Only the bash installer is kept (the Ansible role was dropped) — one set of templates to maintain
- Two REALITY inbounds on one domain: **VLESS-XHTTP-REALITY** (`stream-one`) on `443` as the primary, resilient host and **VLESS-TCP-Vision-REALITY** on `8443` as the fast one (the core prints a non-443 warning for it — a conscious trade-off, drop that inbound if you want a single 443 profile); `firefox` uTLS fingerprint (Chrome 133 is throttled by ТСПУ)
- REALITY target is your own domain served by the local Angie (same IP/ASN/cert), several random `shortIds`, random XHTTP path
- Server-side routing blocks `geoip:ru` / `.ru` / `.su` / `.рф` (or sends it through WARP when enabled) and private ranges; `sniffing.routeOnly`
- Marzban pinned to `v0.8.4` (project is frozen), Xray-core pinned to `26.10.31` for both the standalone container and the Marzban core; keys are generated outside the panel with explicit `publicKey` (Marzban's x25519 parser breaks on new cores)
- Marzban in "Telegram bot only" mode: only the subscription path is public, dashboard/API stay on `127.0.0.1:8000` (SSH tunnel), `SUDO_*` removed from `.env` after the admin is imported
- Default client config name: `🏴‍☠️ <domain> | <marzban username>` (XHTTP) / `🏴‍☠️ <domain> ⚡ | <marzban username>` (Vision)
- Research behind these choices: `reports/Xray VLESS обход блокировок РФ.md`
- Tested on [cherryservers.com](https://www.cherryservers.com/pricing/virtual-servers) (Ubuntu 22.04)

---

VLESS со своим доменом. А что еще нужно для счастья?  

> [!IMPORTANT]
> Дайте секс

В данном варианте VLESS слушает на 443 (XHTTP) и 8443 (Vision) и принимате все запросы, делая запрос на локальный Angie(форк nginx) только для сертификатов. В таком варианте задержка будет меньше, чем в варианте с Caddy/NGINX перед VLESS, где происходит множество лишних запросов. 
## Скрипт

- Установит Xray/Marzban на ваш выбор. Для маскировки страницы используется [Conflunce](https://github.com/Jolymmiles/confluence-marzban-home)
- На ваше усмотрение настроит:
- - Iptables, запретив все подключения, кроме SSH, 80, 443 и 8443.
- - Создаст пользователя для подключения, запретив вход от рута
- - Добавит этому пользователю ключ для SSH, запретив вход по паролю
- - Настроит WARP для ру-сайтов.  
```bash
tmux
bash <(wget -qO- https://raw.githubusercontent.com/iGroza/xray-vps-setup/refs/heads/main/vps-setup.sh)
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
