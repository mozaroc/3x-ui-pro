#!/usr/bin/env bash
# x-ui-backup.sh — backup and restore 3x-ui panel + nginx + certs
# Usage:
#   x-ui-backup.sh backup           — create timestamped backup
#   x-ui-backup.sh restore <file>   — restore from backup archive
#   x-ui-backup.sh list             — list available backups
set -Eeuo pipefail

BACKUP_STORE="/var/backups/x-ui"
PACKAGES="nginx-full certbot python3 sqlite3 curl wget jq ufw mtr-tiny"

# ── paths to back up ──────────────────────────────────────────────────────────
BACKUP_PATHS=(
    /etc/nginx
    /etc/x-ui
    /usr/local/x-ui
    /usr/local/lib/3x-ui-pro
    /etc/letsencrypt
    /var/www/html
    /var/www/diagnostics
    /var/www/subpage
    /etc/ufw/user.rules
    /etc/ufw/user6.rules
)
SYSTEMD_UNITS=(x-ui.service mtr-backend.service)

# ── colours ───────────────────────────────────────────────────────────────────
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }
die()   { red "ERROR: $*" >&2; exit 1; }

require_root() { [[ $EUID -eq 0 ]] || die "Run as root (sudo $0 $*)"; }

# ── backup ────────────────────────────────────────────────────────────────────
cmd_backup() {
    require_root

    local ts name staging dest
    ts=$(date +%Y%m%d-%H%M%S)
    name="x-ui-backup-${ts}"
    staging=$(mktemp -d)
    trap 'rm -rf "${staging}"' EXIT

    mkdir -p "${BACKUP_STORE}"
    dest="${BACKUP_STORE}/${name}.tar.gz"

    blue "==> Stopping x-ui for consistent DB snapshot..."
    systemctl stop x-ui 2>/dev/null || true

    # ── collect filesystem paths ───────────────────────────────────────────
    blue "==> Collecting files..."
    local files_root="${staging}/files"
    for path in "${BACKUP_PATHS[@]}"; do
        [[ -e "${path}" ]] || continue
        local dst="${files_root}${path}"
        mkdir -p "$(dirname "${dst}")"
        cp -a "${path}" "${dst}"
    done

    # systemd units
    mkdir -p "${files_root}/etc/systemd/system"
    for unit in "${SYSTEMD_UNITS[@]}"; do
        [[ -f "/etc/systemd/system/${unit}" ]] && \
            cp "/etc/systemd/system/${unit}" "${files_root}/etc/systemd/system/"
    done

    # ── crontab ───────────────────────────────────────────────────────────
    crontab -l 2>/dev/null > "${staging}/root-crontab" || true

    if [[ -d /etc/cron.d ]]; then
        cp -a /etc/cron.d "${staging}/cron.d"
    fi

    # ── metadata ──────────────────────────────────────────────────────────
    local xui_ver
    xui_ver=$(x-ui version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "unknown")
    cat > "${staging}/meta.json" <<JSON
{
  "created":   "${ts}",
  "hostname":  "$(hostname -f 2>/dev/null || hostname)",
  "x-ui":      "${xui_ver}",
  "kernel":    "$(uname -r)",
  "packages":  "${PACKAGES}"
}
JSON

    blue "==> Restarting x-ui..."
    systemctl start x-ui 2>/dev/null || true

    # ── compress ──────────────────────────────────────────────────────────
    blue "==> Compressing..."
    tar -czf "${dest}" -C "${staging}" .

    local size
    size=$(du -sh "${dest}" | cut -f1)
    green "==> Backup saved: ${dest} (${size})"
}

