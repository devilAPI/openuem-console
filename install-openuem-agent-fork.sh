#!/usr/bin/env bash
#
# Installs or updates the OpenUEM agent built from the fork on Linux: Debian, Ubuntu
# and other Debian based systems, Arch Linux and its derivatives, and any other systemd
# distribution. The agent is a static Go binary, so it doesn't depend on the kernel
# version (mainline and LTS kernels work alike) or on the C library.
#
# install-openuem-fork.sh builds openuem-agent-fork-install.sh from this script: the
# certificates, the agent binaries (amd64, arm64) and the server settings are appended
# to it. Copy that file to the computer and run it as root:
#
#   sudo bash openuem-agent-fork-install.sh
#
# Options:
#   --org <id>           organization (tenant) ID, with --site: the computer is added to
#   --site <id>          this site instead of the default one. The IDs are in the console's
#                        address bar: .../tenant/<org id>/site/<site id>/... Only applies
#                        when the computer registers for the first time; move existing
#                        computers in the console (computer > Overview).
#   --domain <domain>    OpenUEM domain (console.<domain>, nats.<domain>, ocsp.<domain>),
#                        must resolve over DNS; no hosts entries are written
#   --nats-port <port>   NATS port (default: the server's)
#   --files-dir <dir>    take the files from a folder instead of the appended ones
#
# Example: sudo bash openuem-agent-fork-install.sh --org 2 --site 3
#
# The layout is the one of the official package: /opt/openuem-agent/bin/openuem-agent,
# /etc/openuem-agent/openuem.ini, /etc/openuem-agent/certificates and the systemd
# service openuem-agent. If the official package is installed, its binary is replaced
# (and saved as openuem-agent.official) and its settings are kept. Run it again to
# update the agent. Don't use "update agents" in the console for these computers, it
# would install the official agent again.

set -euo pipefail

FILES_DIR=""
ORG_ID=""
SITE_ID=""
OPT_DOMAIN=""
OPT_NATS_PORT=""
while [ $# -gt 0 ]; do
    case "$1" in
        --files-dir) FILES_DIR="${2:-}"; shift ;;
        --org | --tenant) ORG_ID="${2:-}"; shift ;;
        --site) SITE_ID="${2:-}"; shift ;;
        --domain) OPT_DOMAIN="${2:-}"; shift ;;
        --nats-port) OPT_NATS_PORT="${2:-}"; shift ;;
        -h | --help) sed -n '2,35p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this script as root, e.g. sudo bash $0"
command -v systemctl >/dev/null || die "systemd is required"
for tool in awk tar gzip getent useradd groupadd install timeout; do
    command -v "$tool" >/dev/null || die "$tool is missing, install it first (Debian: apt install $tool, Arch: pacman -S $tool)"
done

case "$(uname -m)" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported architecture $(uname -m), only amd64 and arm64 are built" ;;
esac

# --- Files --------------------------------------------------------------------
if [ -z "$FILES_DIR" ]; then
    payload_line="$(awk '/^__OPENUEM_PAYLOAD__$/ { print NR + 1; exit }' "$0")"
    [ -n "$payload_line" ] ||
        die "no files appended to this script: use openuem-agent-fork-install.sh from the server (agent-builds/latest/linux/) or --files-dir"
    FILES_DIR="$(mktemp -d)"
    trap 'rm -rf "$FILES_DIR"' EXIT
    chmod 700 "$FILES_DIR"
    tail -n +"$payload_line" "$0" | tar -xz -C "$FILES_DIR" || die "the appended files are damaged, copy the script again"
fi
for file in settings.env ca.cer agent.cer agent.key sftp.cer "linux-$ARCH/openuem-agent"; do
    [ -f "$FILES_DIR/$file" ] || die "$FILES_DIR/$file is missing"
done

