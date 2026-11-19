#!/usr/bin/env bash
#
# Installs or updates the OpenUEM agent built from the fork on Linux: Debian, Ubuntu
# and other apt based systems, RedHat/Fedora/AlmaLinux and other dnf based systems,
# and any other systemd distribution (e.g. Arch Linux). The agent is a static Go
# binary, so it doesn't depend on the kernel version (mainline and LTS kernels work
# alike) or on the C library.
#
# The installation is the official one (https://openuem.eu/docs/Installation/Agent/linux),
# only the agent binary is swapped for the fork's build at the end:
#   1. install the official package: "apt install openuem-agent" from the OpenUEM
#      repository, or a downloaded .deb (bundled in this script), or "dnf install
#      openuem-agent" from the OpenUEM RPM repository; on distributions without apt/dnf
#      (e.g. Arch) the bundled official .deb is extracted, which installs the same
#      official layout (/opt/openuem-agent/bin, /etc/systemd/system units)
#   2. configure it with the package's own mechanism: debconf preseed on apt systems,
#      otherwise /etc/openuem-agent/openuem.ini ([NATS] NATSServers=..., SFTPPort,
#      VNCProxyPort, TenantID, SiteID)
#   3. place the certificates into /etc/openuem-agent/certificates/ (ca.cer, sftp.cer,
#      agent.cer, agent.key)
#   4. systemctl restart openuem-agent
#   5. fork only: disable the official updater (openuem-agent-updater, so the fork's
#      binary is not replaced again) and replace /opt/openuem-agent/bin/openuem-agent
#      with the fork's binary; the official one is kept as openuem-agent.official
#
# install-openuem-fork.sh builds openuem-agent-fork-install.sh from this script: the
# certificates, the agent binaries (amd64, arm64), the official .deb packages and the
# server settings are appended to it. Copy that file to the computer and run it as root:
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
#   --server-ip <ip>     server IP, only shown in the output (default: the server's)
#   --files-dir <dir>    take the files from a folder instead of the appended ones
#
# Example: sudo bash openuem-agent-fork-install.sh --org 2 --site 3
#
# Run it again to update the agent to the latest build on the server. Don't use
# "update agents" in the console for these computers, it would install the official
# agent again (the official updater service is disabled).

set -euo pipefail

FILES_DIR=""
ORG_ID=""
SITE_ID=""
OPT_DOMAIN=""
OPT_NATS_PORT=""
OPT_SERVER_IP=""
while [ $# -gt 0 ]; do
    case "$1" in
        --files-dir) FILES_DIR="${2:-}"; shift ;;
        --org | --tenant) ORG_ID="${2:-}"; shift ;;
        --site) SITE_ID="${2:-}"; shift ;;
        --domain) OPT_DOMAIN="${2:-}"; shift ;;
        --nats-port) OPT_NATS_PORT="${2:-}"; shift ;;
        --server-ip) OPT_SERVER_IP="${2:-}"; shift ;;
        -h | --help) sed -n '2,48p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this script as root, e.g. sudo bash $0"
command -v systemctl >/dev/null || die "systemd is required"
for tool in awk tar gzip getent useradd groupadd install timeout sed; do
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

# SERVER_IP, DOMAIN, NATS_PORT, SFTP_PORT, VNC_PORT, AGENT_COMMIT, OFFICIAL_AGENT_VERSION
# shellcheck disable=SC1091
. "$FILES_DIR/settings.env"
[ -z "$OPT_DOMAIN" ] || DOMAIN="$OPT_DOMAIN"
[ -z "$OPT_NATS_PORT" ] || NATS_PORT="$OPT_NATS_PORT"
[ -z "$OPT_SERVER_IP" ] || SERVER_IP="$OPT_SERVER_IP"
OFFICIAL_AGENT_VERSION="${OFFICIAL_AGENT_VERSION:-0.11.0}"
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

# --- Official layout ------------------------------------------------------------
AGENT_DIR=/opt/openuem-agent
AGENT_BIN="$AGENT_DIR/bin/openuem-agent"
CONFIG_DIR=/etc/openuem-agent
CONFIG_FILE="$CONFIG_DIR/openuem.ini"
CERT_DIR="$CONFIG_DIR/certificates"
UPDATER_SERVICE=openuem-agent-updater
OFFICIAL_DEB_FILE="$FILES_DIR/official/openuem-agent_${OFFICIAL_AGENT_VERSION}_${ARCH}.deb"

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