# ── restore ───────────────────────────────────────────────────────────────────
cmd_restore() {
    require_root

    local backup_file="${1:-}"
    [[ -n "${backup_file}" ]] || die "Usage: $0 restore <backup.tar.gz>"
    [[ -f "${backup_file}" ]]  || die "File not found: ${backup_file}"

    local staging
    staging=$(mktemp -d)
    trap 'rm -rf "${staging}"' EXIT

    blue "==> Extracting backup: ${backup_file}"
    tar -xzf "${backup_file}" -C "${staging}"

    if [[ -f "${staging}/meta.json" ]]; then
        blue "==> Backup metadata:"
        cat "${staging}/meta.json"
        echo
    fi

    # ── install packages ──────────────────────────────────────────────────
    blue "==> Installing packages..."
    apt-get update -qq
    # shellcheck disable=SC2086
    DEBIAN_FRONTEND=noninteractive apt-get install -y ${PACKAGES}

    # ── stop running services ─────────────────────────────────────────────
    blue "==> Stopping services..."
    for svc in nginx x-ui mtr-backend; do
        systemctl stop "${svc}" 2>/dev/null || true
    done

    # ── restore files ─────────────────────────────────────────────────────
    blue "==> Restoring files..."
    if [[ -d "${staging}/files" ]]; then
        cp -a "${staging}/files/." /
    fi

    # ── permissions ───────────────────────────────────────────────────────
    chown -R www-data:www-data /var/www/html        2>/dev/null || true
    chown -R www-data:www-data /var/www/diagnostics 2>/dev/null || true
    chown -R www-data:www-data /var/www/subpage     2>/dev/null || true
    [[ -f /usr/local/x-ui/x-ui ]] && chmod +x /usr/local/x-ui/x-ui
    find /usr/local/lib/3x-ui-pro -name "*.py" -exec chmod +x {} \; 2>/dev/null || true

    # ── recreate mtr-backend system user if missing ───────────────────────
    id mtr-backend &>/dev/null || \
        useradd --system --no-create-home --shell /usr/sbin/nologin mtr-backend

    # grant mtr net_raw capability
    if command -v setcap &>/dev/null && command -v mtr &>/dev/null; then
        setcap cap_net_raw+ep "$(command -v mtr)" 2>/dev/null || true
    fi

    # ── systemd ───────────────────────────────────────────────────────────
    blue "==> Enabling and starting services..."
    systemctl daemon-reload

    for svc in x-ui mtr-backend; do
        systemctl enable "${svc}" 2>/dev/null || true
        systemctl start  "${svc}" 2>/dev/null || true
    done

    # nginx: test config before starting
    if nginx -t 2>/dev/null; then
        systemctl enable nginx
        systemctl restart nginx
        green "    nginx restarted OK"
    else
        red "    nginx config test failed — fix manually:"
        nginx -t
    fi

    # ── crontab ───────────────────────────────────────────────────────────
    blue "==> Restoring cron..."
    if [[ -s "${staging}/root-crontab" ]]; then
        crontab - < "${staging}/root-crontab"
        green "    Root crontab restored"
    fi

    if [[ -d "${staging}/cron.d" ]]; then
        cp -a "${staging}/cron.d/." /etc/cron.d/
        green "    /etc/cron.d restored"
    fi

    # ── UFW ───────────────────────────────────────────────────────────────
    blue "==> Restoring UFW..."
    # user.rules were already copied by file restore; just (re-)enable
    ufw --force enable 2>/dev/null || true
    green "    UFW enabled"

    echo
    green "==> Restore complete."
    green "    Check status with:"
    green "      systemctl status x-ui nginx mtr-backend"
}

# ── list ──────────────────────────────────────────────────────────────────────
cmd_list() {
    if [[ ! -d "${BACKUP_STORE}" ]]; then
        echo "No backups found (${BACKUP_STORE} does not exist)"
        return
    fi

    local archives
    mapfile -t archives < <(ls -t "${BACKUP_STORE}"/*.tar.gz 2>/dev/null)

    if [[ ${#archives[@]} -eq 0 ]]; then
        echo "No backups in ${BACKUP_STORE}"
        return
    fi

    blue "Backups in ${BACKUP_STORE}:"
    for f in "${archives[@]}"; do
        printf "  %-55s  %s\n" "$(basename "${f}")" "$(du -sh "${f}" | cut -f1)"
    done
}

# ── entry point ───────────────────────────────────────────────────────────────
case "${1:-}" in
    backup)  cmd_backup ;;
    restore) cmd_restore "${2:-}" ;;
    list)    cmd_list ;;
    *)
        cat <<EOF
Usage: $(basename "$0") {backup|restore <file>|list}

  backup            create timestamped backup in ${BACKUP_STORE}/
  restore <file>    restore from backup archive (installs packages first)
  list              list available backups

What is backed up:
  /etc/nginx                      nginx config
  /etc/x-ui                       panel DB + config
  /usr/local/x-ui                 panel binary
  /usr/local/lib/3x-ui-pro        mtr-backend script
  /etc/letsencrypt                SSL certificates
  /var/www/{html,diagnostics,subpage}  web content
  /etc/systemd/system/{x-ui,mtr-backend}.service
  /etc/ufw/user*.rules            firewall rules
  root crontab + /etc/cron.d/
EOF
        exit 1
        ;;
esac