# SERVER_IP, DOMAIN, NATS_PORT, SFTP_PORT, VNC_PORT, AGENT_COMMIT
# shellcheck disable=SC1091
. "$FILES_DIR/settings.env"
[ -z "$OPT_DOMAIN" ] || DOMAIN="$OPT_DOMAIN"
[ -z "$OPT_NATS_PORT" ] || NATS_PORT="$OPT_NATS_PORT"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "invalid domain: $DOMAIN"
[[ "$SERVER_IP" =~ ^[0-9A-Fa-f:.]+$ ]] || die "invalid server IP: $SERVER_IP"
[[ "$NATS_PORT" =~ ^[0-9]+$ ]] || die "invalid NATS port: $NATS_PORT"
# The server only accepts both IDs together and rejects the computer if they don't match
if [ -n "$ORG_ID$SITE_ID" ]; then
    [[ "$ORG_ID" =~ ^[0-9]+$ ]] && [[ "$SITE_ID" =~ ^[0-9]+$ ]] ||
        die "--org and --site must both be given as numbers (see the console's address bar: /tenant/<org>/site/<site>/)"
fi

info "Settings"
printf '    Server:  %s\n    Domain:  %s\n    NATS:    nats.%s:%s\n    Org:     %s\n    Build:   %s (%s)\n' \
    "$SERVER_IP" "$DOMAIN" "$DOMAIN" "$NATS_PORT" "$([ -n "$ORG_ID" ] && echo "org $ORG_ID, site $SITE_ID" || echo default)" "${AGENT_COMMIT:-unknown}" "$ARCH"

# --- Connection check -----------------------------------------------------------
# console.<domain>, nats.<domain> and ocsp.<domain> must resolve over DNS; this script
# does not write hosts entries
info "Checking the connection to nats.$DOMAIN:$NATS_PORT (DNS must resolve it)"
reachable=0
for _ in 1 2 3; do
    if timeout 10 bash -c ": </dev/tcp/nats.$DOMAIN/$NATS_PORT" 2>/dev/null; then
        reachable=1
        break
    fi
    sleep 3
done
[ "$reachable" = "1" ] ||
    die "can't reach nats.$DOMAIN:$NATS_PORT. Check the DNS records for $DOMAIN, the firewall and that the server is running"

# --- Agent --------------------------------------------------------------------
AGENT_DIR=/opt/openuem-agent
AGENT_BIN="$AGENT_DIR/bin/openuem-agent"
CONFIG_DIR=/etc/openuem-agent
CONFIG_FILE="$CONFIG_DIR/openuem.ini"
SERVICE_FILE=/etc/systemd/system/openuem-agent.service

FIRST_INSTALL=1
if [ -f "$CONFIG_FILE" ] && grep -Eq '^\s*UUID\s*=\s*\S' "$CONFIG_FILE"; then
    FIRST_INSTALL=0
fi
OFFICIAL_PACKAGE=0
if command -v dpkg-query >/dev/null && dpkg-query -W -f '${Status}' openuem-agent 2>/dev/null | grep -q "ok installed"; then
    OFFICIAL_PACKAGE=1
elif command -v pacman >/dev/null && pacman -Q openuem-agent >/dev/null 2>&1; then
    OFFICIAL_PACKAGE=1
elif command -v rpm >/dev/null && rpm -q openuem-agent >/dev/null 2>&1; then
    OFFICIAL_PACKAGE=1
fi

if [ "$FIRST_INSTALL" = "1" ]; then
    info "Installing the OpenUEM agent"
else
    info "The OpenUEM agent is already installed, updating it"
fi

if ! getent group openuem-agent >/dev/null; then
    groupadd -r openuem-agent
fi
if ! getent passwd openuem-agent >/dev/null; then
    useradd -r -g openuem-agent -M -d "$AGENT_DIR" -s "$(command -v nologin || echo /bin/false)" openuem-agent
fi

install -d -m 755 "$AGENT_DIR" "$AGENT_DIR/bin"
install -d -m 770 -o root -g openuem-agent "$CONFIG_DIR" /var/log/openuem-agent
install -d -m 750 -o root -g openuem-agent "$CONFIG_DIR/certificates"
# The certificates of the installed agent are replaced: they come from the same server
install -m 644 -o root -g openuem-agent "$FILES_DIR/ca.cer" "$FILES_DIR/agent.cer" "$FILES_DIR/sftp.cer" "$CONFIG_DIR/certificates/"
install -m 640 -o root -g openuem-agent "$FILES_DIR/agent.key" "$CONFIG_DIR/certificates/"

