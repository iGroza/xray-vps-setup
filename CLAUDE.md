# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Provisioning tooling that turns a fresh Ubuntu VPS into a VLESS Reality proxy server (Xray, optionally behind the Marzban panel), fronted by Caddy which exists only to obtain TLS certificates and serve a camouflage page. This is the iGroza fork of Akiyamov/xray-vps-setup; fork-specific changes: Xray listens on port 433 (not 443), `xver: 0`, `fallbacks` instead of `sniffing`, and Telegram bot support for Marzban.

There are **two parallel installation paths that implement the same setup and must be kept in sync**:

1. **`vps-setup.sh`** — interactive bash bootstrap script users run as root on the VPS. It renders templates from `templates_for_script/` with `envsubst` (shell `$VAR` syntax).
2. **Ansible role** (standard Galaxy layout: `tasks/`, `templates/`, `handlers/`, `defaults/`, `vars/`, `meta/`) — published as `Akiyamov.xray-vps-setup`. It renders Jinja2 templates from `templates/*.j2`.

When changing generated config (Xray config, Caddyfile, docker-compose, Marzban env), the same change usually needs to land in **both** template directories, in their respective syntaxes.

## Critical: the script fetches templates from GitHub, not disk

`vps-setup.sh` downloads every template at runtime from
`https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script/...`
where `GIT_REPO="igroza/xray-vps-setup"` and `GIT_BRANCH="main"` are set at the top of the script. Local template edits have **no effect** until pushed to that repo/branch; to test changes on a branch, override `GIT_BRANCH` (and `GIT_REPO` for forks).

## How the pieces fit

- Everything is deployed to `/opt/xray-vps-setup` on the target and run via docker compose (services: `caddy` + either `xray` or `marzban`, all `network_mode: host`).
- The compose file starts from one shared template (`templates_for_script/compose` / `templates/*_docker.j2`); variant-specific service definitions are injected with `yq` (mikefarah's Go version — the script explicitly uninstalls the Python `yq` to avoid conflicts).
- Reality keypair (PIK/PBK), short ID, and UUID are generated at install time by running the `ghcr.io/xtls/xray-core` image; Caddy's password hash is generated via the `caddy` image.
- Flow: `main.yml` orders it as BBR → docker → yq → optional security block (sshd hardening, iptables, user creation) → key generation → marzban XOR xray install → optional WARP → `docker compose up`.
- WARP (optional) installs `cloudflare-warp` in proxy mode on port 40000 and adds an Xray `socks` outbound plus a routing rule sending `.ru`/`.su`/geosite ru-category traffic through it.
- Security hardening (optional) locks iptables down to SSH + 80 + the Xray port, creates a sudo user with the provided SSH key, and disables root login and password auth. Order matters: the user must exist before root login is disabled (see commit 8f06c6d).
- Ports 80 and 4123 are reserved (Caddy cert issuance / internal fallback) — the script refuses them for both the Xray port and the SSH port.

## Testing / verification

There is no CI, linter, or real test suite (`tests/test.yml` is the Galaxy stub). Verification is done by running the installer on a throwaway machine:

- Docker-based manual walkthrough: `install_in_docker.md`.
- Script path: `bash vps-setup.sh` as root on a scratch Ubuntu box (remember the GitHub-fetch caveat above).
- Ansible path: run a playbook with role vars `domain`, `setup_variant` (`marzban`|`xray`), `setup_warp`, `configure_security` (+ `user_to_create`, `user_password`, `SSH_PORT`, `ssh_public_key` when true) — see README.md for the example play.
- Syntax checks: `bash -n vps-setup.sh`; `ansible-playbook --syntax-check` against a play including the role.