# The official package's postinst creates this user; the extract path needs it too
if ! getent group openuem-agent >/dev/null; then
    groupadd -r openuem-agent
fi
if ! getent passwd openuem-agent >/dev/null; then
    useradd -r -g openuem-agent -M -d "$AGENT_DIR" -s "$(command -v nologin || echo /usr/sbin/nologin)" openuem-agent
fi

# --- 1. Install the official package --------------------------------------------
# apt: debconf preseed + "apt install openuem-agent" (repository) or the bundled .deb;
# dnf: "dnf install openuem-agent" from the OpenUEM RPM repository; otherwise (e.g. Arch)
# the bundled official .deb is extracted, which installs the official layout and units
preseed_debconf() {
    command -v debconf-set-selections >/dev/null || apt-get install -y -qq debconf >/dev/null
    {
        printf 'openuem-agent openuem-agent/nats-server string nats.%s:%s\n' "$DOMAIN" "$NATS_PORT"
        printf 'openuem-agent openuem-agent/sftp-port string %s\n' "$SFTP_PORT"
        printf 'openuem-agent openuem-agent/vnc-proxy-port string %s\n' "$VNC_PORT"
        if [ -n "$ORG_ID" ]; then printf 'openuem-agent openuem-agent/org string %s\n' "$ORG_ID"; fi
        if [ -n "$SITE_ID" ]; then printf 'openuem-agent openuem-agent/site string %s\n' "$SITE_ID"; fi
    } | debconf-set-selections
}

ensure_openuem_apt_repo() {
    apt-get install -y -qq curl gnupg >/dev/null 2>&1 || true
    install -m 0755 -d /etc/apt/keyrings
    if [ ! -s /usr/share/keyrings/openuem.gpg ]; then
        curl -fsSL https://apt.openuem.eu/pgp-key.public | gpg --dearmor -o /usr/share/keyrings/openuem.gpg
    fi
    printf 'deb [arch=%s signed-by=/usr/share/keyrings/openuem.gpg] https://apt.openuem.eu stable main\n' "$ARCH" \
        >/etc/apt/sources.list.d/openuem.list
    apt-get update -qq
}

extract_deb() {
    local deb="$1" member tmp
    if command -v dpkg-deb >/dev/null; then
        dpkg-deb -x "$deb" /
    elif command -v bsdtar >/dev/null; then
        # libarchive reads the data.tar.* payload of a .deb directly
        bsdtar -xf "$deb" -C /
    elif command -v ar >/dev/null; then
        tmp="$(mktemp -d)"
        member="$(ar t "$deb" | grep -E '^data\.tar\.' | head -n1)"
        [ -n "$member" ] || die "no data.tar.* in $deb"
        ar p "$deb" "$member" >"$tmp/data.tar"
        tar -xf "$tmp/data.tar" -C /
        rm -rf "$tmp"
    else
        die "cannot extract $deb: install dpkg-deb, bsdtar (libarchive) or ar (binutils) first"
    fi
}

PACKAGE_MANAGER=""
if command -v apt-get >/dev/null; then
    PACKAGE_MANAGER=apt
elif command -v dnf >/dev/null; then
    PACKAGE_MANAGER=dnf
fi

if [ "$FIRST_INSTALL" = "1" ]; then
    info "Installing the official OpenUEM agent package"
else
    info "The OpenUEM agent is already installed, updating the official package and then the fork's agent"
fi

case "$PACKAGE_MANAGER" in
    apt)
        apt-get update -qq || true
        # debconf preseed: the package's config script loops until nats-server is set,
        # so an unattended install without it would hang forever
        preseed_debconf
        if [ -f "$OFFICIAL_DEB_FILE" ]; then
            info "Installing the bundled official package $(basename "$OFFICIAL_DEB_FILE")"
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --allow-downgrades "$OFFICIAL_DEB_FILE" || {
                warn "installing the bundled .deb failed, trying the OpenUEM repository instead"
                ensure_openuem_apt_repo
                DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openuem-agent
            }
        else
            info "No bundled .deb in this script, installing openuem-agent from the OpenUEM repository"
            ensure_openuem_apt_repo
            DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openuem-agent
        fi
        # So that a later apt upgrade doesn't replace the fork's binary again
        apt-mark hold openuem-agent >/dev/null 2>&1 || true
        ;;
    dnf)
        info "Installing openuem-agent from the OpenUEM RPM repository"
        cat >/etc/yum.repos.d/openuem.repo <<'REPO_EOF'
