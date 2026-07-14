# 3x-ui-pro

🇷🇺 [Русская версия](README.md)

Automated installer for the [3x-ui](https://github.com/MHSanaei/3x-ui) panel with nginx, SSL, Clash subscription and network diagnostics.

- Debian 12 / Ubuntu 24
- Two domains or subdomains (one for the panel, one for REALITY)
- Automatic SSL certificate renewal
- VLESS+REALITY, VLESS+WebSocket, VLESS+XHTTP, Trojan+gRPC — all through port 443

---

## What gets installed

| Component | Description |
|-----------|-------------|
| 3x-ui | VPN panel with web UI |
| nginx | Reverse proxy, SNI routing |
| certbot | Let's Encrypt SSL |
| Clash subscription | Serves `clash.yaml` based on User-Agent |
| Diagnostics | MTR tracer + in-browser speed test |
| Fake site | Random HTML cover site |
| Backup | Backup / restore script |
| AdGuard Home | Optional: ad-blocking DNS (DoH) — separate script |

---

## Installation

**Step 1 — download the script**

```bash
wget -qO x-ui-latest.sh https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh
```

**Step 2 — run it**

```bash
bash x-ui-latest.sh -install y
```

---
## Patch

Apply current fixes to an existing installation (no DB changes):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh)
```

---

## AdGuard Home (optional)

Installs [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome) on the panel domain — no separate domain or open ports, everything goes through the existing 443:

- **DNS-over-HTTPS** for clients: `https://<panel-domain>/dns-query`
- **Admin UI** — at a random `/adg-<random>/` path (login and password are printed by the script)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-adguard.sh)
```

Re-running is safe (settings and password are kept). After the installer or the patch, run this script again — they rewrite the nginx config.

Uninstall:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-adguard.sh) -uninstall y
```

---

## Uninstall

```bash
bash x-ui-latest.sh -uninstall y
```

---

## Command-line options

| Option | Description |
|--------|-------------|
| `-install y` | Install |
| `-subdomain <domain>` | Panel and subscription domain |
| `-reality_domain <domain>` | REALITY destination domain |
| `-auto_domain y` | Auto-detect domain (no manual input) |
| `-uninstall y` | Full uninstall |

---

## Clash subscription

Works via User-Agent detection — one URL, different behavior:

- **Clash / Mihomo / Stash** → get a ready-to-use `clash.yaml` config
- **Regular browser / other clients** → get the standard 3x-ui subscription page

The import link is printed by the script after installation.

---

## Backup and restore

**Install the backup script**

```bash
wget -qO /usr/local/bin/x-ui-backup https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/assets/backup/x-ui-backup.sh
chmod +x /usr/local/bin/x-ui-backup
```

**Create a backup**

```bash
x-ui-backup backup
```

**List backups**

```bash
x-ui-backup list
```

**Restore from a backup** (on a clean server; packages are installed automatically)

```bash
x-ui-backup restore /var/backups/x-ui/x-ui-backup-20260101-120000.tar.gz
```

The backup includes: nginx configs, panel DB, 3x-ui binary, SSL certificates, web content, systemd units, cron, UFW rules.

---

## Network diagnostics

Available after installation at the link printed by the script. Includes:

- MTR trace to your IP
- Download and upload speed test (512 MB test files)
