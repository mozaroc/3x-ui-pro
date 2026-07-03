# x-ui-pro-refactor

Refactored single-file installer for 3x-ui VPN panel (based on x-ui-pro).

## Repository structure

```
x-ui-latest.sh          — main installer script (single file, run remotely)
x-ui-patch.sh           — apply current features to an existing install (no DB changes)
assets/
  backup/x-ui-backup.sh — backup / restore / list script
  clash/clash.yaml      — Clash/Mihomo subscription template (served by UA sniffing)
  diagnostics/
    index.html          — network diagnostics page (speed test, MTR, test files)
    mtr-backend.py      — localhost-only backend: MTR, LibreSpeed endpoints, clash.yaml generator
    librespeed/         — vendored LibreSpeed engine (speedtest.js, speedtest_worker.js, LGPL)
  fake-sites/
    site-01 … site-50/  — static HTML cover pages (index.html per site)
```

Scripts download assets at install time from this repo's raw GitHub URL
(`https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/...`) — changes take
effect on servers only after push to `main`.

## What x-ui-latest.sh does

1. Checks OS (Ubuntu 24.04/26.04, Debian 12/13) and rejects QEMU-emulated CPUs
2. Parses CLI arguments (`-install y`, `-subdomain`, `-reality_domain`, `-auto_domain y`, `-uninstall y`)
3. Validates domains (panel ≠ REALITY), then stops/cleans any previous install
4. Installs packages (`install_packages`) — nginx-full, certbot, sqlite3, ufw, mtr, python3 …
5. Obtains Let's Encrypt certs via certbot standalone (`get_ssl_certs`) — panel + reality domains
6. Installs 3x-ui panel from MHSanaei/3x-ui latest release (`install_panel`)
7. Configures nginx (`configure_nginx`) — SNI stream (443 → reality:8443 / panel:7443),
   per-domain vhosts, shared includes snippet, rate-limit zones
8. Pushes all settings and inbounds into x-ui.db (`configure_xui_db`)
9. Installs Clash subscription template (`install_clash_sub`) → `/var/www/subpage/clash.yaml.tpl`;
   Clash/Mihomo user agents get generated clash.yaml, `?provider=1` bypasses it
10. Downloads a random fake cover site (`install_fake_site`) → `/var/www/html/`
11. Installs network diagnostics (`install_diagnostics`) → `/var/www/diagnostics/` +
    `mtr-backend` systemd service (hardened, dedicated user, localhost-only)
12. Tunes kernel/BBR (`tune_system`)
13. Sets up cron (`setup_cron`) — daily x-ui restart + nginx reload; monthly certbot renew
    with pre/post hooks stopping/starting nginx (certs are standalone-issued)
14. Configures UFW (`setup_firewall`) — 22/80/443 tcp, 443 udp
15. Prints panel URL + credentials (`show_results`)

## Speed test (LibreSpeed)

Upload over HTTP/2 is throttled per-stream by the h2 flow-control window, so a
single big POST measures ~4x low. The diagnostics page uses the vendored
LibreSpeed engine: parallel streams, XHR-progress measurement, no telemetry, no
database. h2 must stay enabled on the vhosts — trojan-gRPC needs it. Endpoints:
download = static `testfiles/test-100m.bin`; upload = `api/st/up` (Python sink,
`proxy_request_buffering off`); ping = `api/st/ping` (nginx `return 200`);
IP = `api/st/getip`. Speedtest locations use `limit_conn`, not `limit_req`
(the engine fires many requests).

## Inbounds created

| Protocol | Port           | Transport      |
|----------|----------------|----------------|
| vless    | 8443           | REALITY / TCP  |
| vless    | `$ws_port`     | WebSocket      |
| vless    | UDS socket     | XHTTP (gRPC)   |
| trojan   | `$trojan_port` | gRPC           |

## Running

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-latest.sh) \
  -install y -subdomain panel.example.com -reality_domain r.example.com
```

Patch an existing install (re-reads ports/paths from x-ui.db and nginx):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh)
```