# An existing configuration (UUID, organization, settings changed by the console) is kept
if [ ! -f "$CONFIG_FILE" ]; then
    cat >"$CONFIG_FILE" <<EOF
[Agent]
UUID                     =
Enabled                  = true
ExecuteTaskEveryXMinutes = 5
Debug                    = false
DefaultFrequency         = 60
SFTPPort                 = ${SFTP_PORT}
VNCProxyPort             = ${VNC_PORT}
TenantID                 =
SiteID                   =

[NATS]
NATSServers = nats.${DOMAIN}:${NATS_PORT}

[Certificates]
CACert    = ${CONFIG_DIR}/certificates/ca.cer
AgentCert = ${CONFIG_DIR}/certificates/agent.cer
AgentKey  = ${CONFIG_DIR}/certificates/agent.key
SFTPCert  = ${CONFIG_DIR}/certificates/sftp.cer
EOF
fi
# Sets key = value in a section of the configuration
set_config() {
    local section="$1" key="$2" value="$3"
    if grep -Eq "^\s*${key}\s*=" "$CONFIG_FILE"; then
        sed -i -E "s|^\s*${key}\s*=.*|${key} = ${value}|" "$CONFIG_FILE"
    elif grep -q "^\[${section}\]" "$CONFIG_FILE"; then
        sed -i "/^\[${section}\]/a ${key} = ${value}" "$CONFIG_FILE"
    else
        printf '\n[%s]\n%s = %s\n' "$section" "$key" "$value" >>"$CONFIG_FILE"
    fi
}
set_config NATS NATSServers "nats.${DOMAIN}:${NATS_PORT}"
if [ -n "$ORG_ID" ]; then
    set_config Agent TenantID "$ORG_ID"
    set_config Agent SiteID "$SITE_ID"
    [ "$FIRST_INSTALL" = "1" ] ||
        warn "this computer is already registered: --org/--site only apply to new computers, move it in the console (computer > Overview)"
fi
chown root:openuem-agent "$CONFIG_FILE"
chmod 660 "$CONFIG_FILE"

if [ ! -f "$SERVICE_FILE" ]; then
    cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=OpenUEM Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${AGENT_BIN}
User=root
Group=openuem-agent
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi

systemctl stop openuem-agent 2>/dev/null || true
OFFICIAL_SAVED=0
if [ "$OFFICIAL_PACKAGE" = "1" ] && [ -f "$AGENT_BIN" ] && [ ! -f "$AGENT_BIN.official" ]; then
    cp -p "$AGENT_BIN" "$AGENT_BIN.official"
    OFFICIAL_SAVED=1
fi
install -m 755 "$FILES_DIR/linux-$ARCH/openuem-agent" "$AGENT_BIN.new"
mv -f "$AGENT_BIN.new" "$AGENT_BIN"

# The official updater would install the official agent again
if systemctl list-unit-files openuem-agent-updater.service >/dev/null 2>&1; then
    systemctl disable --now openuem-agent-updater >/dev/null 2>&1 || true
fi

systemctl daemon-reload
systemctl enable openuem-agent >/dev/null 2>&1
systemctl restart openuem-agent

# Software deployment uses Flathub when flatpak is installed
if command -v flatpak >/dev/null; then
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1 ||
        warn "could not add the Flathub repository"
fi

sleep 5
if ! systemctl is-active --quiet openuem-agent; then
    journalctl -u openuem-agent -n 20 --no-pager >&2 || true
    die "the openuem-agent service is not running, see the log above"
fi

printf '\n\033[1;32mOpenUEM agent service: running (fork build %s)\033[0m\n' "${AGENT_COMMIT:-unknown}"
if [ "$OFFICIAL_SAVED" = "1" ]; then
    echo "The official package's binary was saved as $AGENT_BIN.official"
elif [ "$OFFICIAL_PACKAGE" = "1" ]; then
    echo "The official package's binary is kept as $AGENT_BIN.official"
fi
[ "$FIRST_INSTALL" = "0" ] || echo "Next: admit this computer in https://console.${DOMAIN}:1323 (Agents)"
echo "Log: /var/log/openuem-agent/ and journalctl -u openuem-agent"
echo "Don't use 'update agents' in the console for this computer, it would replace the fork's agent."
exit 0
