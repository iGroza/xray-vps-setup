# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Provisioning tooling that turns a fresh Ubuntu VPS into a VLESS Reality proxy server (Xray, optionally behind the Marzban panel, or a Marzban node for an existing panel), fronted by Angie (nginx fork) which exists only to obtain TLS certificates (built-in ACME) and serve a camouflage page / proxy the Marzban panel. This is the iGroza fork of Akiyamov/xray-vps-setup; fork-specific changes: Xray listens on port 433 by default (configurable, `XRAY_PORT`), VLESS-gRPC-REALITY transport with `firefox` fingerprint, Xray-core pinned to `XRAY_VERSION`, Telegram bot support for Marzban, and the `🏴‍☠️ <domain>` remark on generated configs.

There are **two parallel installation paths that implement the same setup and must be kept in sync**:

1. **`vps-setup.sh`** — interactive bash bootstrap script users run as root on the VPS. It renders templates from `templates_for_script/` with `envsubst` (shell `$VAR` syntax).
2. **Ansible role** (standard Galaxy layout: `tasks/`, `templates/`, `handlers/`, `defaults/`, `vars/`, `meta/`) — published as `Akiyamov.xray-vps-setup`. It renders Jinja2 templates from `templates/*.j2`.

When changing generated config (Xray config, angie.conf, docker-compose, Marzban env), the same change usually needs to land in **both** template directories, in their respective syntaxes.

## Critical: the script fetches templates from GitHub, not disk

`vps-setup.sh` downloads every template at runtime from
`https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/...`
where `GIT_REPO="igroza/xray-vps-setup"` and `GIT_BRANCH="main"` are set at the top of the script. Local template edits have **no effect** until pushed to that repo/branch; to test changes on a branch, override `GIT_BRANCH` (and `GIT_REPO` for forks).

## How the pieces fit

- Everything is deployed to `/opt/xray-vps-setup` on the target and run via docker compose (services: `angie` + one of `xray` / `marzban` / `marzban-node`, all `network_mode: host`).
- One compose template per variant: `templates_for_script/compose-{xray,marzban,node}` and `templates/docker_compose.yml.j2` (Jinja `if setup_variant`). `yq` (mikefarah's Go version — the script uninstalls the Python `yq` to avoid conflicts) is used for WARP config edits and parsing panel API JSON.
- Angie listens on `127.0.0.1:4123` with `proxy_protocol`, so the Xray Reality inbound must keep `xver: 1` and `dest: 127.0.0.1:4123`. Port 80 is Angie's ACME + redirect listener.
- Marzban runs the pinned Xray-core release (zip from GitHub, unpacked to `./xray-core`, mounted at `/code/xray-core`, `XRAY_EXECUTABLE_PATH` in `marzban/.env`), not the core bundled in its image. Marzban listens on `127.0.0.1:8000`; Angie proxies the dashboard/sub/api paths to it.
- Reality keypair (PIK/PBK), short ID, and UUID are generated at install time by running the `ghcr.io/xtls/xray-core:$XRAY_VERSION` image (output parsed by label: `PrivateKey` / `Password (PublicKey)`).
- After Marzban starts, the script imports the admin from env (`marzban-cli admin import-from-env`) and rewrites the default host via the panel API on `127.0.0.1:8000` (remark `🏴‍☠️ <domain> | {USERNAME}`, address/sni = domain, fingerprint firefox). The Ansible path does the same through sqlite in `tasks/end_marzban.yml`.
- Flow (script): mode → domain/DNS check → TG bot (marzban) → xray port → optional SSH user → optional WARP → BBR → yq → docker → key generation → variant setup → iptables/sshd (only when the SSH user is requested) → WARP → node API registration → `docker compose up` → panel host update → print credentials.
- Flow (Ansible `main.yml`): BBR → docker → yq → key generation → marzban XOR xray install → optional WARP → `docker compose up` → end_{xray,marzban}. The Ansible role has no SSH/iptables hardening any more (upstream dropped it).
- WARP (optional) installs `cloudflare-warp` in proxy mode on port 40000 and adds an Xray `socks` outbound plus a routing rule sending `.ru`/`.su`/geosite ru-category traffic through it.
- Security hardening (optional, script only) locks iptables down to SSH + 80 + the Xray port, creates a sudo user with the provided SSH key, and disables root login and password auth via `templates_for_script/00-disable-password`. Order matters: the user must exist before root login is disabled (see commit 8f06c6d).
- Ports 80 and 4123 are reserved (Angie ACME/redirect / internal fallback) — the script refuses them for both the Xray port and the SSH port.
- Node mode (`marzban-node`) registers itself on an existing panel through its REST API (`/api/node`, `/api/core/config`, `/api/hosts`) and only opens 62001/62002 to the panel IP.

## Testing / verification

There is no CI, linter, or real test suite (`tests/test.yml` is the Galaxy stub). Verification is done by running the installer on a throwaway machine:

- Docker-based manual walkthrough: `install_in_docker.md`.
- Script path: `bash vps-setup.sh` as root on a scratch Ubuntu box (remember the GitHub-fetch caveat above).
- Ansible path: run a playbook with role vars `domain`, `setup_variant` (`marzban`|`xray`), `setup_warp`, optional `xray_port`, `xray_version`, `TELEGRAM_API_TOKEN`, `TELEGRAM_ADMIN_ID` — see README.md for the example play.
- Syntax checks: `bash -n vps-setup.sh`; `ansible-playbook --syntax-check` against a play including the role.
