#!/usr/bin/env bash
# x-ui-patch.sh — apply current features to an existing 3x-ui installation
#
# What it does (non-destructively, no DB changes):
#   1. Reads ports/paths from /etc/x-ui/x-ui.db
#   2. Detects domains from existing nginx configs
#   3. Regenerates all nginx configs
#   4. Installs network diagnostics (MTR + speed test)
#   5. Installs Clash subscription template (UA-based routing)
#   6. Replaces fake cover site with a current one
#
# Usage:
#   wget -qO x-ui-patch.sh https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main/x-ui-patch.sh
#   bash x-ui-patch.sh
set -Eeuo pipefail

XUIDB="/etc/x-ui/x-ui.db"
GITHUB_RAW="https://raw.githubusercontent.com/mozaroc/3x-ui-pro/main"
FAKE_SITE_COUNT=50
LIB_DIR="/usr/local/lib/3x-ui-pro"
DIAG_ROOT="/var/www/diagnostics"

# ── colour helpers ────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m[*] %s\033[0m\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -f "$XUIDB" ]]  || die "x-ui.db not found at $XUIDB — is 3x-ui installed?"

# ── ensure sqlite3 available ──────────────────────────────────────────────────
command -v sqlite3 &>/dev/null || apt-get install -y -q sqlite3

# ── read settings from DB ─────────────────────────────────────────────────────
blue "Reading settings from x-ui.db..."
db() { sqlite3 "$XUIDB" "$1"; }

sub_port=$(   db "SELECT value FROM settings WHERE key='subPort';")
sub_path=$(   db "SELECT value FROM settings WHERE key='subPath';"     | sed 's|^/||;s|/$||')
json_path=$(  db "SELECT value FROM settings WHERE key='subJsonPath';" | sed 's|^/||;s|/$||')
panel_port=$( db "SELECT value FROM settings WHERE key='webPort';")
panel_path=$( db "SELECT value FROM settings WHERE key='webBasePath';" | sed 's|^/||;s|/$||')

[[ -n "$sub_port"   ]] || die "subPort not found in DB — re-run the main installer"
[[ -n "$sub_path"   ]] || die "subPath not found in DB"
[[ -n "$panel_port" ]] || die "webPort not found in DB"
[[ -n "$panel_path" ]] || die "webBasePath not found in DB"

printf "    sub_port   = %-6s  sub_path   = %s\n" "$sub_port"  "$sub_path"
printf "    panel_port = %-6s  panel_path = %s\n" "$panel_port" "$panel_path"
printf "    json_path  = %s\n" "$json_path"

# ── detect domains from existing nginx ───────────────────────────────────────
blue "Detecting domains from nginx configs..."
domain=""
reality_domain=""