[openuem]
name=OpenUEM
baseurl=https://rpm.openuem.eu/packages
enabled=1
gpgcheck=1
gpgkey=https://rpm.openuem.eu/pgp-key.public
REPO_EOF
        curl -fsSL https://rpm.openuem.eu/pgp-key.public -o /tmp/openuem-pgp.key
        rpm --import /tmp/openuem-pgp.key
        rm -f /tmp/openuem-pgp.key
        dnf install -y openuem-agent
        ;;
    *)
        [ -f "$OFFICIAL_DEB_FILE" ] ||
            die "this system has neither apt nor dnf and this script bundles no official .deb: use openuem-agent-fork-install.sh from the server (agent-builds/latest/linux/) or --files-dir"
        info "No apt/dnf here (e.g. Arch Linux): extracting the bundled official package $(basename "$OFFICIAL_DEB_FILE"), which installs the official layout and systemd units"
        extract_deb "$OFFICIAL_DEB_FILE"
        ;;
esac

# The package's postinst started the services with the official binary and without the
# certificates yet: stop them until the fork's binary and the certificates are in place
systemctl stop openuem-agent 2>/dev/null || true
systemctl stop "$UPDATER_SERVICE" 2>/dev/null || true

# --- 2./3. Certificates (official location) and configuration -------------------
install -d -m 770 "$CONFIG_DIR" "$CERT_DIR" /var/log/openuem-agent
chown root:openuem-agent /var/log/openuem-agent
# The certificates of the installed agent are replaced: they come from the same server
install -m 644 "$FILES_DIR/ca.cer" "$FILES_DIR/agent.cer" "$FILES_DIR/sftp.cer" "$CERT_DIR/"
install -m 640 "$FILES_DIR/agent.key" "$CERT_DIR/"

# An existing configuration (UUID, organization, settings changed by the console) is
# kept, like the package's postinst does: it only writes openuem.ini when it's missing
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
CACert    = ${CERT_DIR}/ca.cer
AgentCert = ${CERT_DIR}/agent.cer
AgentKey  = ${CERT_DIR}/agent.key
SFTPCert  = ${CERT_DIR}/sftp.cer
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
chown openuem-agent:openuem-agent "$CONFIG_FILE"
chmod 660 "$CONFIG_FILE"
# Same ownership and permissions as the package's postinst
chown -R openuem-agent:openuem-agent "$CONFIG_DIR"
chmod -R ug+rwX,o-rwx "$CERT_DIR"

# --- 4./5. Fork's agent: swap the binary, disable the official updater -----------
OFFICIAL_SAVED=0
if [ -f "$AGENT_BIN" ] && [ ! -f "$AGENT_BIN.official" ]; then
    cp -p "$AGENT_BIN" "$AGENT_BIN.official"
    OFFICIAL_SAVED=1
fi
install -m 755 "$FILES_DIR/linux-$ARCH/openuem-agent" "$AGENT_BIN.new"
mv -f "$AGENT_BIN.new" "$AGENT_BIN"
chown -R openuem-agent:openuem-agent "$AGENT_DIR" 2>/dev/null || true

# The official updater (and "update agents" in the console) would install the official
# agent again and replace the fork's binary
if systemctl list-unit-files "$UPDATER_SERVICE".service >/dev/null 2>&1; then
    systemctl disable --now "$UPDATER_SERVICE" >/dev/null 2>&1 || true
fi

systemctl daemon-reload
systemctl enable openuem-agent >/dev/null 2>&1 || true
systemctl restart openuem-agent

# Software deployment uses Flathub when flatpak is installed (the official postinst does this too)
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
elif [ -f "$AGENT_BIN.official" ]; then
    echo "The official package's binary is kept as $AGENT_BIN.official"
fi
[ "$FIRST_INSTALL" = "0" ] || echo "Next: admit this computer in https://console.${DOMAIN}:1323 (Agents)"
echo "Log: /var/log/openuem-agent/ and journalctl -u openuem-agent"
echo "Don't use 'update agents' in the console for this computer, it would replace the fork's agent (the official updater service is disabled)."
exit 0
