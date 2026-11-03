# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Provisioning tooling that turns a fresh Ubuntu VPS into a VLESS Reality proxy server (Xray, optionally behind the Marzban panel, or a Marzban node for an existing panel), fronted by Angie (nginx fork) which exists only to obtain TLS certificates (built-in ACME) and serve a camouflage page / proxy the Marzban panel. This is the iGroza fork of Akiyamov/xray-vps-setup; fork-specific changes: two REALITY inbounds (VLESS-XHTTP `stream-one` on `XRAY_PORT`, default 443, and VLESS-TCP-Vision on `VISION_PORT` 8443) with `firefox` fingerprint, Xray-core pinned to `XRAY_VERSION`, Marzban pinned to v0.8.4 and run in "Telegram bot only" mode (only the sub path is public), server-side blocking of RU traffic, and the `🏴‍☠️ <domain>` remark on generated configs. Decisions are backed by `reports/Xray VLESS обход блокировок РФ.md` (Nov 2026 research).

The only installation path is **`vps-setup.sh`** — an interactive bash bootstrap script users run as root on the VPS. It renders templates from `templates_for_script/` with `envsubst` (shell `$VAR` syntax). The Ansible role that used to mirror it was removed in Nov 2026; don't re-add a second template set.

## Critical: the script fetches templates from GitHub, not disk

`vps-setup.sh` downloads every template at runtime from
`https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/...`
where `GIT_REPO="igroza/xray-vps-setup"` and `GIT_BRANCH="main"` are set at the top of the script. Local template edits have **no effect** until pushed to that repo/branch; to test changes on a branch, override `GIT_BRANCH` (and `GIT_REPO` for forks).

## How the pieces fit

- Everything is deployed to `/opt/xray-vps-setup` on the target and run via docker compose (services: `angie` + one of `xray` / `marzban` / `marzban-node`, all `network_mode: host`).
- One compose template per variant: `templates_for_script/compose-{xray,marzban,node}`; `xray`/`marzban` `depends_on` Angie because REALITY learns the target's handshake at core start. `yq` (mikefarah's Go version — the script uninstalls the Python `yq` to avoid conflicts) is used for WARP config edits and parsing panel API JSON.
- Angie listens on `127.0.0.1:4123` with `proxy_protocol`, so both Reality inbounds must keep `xver: 1` and `target: 127.0.0.1:4123`. Port 80 is Angie's ACME + redirect listener (`$XRAY_PORT_SUFFIX` is `":port"` when not on 443). In the Marzban variant Angie publicly proxies only `/$MARZBAN_SUB_PATH` and `/statics`; dashboard/API are reachable only on `127.0.0.1:8000`.
- Angie templates are rendered with an explicit envsubst variable list (nginx uses `$var` too) — add any new shell variable to that list in `vps-setup.sh` or it stays literal.
- Xray config (`templates_for_script/xray`): XHTTP inbound has no `flow` (Vision is incompatible with XHTTP; Marzban strips it itself), Vision inbound uses `network: tcp` (not `raw`) so old clients parse the link. Routing: bittorrent + `geoip:private` blocked in the template; RU traffic rule is appended by the script (`block_ru_routing` or the WARP rule), never both.
- Marzban runs the pinned Xray-core release (zip from GitHub, unpacked to `./xray-core`, mounted at `/code/xray-core`, `XRAY_EXECUTABLE_PATH` in `marzban/.env`), not the core bundled in its image. Marzban listens on `127.0.0.1:8000`; Angie proxies the dashboard/sub/api paths to it.
- Reality keypair (PIK/PBK), short ID, and UUID are generated at install time by running the `ghcr.io/xtls/xray-core:$XRAY_VERSION` image (output parsed by label: `PrivateKey` / `Password (PublicKey)`).
- `marzban_bot_patch` (script) extracts `app/telegram/handlers/admin.py` from the pinned `gozargah/marzban:v0.8.4` image, patches it with `templates_for_script/marzban_bot_patch.py` (labels links/QR captions via `_link_label`) and compose bind-mounts the result over the original. The patch asserts its anchors, so bumping the Marzban tag requires re-checking it.
- After Marzban starts, the script imports the admin from env (`marzban-cli admin import-from-env`), strips `SUDO_*` from `.env`, and rewrites the default hosts via the panel API on `127.0.0.1:8000` (remark `🏴‍☠️ <domain> | {USERNAME}` / `… ⚡ …` for the Vision inbound, address/sni = domain, fingerprint firefox, mux off).
- Flow (script): mode → domain/DNS check → TG bot (marzban) → xray port → optional SSH user → optional WARP → BBR → yq → docker → key generation (keys, 3 shortIds, XHTTP path) → variant setup → iptables/sshd (only when the SSH user is requested) → WARP or `block_ru_routing` → node API registration → `docker compose up` → admin import + panel host update → print credentials.
- WARP (optional) installs `cloudflare-warp` in proxy mode on port 40000 and adds an Xray `socks` outbound plus a routing rule sending `.ru`/`.su`/geosite ru-category traffic through it.
- Security hardening (optional) locks iptables down to SSH + 80 + both Xray ports, creates a sudo user with the provided SSH key, and disables root login and password auth via `templates_for_script/00-disable-password`. Order matters: the user must exist before root login is disabled (see commit 8f06c6d).
- Ports 80, 4123 and `VISION_PORT` are reserved — the script refuses them for the Xray port and the SSH port.
- Node mode (`marzban-node`) registers itself on an existing panel through its REST API (`/api/node`, `/api/core/config`, `/api/hosts`) and only opens 62001/62002 to the panel IP.

## Testing / verification

There is no CI, linter, or test suite. Verification is done by running the installer on a throwaway machine:

- Docker-based manual walkthrough: `install_in_docker.md`.
- Script path: `bash vps-setup.sh` as root on a scratch Ubuntu box (remember the GitHub-fetch caveat above).
- Syntax checks: `bash -n vps-setup.sh`; render `templates_for_script/xray` with dummy env vars via `envsubst` and run `docker run --rm -v $PWD/x.json:/c.json ghcr.io/xtls/xray-core:$XRAY_VERSION run -test -c /c.json`.