for f in /etc/nginx/sites-available/*; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "80.conf" ]] && continue
    if grep -q 'listen 7443' "$f" 2>/dev/null; then
        domain=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
    elif grep -q 'listen 9443' "$f" 2>/dev/null; then
        reality_domain=$(awk '/server_name/{print $2; exit}' "$f" | tr -d ';')
    fi
done

[[ -n "$domain" ]]         || die "Could not find panel domain (nginx config with 'listen 7443')"
[[ -n "$reality_domain" ]] || die "Could not find reality domain (nginx config with 'listen 9443')"
printf "    domain         = %s\n" "$domain"
printf "    reality_domain = %s\n" "$reality_domain"

# ── ensure the panel is served over HTTPS ─────────────────────────────────────
# The panel vhost and the diag SSO bridge both proxy_pass https://127.0.0.1:panel_port.
# If the panel has no TLS cert configured it answers plain HTTP and every one of
# those proxy_pass calls fails (502 / SSL handshake error, diag never loads).
# Mirror the main installer: symlink the Let's Encrypt cert into /root/cert and
# register it with `x-ui cert`.
web_cert=$(db "SELECT value FROM settings WHERE key='webCertFile';")
web_key=$( db "SELECT value FROM settings WHERE key='webKeyFile';")
# The DB may reference a cert that no longer exists on disk (e.g. a dangling
# /root/cert symlink after a restore) — the panel then fails to serve HTTPS and
# every proxy_pass https:// (panel + diag bridge) breaks. "-e" follows symlinks,
# so a broken link reads as missing.
if [[ -z "$web_cert" || -z "$web_key" ]]; then
    need_cert=1; blue "Panel has no TLS cert configured — enabling HTTPS..."
elif [[ ! -e "$web_cert" || ! -e "$web_key" ]]; then
    need_cert=1; blue "Panel cert configured but missing on disk ($web_cert) — repairing..."
else
    need_cert=0; blue "Panel TLS cert present: $web_cert"
fi
if [[ $need_cert -eq 1 ]]; then
    if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
        mkdir -p "/root/cert/${domain}"
        chmod 755 /root/cert/* 2>/dev/null || true
        ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "/root/cert/${domain}/fullchain.pem"
        ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem"   "/root/cert/${domain}/privkey.pem"
        if [[ -x /usr/local/x-ui/x-ui ]]; then
            /usr/local/x-ui/x-ui cert \
                -webCert    "/root/cert/${domain}/fullchain.pem" \
                -webCertKey "/root/cert/${domain}/privkey.pem"
            systemctl restart x-ui 2>/dev/null || x-ui restart 2>/dev/null || true
            green "Panel HTTPS enabled."
        else
            red "x-ui binary not found at /usr/local/x-ui/x-ui — cannot set panel cert."
        fi
    else
        red "No Let's Encrypt cert for ${domain} at /etc/letsencrypt/live/${domain} — cannot enable panel HTTPS."
    fi
fi

# ── detect xhttp_path ─────────────────────────────────────────────────────────
xhttp_path=""
# 1. from existing includes.conf
if [[ -f /etc/nginx/snippets/includes.conf ]]; then
    xhttp_path=$(grep -A1 '#XHTTP' /etc/nginx/snippets/includes.conf \
        | grep 'location' | grep -oP 'location /\K[^ {]+' | head -1 || true)
fi
# 2. from DB (xhttp inbound stream_settings)
if [[ -z "$xhttp_path" ]]; then
    xhttp_path=$(db "SELECT json_extract(stream_settings,'$.xhttpSettings.path')
                     FROM inbounds
                     WHERE json_extract(stream_settings,'$.network')='xhttp'
                     LIMIT 1;" 2>/dev/null | sed 's|^/||;s|/$||' || true)
fi
# 3. generate new
if [[ -z "$xhttp_path" ]]; then
    xhttp_path=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 10 || true)
    blue "xhttp_path generated: $xhttp_path"
else
    blue "xhttp_path detected: $xhttp_path"
fi

# ── detect or generate diag_path ─────────────────────────────────────────────
diag_path=""
for f in /etc/nginx/sites-available/*; do
    [[ -f "$f" ]] || continue
    p=$(grep -oP 'location \^\~ \K/net-[^ {/]+/' "$f" 2>/dev/null | head -1 || true)
    [[ -n "$p" ]] && { diag_path="$p"; break; }
done
if [[ -n "$diag_path" ]]; then
    blue "diag_path reused: $diag_path"
else
    diag_path="/net-$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 12 || true)/"
    blue "diag_path generated: $diag_path"
fi

# ── detect or generate diag access token ─────────────────────────────────────
diag_token=""
for f in /etc/nginx/sites-available/*; do
    [[ -f "$f" ]] || continue
    t=$(grep -oP 'diag_key=\K[a-zA-Z0-9]+' "$f" 2>/dev/null | head -1 || true)
    [[ -n "$t" ]] && { diag_token="$t"; break; }
done
if [[ -n "$diag_token" ]]; then
    blue "diag_token reused"
else
    diag_token=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 16 || true)
    blue "diag_token generated"
fi

# ── detect or generate mtr_backend_port ──────────────────────────────────────
mtr_backend_port=""
if [[ -f /etc/systemd/system/mtr-backend.service ]]; then
    mtr_backend_port=$(grep -oP '(?<=--port )\d+' /etc/systemd/system/mtr-backend.service \
        | head -1 || true)
fi
if [[ -z "$mtr_backend_port" ]]; then
    while true; do
        p=$(( ((RANDOM<<15)|RANDOM) % 49152 + 10000 ))
        nc -z 127.0.0.1 "$p" &>/dev/null || { mtr_backend_port=$p; break; }
    done
    blue "mtr_backend_port generated: $mtr_backend_port"
else
    blue "mtr_backend_port reused: $mtr_backend_port"
fi

# ── install required packages ─────────────────────────────────────────────────
blue "Installing packages..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -q mtr-tiny python3 curl wget sqlite3

# ─────────────────────────────────────────────────────────────────────────────
# NGINX CONFIGS
# ─────────────────────────────────────────────────────────────────────────────
blue "Regenerating nginx configs..."

mkdir -p /etc/nginx/stream-enabled /etc/nginx/snippets \
         /etc/nginx/sites-available /etc/nginx/sites-enabled

# nginx >= 1.25.1 deprecates "listen ... http2" in favor of "http2 on;";
# older versions (Debian 12 / Ubuntu 24.04) don't know the new directive
http2_listen="" ; http2_on=""
ngx_ver=$(nginx -v 2>&1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo 0)
if [[ "$(printf '%s\n' 1.25.1 "$ngx_ver" | sort -V | head -1)" == "1.25.1" ]]; then
    http2_on="http2 on;"
else
    http2_listen=" http2"
fi

# ── SNI stream ────────────────────────────────────────────────────────────────
cat > /etc/nginx/stream-enabled/stream.conf <<EOF
map \$ssl_preread_server_name \$sni_name {
    hostnames;
    ${reality_domain}    xray;
    ${domain}            www;
    default              xray;
}

upstream xray { server 127.0.0.1:8443; }
upstream www  { server 127.0.0.1:7443; }

server {
    proxy_protocol on;
    set_real_ip_from unix:;
    listen     443;
    listen     [::]:443;
    proxy_pass \$sni_name;
    ssl_preread on;
}
EOF

grep -xqFR "stream { include /etc/nginx/stream-enabled/*.conf; }" /etc/nginx/* \
    || echo "stream { include /etc/nginx/stream-enabled/*.conf; }" >> /etc/nginx/nginx.conf
grep -xqFR "load_module modules/ngx_stream_module.so;" /etc/nginx/* \
    || sed -i '1s/^/load_module \/usr\/lib\/nginx\/modules\/ngx_stream_module.so; /' /etc/nginx/nginx.conf
grep -xqFR "worker_rlimit_nofile 16384;" /etc/nginx/* \
    || echo "worker_rlimit_nofile 16384;" >> /etc/nginx/nginx.conf
sed -i "/worker_connections/c\worker_connections 4096;" /etc/nginx/nginx.conf

# ── HTTP → HTTPS redirect ─────────────────────────────────────────────────────
cat > /etc/nginx/sites-available/80.conf <<EOF
server {
    listen 80;
    server_name ${domain} ${reality_domain};
    return 301 https://\$host\$request_uri;
}
EOF

# ── Shared proxy locations snippet ────────────────────────────────────────────
cat > /etc/nginx/snippets/includes.conf <<EOF
    #Subscription — prefix location covers all sub-paths (assets, JS, etc.)
    location /${sub_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location = /${sub_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location ~ ^/${sub_path}/(?<clash_sub_id>[^/]+)\$ {
        if (\$hack = 1) { return 404; }
        if (\$serve_clash_yaml = 1) { rewrite ^ /__clash_api?sub_id=\$clash_sub_id last; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /assets  { proxy_pass https://127.0.0.1:${sub_port}; }
    location /assets/ { proxy_pass https://127.0.0.1:${sub_port}; }

    #Subscription (json)
    location /${json_path} {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }
    location /${json_path}/ {
        if (\$hack = 1) { return 404; }
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass https://127.0.0.1:${sub_port};
    }

    #XHTTP
    location /${xhttp_path} {
        grpc_pass grpc://unix:/dev/shm/uds2023.sock;
        grpc_buffer_size      16k;
        grpc_socket_keepalive on;
        grpc_read_timeout     1h;
        grpc_send_timeout     1h;
        grpc_set_header Connection        "";
        grpc_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto \$scheme;
        grpc_set_header X-Forwarded-Port  \$server_port;
        grpc_set_header Host              \$host;
        grpc_set_header X-Forwarded-Host  \$host;
    }

    #Xray generic proxy (WS / gRPC by port+path)
    location ~ ^/(?<fwdport>\d+)/(?<fwdpath>.*)\$ {
        if (\$hack = 1) { return 404; }
        client_max_body_size 0;
        client_body_timeout 1d;
        grpc_read_timeout 1d;
        grpc_socket_keepalive on;
        proxy_read_timeout 1d;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_socket_keepalive on;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        if (\$content_type ~* "GRPC") {
            grpc_pass grpc://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$http_upgrade ~* "(WEBSOCKET|WS)") {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
        if (\$request_method ~* ^(PUT|POST|GET)\$) {
            proxy_pass http://127.0.0.1:\$fwdport\$is_args\$args;
            break;
        }
    }

    location / { try_files \$uri \$uri/ =404; }
EOF

# ── Panel domain vhost ────────────────────────────────────────────────────────
cat > "/etc/nginx/sites-available/${domain}" <<EOF
limit_req_zone  \$binary_remote_addr zone=diag_api:10m  rate=6r/m;
limit_req_zone  \$binary_remote_addr zone=diag_page:10m rate=30r/m;
limit_conn_zone \$binary_remote_addr zone=per_ip:10m;

map \$http_user_agent \$is_clash_ua {
    ~*(clash|clashx|clashn|mihomo|stash|surfboard)  1;
    default                                          0;
}
map "\$is_clash_ua:\$arg_provider" \$serve_clash_yaml {
    "1:"    1;
    default 0;
}

# Diagnostics access: cookie issued by the SSO bridge after panel login
map \$cookie_diag_key \$diag_auth {
    "${diag_token}" 1;
    default          0;
}

server {
    server_tokens off;
    server_name ${domain};
    listen 7443 ssl${http2_listen} proxy_protocol;
    listen [::]:7443 ssl${http2_listen} proxy_protocol;
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    # This vhost listens on 7443 behind the SNI stream (public port 443). Without
    # this, nginx bakes :7443 into redirect Location headers (return/error_page),
    # so browsers get sent to an unreachable port. Keep redirects relative.
    absolute_redirect off;
    # Larger h2 preread window improves single-stream upload throughput
    http2_body_preread_size 128k;
    client_body_buffer_size 512k;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${domain}\$)            { return 444; }
    if (\$scheme ~* https)                          { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_pass https://127.0.0.1:${panel_port};
    }

    # Diagnostics SSO bridge: valid panel session → diag cookie + redirect.
    # auth_request runs in the access phase; plain "return" would skip it,
    # hence the try_files → named-location hop.
    location = /${panel_path}/diag {
        auth_request /__diag_auth;
        # Named location (not "=302 /uri") so the deny path emits a real Location
        # header; an internal-redirect error_page returns a 302 with no Location.
        error_page 401 403 = @diag_login;
        try_files /__nonexistent @diag_sso_ok;
    }
    location @diag_login {
        return 302 /${panel_path}/;
    }
    location @diag_sso_ok {
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800";
        return 302 ${diag_path};
    }
    location = /__diag_auth {
        internal;
        proxy_pass https://127.0.0.1:${panel_port}/${panel_path}/panel/;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        # 3x-ui answers AJAX requests with 401 instead of a login redirect
        proxy_set_header X-Requested-With XMLHttpRequest;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        # auth_request emits a raw 500 to the browser if the subrequest returns
        # anything other than 2xx / 401 / 403 (a login 302, or a 502 when the
        # panel's HTTPS cert is missing). Coerce every such status to a 401 deny
        # so the main location redirects to the panel login instead of 500ing.
        # 401/403 must be listed too, else the server-level "error_page 401 =404"
        # hijacks a genuine deny into a 404 (which auth_request then 500s on).
        proxy_intercept_errors on;
        error_page 300 301 302 303 304 305 307 308 400 401 402 403 404 405 500 501 502 503 504 =401 @diag_denied;
    }
    location @diag_denied { return 401; }

    # No diag cookie yet → bounce through the SSO bridge (checks panel session,
    # mints the cookie) so a bookmarked diag link works once logged into the panel.
    location ^~ ${diag_path} {
        if (\$diag_auth = 0) { return 302 /${panel_path}/diag; }
        limit_req  zone=diag_page burst=10 nodelay;
        limit_conn per_ip 5;
        alias /var/www/diagnostics/;
        index index.html;
        try_files \$uri \$uri/ /index.html;
        add_header Set-Cookie "diag_key=${diag_token}; Path=${diag_path}; Secure; HttpOnly; SameSite=Lax; Max-Age=604800" always;
        add_header Cache-Control "no-store" always;
        add_header X-Robots-Tag "noindex, nofollow" always;
    }
    location ^~ ${diag_path}api/mtr {
        if (\$diag_auth = 0) { return 404; }
        limit_req  zone=diag_api burst=2 nodelay;
        limit_conn per_ip 2;
        proxy_pass         http://127.0.0.1:${mtr_backend_port}/api/mtr;
        proxy_http_version 1.1;
        proxy_set_header   X-Real-IP       \$remote_addr;
        proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 120s;
        proxy_send_timeout 120s;
    }
    location ^~ ${diag_path}api/st/up {
        if (\$diag_auth = 0) { return 404; }
        access_log              off;
        limit_conn              per_ip 8;
        proxy_pass              http://127.0.0.1:${mtr_backend_port}/api/st/up;
        proxy_http_version      1.1;
        proxy_set_header        X-Real-IP       \$remote_addr;
        proxy_request_buffering off;
        client_max_body_size    64m;
        proxy_read_timeout      60s;
        proxy_send_timeout      60s;
        add_header              Cache-Control "no-store" always;
    }
    location = ${diag_path}api/st/ping {
        if (\$diag_auth = 0) { return 404; }
        access_log off;
        limit_conn per_ip 8;
        add_header Cache-Control "no-store" always;
        default_type text/plain;
        return 200 "";
    }
    location = ${diag_path}api/st/getip {
        if (\$diag_auth = 0) { return 404; }
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/st/getip;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
        add_header          Cache-Control "no-store" always;
    }
    location ^~ ${diag_path}testfiles/ {
        if (\$diag_auth = 0) { return 404; }
        alias      /var/www/diagnostics/testfiles/;
        access_log off;
        add_header Cache-Control "no-store, no-cache, must-revalidate" always;
        add_header Content-Disposition "attachment" always;
    }
    location = /__clash_api {
        internal;
        proxy_pass          http://127.0.0.1:${mtr_backend_port}/api/clash\$is_args\$args;
        proxy_http_version  1.1;
        proxy_set_header    X-Real-IP \$remote_addr;
        add_header          Content-Type        "text/yaml; charset=utf-8" always;
        add_header          Content-Disposition "attachment; filename=clash.yaml" always;
        add_header          Cache-Control       "no-store" always;
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

# ── Reality domain vhost ──────────────────────────────────────────────────────
cat > "/etc/nginx/sites-available/${reality_domain}" <<EOF
server {
    server_tokens off;
    server_name ${reality_domain};
    listen 9443 ssl${http2_listen};
    listen [::]:9443 ssl${http2_listen};
    ${http2_on}
    index index.html index.htm index.php;
    root /var/www/html/;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!eNULL:!MD5:!DES:!RC4:!ADH:!SSLv3:!EXP:!PSK:!DSS;
    ssl_certificate     /etc/letsencrypt/live/${reality_domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${reality_domain}/privkey.pem;
    if (\$host !~* ^(.+\.)?${reality_domain}\$)            { return 444; }
    if (\$scheme ~* https)                                  { set \$safe 1; }
    if (\$ssl_server_name !~* ^(.+\.)?${reality_domain}\$) { set \$safe "\${safe}0"; }
    if (\$safe = 10)                                        { return 444; }
    if (\$request_uri ~ "(\"|'|\`|~|,|:|;|%|\\$|&&|\?\?|0x00|0X00|\||\\|\{|\}|\[|\]|<|>|\.\.\.|\.\.\/|\/\/\/)") { set \$hack 1; }
    error_page 400 401 402 403 500 501 502 503 504 =404 /404;
    proxy_intercept_errors on;

    location /${panel_path}/ {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }
    location /${panel_path} {
        proxy_redirect off;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_pass http://127.0.0.1:${panel_port};
    }

    include /etc/nginx/snippets/includes.conf;
}
EOF

# ── activate sites ────────────────────────────────────────────────────────────
rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default
ln -sf "/etc/nginx/sites-available/${domain}"         /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/${reality_domain}" /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/80.conf"           /etc/nginx/sites-enabled/

# ─────────────────────────────────────────────────────────────────────────────
# MTR-BACKEND
# ─────────────────────────────────────────────────────────────────────────────
blue "Installing mtr-backend..."

mkdir -p "$LIB_DIR"
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/mtr-backend.py" -o "${LIB_DIR}/mtr-backend.py"
chmod +x "${LIB_DIR}/mtr-backend.py"

id mtr-backend &>/dev/null || \
    useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

if command -v setcap &>/dev/null; then
    setcap cap_net_raw+ep "$(command -v mtr)" 2>/dev/null || true
fi

cat > /etc/systemd/system/mtr-backend.service <<EOF
[Unit]
Description=MTR diagnostics backend
After=network.target

[Service]
Type=simple
User=mtr-backend
Group=mtr-backend
ExecStart=/usr/bin/python3 ${LIB_DIR}/mtr-backend.py --port ${mtr_backend_port}
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/tmp

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mtr-backend
systemctl restart mtr-backend

# ─────────────────────────────────────────────────────────────────────────────
# DIAGNOSTICS WEBROOT
# ─────────────────────────────────────────────────────────────────────────────
blue "Installing diagnostics page..."

mkdir -p "${DIAG_ROOT}/testfiles"
server_ip=$(ip route get 8.8.8.8 2>/dev/null | grep -Po 'src \K\S*' || true)
[[ -n "$server_ip" ]] || server_ip=$(curl -fsS ipv4.icanhazip.com | tr -d '[:space:]' || true)
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/index.html" \
    | sed -e "s|__DIAG_PATH__|${diag_path}|g" \
          -e "s|__SERVER_DOMAIN__|${domain}|g" \
          -e "s|__SERVER_IP__|${server_ip}|g" \
    > "${DIAG_ROOT}/index.html"

# LibreSpeed engine (speed test frontend, LGPL — github.com/librespeed/speedtest)
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest.js" \
    -o "${DIAG_ROOT}/speedtest.js"
curl -fsSL "${GITHUB_RAW}/assets/diagnostics/librespeed/speedtest_worker.js" \
    -o "${DIAG_ROOT}/speedtest_worker.js"

# Generate speed test files if missing (same set as the main installer)
[[ -f "${DIAG_ROOT}/testfiles/test-15k.bin"  ]] || \
    dd if=/dev/zero bs=1024 count=15 of="${DIAG_ROOT}/testfiles/test-15k.bin" status=none
[[ -f "${DIAG_ROOT}/testfiles/test-17k.bin"  ]] || \
    dd if=/dev/zero bs=1024 count=17 of="${DIAG_ROOT}/testfiles/test-17k.bin" status=none
[[ -f "${DIAG_ROOT}/testfiles/test-100m.bin" ]] || \
    dd if=/dev/zero bs=1048576 count=100 of="${DIAG_ROOT}/testfiles/test-100m.bin" status=none
[[ -f "${DIAG_ROOT}/testfiles/test-1g.bin"   ]] || \
    dd if=/dev/zero bs=1048576 count=1024 of="${DIAG_ROOT}/testfiles/test-1g.bin"  status=none
rm -f "${DIAG_ROOT}/testfiles/test-512m.bin"   # only used by the old single-stream speed test

chown -R www-data:www-data "$DIAG_ROOT"

# ─────────────────────────────────────────────────────────────────────────────
# CLASH SUBSCRIPTION TEMPLATE
# ─────────────────────────────────────────────────────────────────────────────
blue "Installing Clash subscription template..."

clash_dir="/var/www/subpage"
mkdir -p "$clash_dir"
if curl -fsSL "${GITHUB_RAW}/assets/clash/clash.yaml" -o "${clash_dir}/clash.yaml.tpl"; then
    sed -i "s|\${DOMAIN}|${domain}|g"     "${clash_dir}/clash.yaml.tpl"
    sed -i "s|\${SUB_PATH}|${sub_path}|g" "${clash_dir}/clash.yaml.tpl"
    chown -R www-data:www-data "$clash_dir"
    chmod 644 "${clash_dir}/clash.yaml.tpl"
    green "Clash template installed."
else
    red "Failed to download clash.yaml template (non-fatal)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# FAKE COVER SITE
# ─────────────────────────────────────────────────────────────────────────────
blue "Updating fake cover site..."

pick=$(( RANDOM % FAKE_SITE_COUNT + 1 ))
site_num=$(printf "%02d" "$pick")
mkdir -p /var/www/html

if curl -fsSL "${GITHUB_RAW}/assets/fake-sites/site-${site_num}/index.html" \
        -o /var/www/html/index.html; then
    chown -R www-data:www-data /var/www/html
    chmod 644 /var/www/html/index.html
    green "Fake site #${site_num} installed."
else
    red "Failed to download fake site (non-fatal)."
fi

# ─────────────────────────────────────────────────────────────────────────────
# NGINX TEST & RELOAD
# ─────────────────────────────────────────────────────────────────────────────
blue "Testing nginx config..."
if nginx -t 2>&1 | grep -q successful; then
    systemctl reload nginx
    green "nginx reloaded OK."
else
    red "nginx config test failed — check errors above."
    nginx -t
    exit 1
fi

# ─────────────────────────────────────────────────────────────────────────────
# RESULTS
# ─────────────────────────────────────────────────────────────────────────────
echo
green "══════════════════════════════════════════════"
green " Patch complete"
green "══════════════════════════════════════════════"
printf "\n  Panel:       https://%s/%s/\n"  "$domain" "$panel_path"
printf "  Diagnostics (panel login): https://%s/%s/diag\n"  "$domain" "$panel_path"
printf "  Diagnostics (direct):      https://%s%s\n"  "$domain" "$diag_path"
echo
