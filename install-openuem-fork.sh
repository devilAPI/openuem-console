#!/usr/bin/env bash
#
# Installs OpenUEM on a fresh Debian 13 (trixie) server using the official
# openuem-docker compose stack, with the console built from a fork.
#
# Usage (as root):
#   curl -fsSL https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-fork.sh | bash
#
# Settings can be given as environment variables, e.g.:
#   curl -fsSL ... | OPENUEM_DOMAIN=uem.example.org ORG_NAME="ACME" ORG_COUNTRY=DE bash
#
# Running the script again on an existing installation updates it: the official
# containers are pulled again, the fork's branches are pulled, the console image and
# the agents are rebuilt and the console is restarted. The settings (.env), the
# certificates and the database are kept; settings added upstream are appended to .env.

set -euo pipefail

# ----------------------------------------------------------------------------
# Settings
# ----------------------------------------------------------------------------
INSTALL_DIR="${INSTALL_DIR:-/opt/openuem}"

OPENUEM_DOCKER_REPO="${OPENUEM_DOCKER_REPO:-https://github.com/open-uem/openuem-docker}"
OPENUEM_DOCKER_REF="${OPENUEM_DOCKER_REF:-main}"

CONSOLE_REPO="${CONSOLE_REPO:-https://github.com/devilAPI/openuem-console}"
CONSOLE_BRANCH="${CONSOLE_BRANCH:-feature/bulk-software-updates}"

AGENT_REPO="${AGENT_REPO:-https://github.com/devilAPI/openuem-agent}"
AGENT_BRANCH="${AGENT_BRANCH:-feature/bulk-software-updates}"
BUILD_AGENTS="${BUILD_AGENTS:-1}"
# The Windows setup program openuem-agent-fork-setup.exe bundles the official agent
# installer of this version, the fork's agent, the certificates and
# install-openuem-agent-fork.ps1 (taken from next to this script or downloaded).
# It is built with Inno Setup, like the official openuem-agent-setup.exe.
OFFICIAL_AGENT_VERSION="${OFFICIAL_AGENT_VERSION:-0.11.0}"
INNO_SETUP_VERSION="${INNO_SETUP_VERSION:-6.6.1}"
# GitHub release tag of the Inno Setup compiler, e.g. is-6_6_1
INNO_SETUP_TAG="${INNO_SETUP_TAG:-is-$(echo "$INNO_SETUP_VERSION" | tr . _)}"
AGENT_SCRIPT_URL="${AGENT_SCRIPT_URL:-https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1}"
# The Linux installer openuem-agent-fork-install.sh is built from this script and also
# bundles the official .deb packages (amd64, arm64) from the OpenUEM apt repository
AGENT_LINUX_SCRIPT_URL="${AGENT_LINUX_SCRIPT_URL:-https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.sh}"
AGENT_SFTP_PORT="${AGENT_SFTP_PORT:-2022}"
AGENT_VNC_PORT="${AGENT_VNC_PORT:-1443}"

# The agents worker sends the computers their profiles. The fork's installs packages of
# the software library from the console's winget repository. If the repository isn't
# available, the official worker is used.
WORKER_REPO="${WORKER_REPO:-https://github.com/devilAPI/openuem-worker}"
WORKER_BRANCH="${WORKER_BRANCH:-software-updates}"

OPENUEM_DOMAIN="${OPENUEM_DOMAIN:-}"
ORG_NAME="${ORG_NAME:-OpenUEM}"
ORG_PROVINCE="${ORG_PROVINCE:-}"
ORG_LOCALITY="${ORG_LOCALITY:-}"
ORG_ADDRESS="${ORG_ADDRESS:-}"
ORG_COUNTRY="${ORG_COUNTRY:-DE}"
SERVER_IP="${SERVER_IP:-}"
# Add console/nats/ocsp names to this server's /etc/hosts when DNS doesn't resolve them
ADD_HOSTS_ENTRIES="${ADD_HOSTS_ENTRIES:-1}"
# Set to 1 to install on something other than Debian 13
FORCE="${FORCE:-0}"

# The folder of this script, empty when it's piped into bash
SCRIPT_DIR=""
if [ -f "${BASH_SOURCE[0]:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

FORK_IMAGE="openuem-console-fork"
WORKER_IMAGE="openuem-worker-fork"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# Runs a command up to 3 times. Downloads from the Go module proxy and Docker Hub fail
# now and then ("stream error", "connection reset"); a second try usually works.
retry() {
    local attempt
    for attempt in 1 2 3; do
        "$@" && return 0
        [ "$attempt" = 3 ] && return 1
        warn "attempt $attempt of 3 failed, trying again in 20 seconds"
        sleep 20
    done
}

# Ask a question even when the script is piped into bash
ask() {
    local prompt="$1" default="$2" answer=""
    if [ -r /dev/tty ]; then
        read -r -p "$prompt [$default]: " answer </dev/tty || true
    fi
    printf '%s' "${answer:-$default}"
}

# Set KEY=value in the .env file, replacing the existing line
set_env() {
    local key="$1" value="$2" file="$INSTALL_DIR/.env"
    value="${value//\\/\\\\}"
    value="${value//&/\\&}"
    value="${value//|/\\|}"
    if grep -q "^${key}=" "$file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    else
        printf '%s=%s\n' "$key" "$value" >>"$file"
    fi
}

get_env() {
    grep "^$1=" "$INSTALL_DIR/.env" | head -n1 | cut -d= -f2- | tr -d '"'
}

# Clone a repository or update it to the latest commit of a branch
sync_repo() {
    local repo="$1" ref="$2" dir="$3"
    if [ -d "$dir/.git" ]; then
        git -C "$dir" fetch --quiet origin "$ref"
        git -C "$dir" checkout --quiet -B "$ref" FETCH_HEAD
    else
        git clone --quiet --branch "$ref" "$repo" "$dir"
    fi
    printf '%s @ %s\n' "$(basename "$dir")" "$(git -C "$dir" rev-parse --short HEAD)"
}

# ----------------------------------------------------------------------------
# Checks
# ----------------------------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "run this script as root (e.g. with sudo -i)"

# shellcheck disable=SC1091
. /etc/os-release
if [ "${ID:-}" != "debian" ] || [ "${VERSION_CODENAME:-}" != "trixie" ]; then
    [ "$FORCE" = "1" ] || die "this script is meant for Debian 13 (trixie), found ${PRETTY_NAME:-unknown}. Set FORCE=1 to continue anyway"
    warn "not Debian 13 (${PRETTY_NAME:-unknown}), continuing because FORCE=1"
fi

FIRST_INSTALL=0
[ -f "$INSTALL_DIR/.env" ] || FIRST_INSTALL=1
if [ "$FIRST_INSTALL" = "1" ]; then
    info "Installing OpenUEM in $INSTALL_DIR"
else
    info "Existing installation found in $INSTALL_DIR, updating it"
fi

if [ "$FIRST_INSTALL" = "1" ]; then
    [ -n "$SERVER_IP" ] || SERVER_IP="$(hostname -I | awk '{print $1}')"
    [ -n "$OPENUEM_DOMAIN" ] || OPENUEM_DOMAIN="$(ask "Domain for OpenUEM (console.<domain>, nats.<domain> and ocsp.<domain> will be used)" "openuem.example")"
    [ -n "$OPENUEM_DOMAIN" ] || die "OPENUEM_DOMAIN is required"
    [ ${#ORG_COUNTRY} -eq 2 ] || die "ORG_COUNTRY must be a two letter country code, e.g. DE"
fi

# ----------------------------------------------------------------------------
# Packages and Docker
# ----------------------------------------------------------------------------
info "Installing required packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git openssl >/dev/null

if ! docker compose version >/dev/null 2>&1; then
    info "Installing Docker Engine from Docker's repository"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker compose version

# ----------------------------------------------------------------------------
# Sources
# ----------------------------------------------------------------------------
info "Fetching sources"
mkdir -p "$INSTALL_DIR"
if [ -d "$INSTALL_DIR/.git" ]; then
    git -C "$INSTALL_DIR" pull --quiet --ff-only || warn "could not update openuem-docker, keeping the current version"
    printf 'openuem-docker @ %s\n' "$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
elif [ -z "$(ls -A "$INSTALL_DIR")" ]; then
    git clone --quiet --branch "$OPENUEM_DOCKER_REF" "$OPENUEM_DOCKER_REPO" "$INSTALL_DIR"
    printf 'openuem-docker @ %s\n' "$(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
else
    die "$INSTALL_DIR exists and is not an openuem-docker checkout"
fi

mkdir -p "$INSTALL_DIR/src"
sync_repo "$CONSOLE_REPO" "$CONSOLE_BRANCH" "$INSTALL_DIR/src/openuem-console"
if [ "$BUILD_AGENTS" = "1" ]; then
    sync_repo "$AGENT_REPO" "$AGENT_BRANCH" "$INSTALL_DIR/src/openuem-agent"
fi
BUILD_WORKER=0
if git ls-remote --exit-code --heads "$WORKER_REPO" "$WORKER_BRANCH" >/dev/null 2>&1; then
    sync_repo "$WORKER_REPO" "$WORKER_BRANCH" "$INSTALL_DIR/src/openuem-worker"
    BUILD_WORKER=1
else
    warn "${WORKER_REPO} (${WORKER_BRANCH}) isn't available, the official agents worker is used: profiles can't install packages of the software library"
fi

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
if [ "$FIRST_INSTALL" = "1" ]; then
    info "Creating $INSTALL_DIR/.env"
    cp "$INSTALL_DIR/.env-example" "$INSTALL_DIR/.env"
    chmod 600 "$INSTALL_DIR/.env"

    set_env DATABASE_PASSWORD "$(openssl rand -hex 24)"
    set_env CONSOLE_JWT_KEY "$(openssl rand -hex 16)"
    set_env OPENUEM_DOMAIN "$OPENUEM_DOMAIN"
    set_env OPENUEM_ORGNAME "\"$ORG_NAME\""
    set_env OPENUEM_ORGPROVINCE "\"$ORG_PROVINCE\""
    set_env OPENUEM_ORGLOCALITY "\"$ORG_LOCALITY\""
    set_env OPENUEM_ORGADDRESS "\"$ORG_ADDRESS\""
    set_env OPENUEM_ORGCOUNTRY "\"$ORG_COUNTRY\""
    set_env TZ "$(timedatectl show -p Timezone --value 2>/dev/null || echo UTC)"
else
    info "Keeping the existing $INSTALL_DIR/.env"
    OPENUEM_DOMAIN="$(get_env OPENUEM_DOMAIN)"
    [ -n "$SERVER_IP" ] || SERVER_IP="$(hostname -I | awk '{print $1}')"

    # Settings introduced upstream since the installation get their default value
    while IFS= read -r line; do
        key="${line%%=*}"
        if ! grep -q "^${key}=" "$INSTALL_DIR/.env"; then
            printf '%s\n' "$line" >>"$INSTALL_DIR/.env"
            printf 'Added new setting %s\n' "$key"
        fi
    done < <(grep -E '^[A-Z_][A-Z0-9_]*=' "$INSTALL_DIR/.env-example")

    # The reset flag would reset the openuem user on every restart
    if [ "$(get_env CONSOLE_RESET_OPENUEM_USER)" = "true" ]; then
        set_env CONSOLE_RESET_OPENUEM_USER ""
        warn "CONSOLE_RESET_OPENUEM_USER was set, it has been cleared"
    fi
fi

CONSOLE_PORT="$(get_env CONSOLE_PORT)"
CONSOLE_AUTH_PORT="$(get_env CONSOLE_AUTH_PORT)"
NATS_PORT="$(get_env NATS_PORT)"
OCSP_PORT="$(get_env OCSP_PORT)"

# The upstream compose file only has network aliases for openuem.example, containers
# don't read the host's /etc/hosts, so aliases are added for the chosen domain
mkdir -p "$INSTALL_DIR/winget-repository"
chmod 700 "$INSTALL_DIR/winget-repository"

# The openuem-certs container rewrites nats.cfg every time it starts, so the permissions
# the fork needs are added by this script, which the container runs right after
mkdir -p "$INSTALL_DIR/fork"
cat >"$INSTALL_DIR/fork/nats-permissions.sh" <<'NATS_PERMISSIONS_EOF'
#!/bin/bash
# Adds the NATS permissions needed by the fork to nats.cfg. The openuem-certs container
# regenerates nats.cfg every time it starts, so it runs this script right after.
set -u
cfg="${1:-/etc/nats/nats.cfg}"

# Agents may only subscribe to an explicit list of subjects. The fork's agent needs more:
# to list the available updates, to start update runs and to register the winget repository.
for subject in listpackageupdates updatepackages wingetsource; do
    grep -q "\"agent.${subject}.> openuem-agent-management\"" "$cfg" && continue
    sed -i "s|\"agent.runprofile.> openuem-agent-management\"|&, \"agent.${subject}.> openuem-agent-management\"|" "$cfg"
done

# The console elects a leader with a key-value bucket to fill the package database used by
# the package search, and the update status page reads queued requests from AGENTS_STREAM
# shellcheck disable=SC2016 # NATS subject names, the $ is literal
for permission in '$JS.API.INFO' '$JS.API.STREAM.INFO.KV_leaders' '$JS.API.DIRECT.GET.KV_leaders.>' '$JS.API.CONSUMER.CREATE.KV_leaders.>' '$KV.leaders.openuem' '$JS.API.STREAM.MSG.GET.AGENTS_STREAM'; do
    sed -n '/CN=OpenUEM Console/,/publish:/p' "$cfg" | grep -qF "\"$permission\"" && continue
    sed -i "/CN=OpenUEM Console/,/publish:/ s|publish: \[|publish: [\"$permission\", |" "$cfg"
done

# Never fail: NATS must start even if the format of nats.cfg changed
if grep -q '"agent.updatepackages.> openuem-agent-management"' "$cfg"; then
    echo "NATS permissions for the fork are set"
else
    echo "WARNING: could not add the fork's permissions to $cfg, software updates won't work" >&2
fi
exit 0
NATS_PERMISSIONS_EOF
chmod 755 "$INSTALL_DIR/fork/nats-permissions.sh"

# The fork's agents worker, if it's built
AGENTS_WORKER_IMAGE=""
if [ "$BUILD_WORKER" = "1" ]; then
    AGENTS_WORKER_IMAGE="    image: ${WORKER_IMAGE}:latest"$'\n'"    pull_policy: never"$'\n'
fi

info "Writing $INSTALL_DIR/compose.override.yml"
cat >"$INSTALL_DIR/compose.override.yml" <<EOF
# Generated by install-openuem-fork.sh. Delete this file and run
# 'docker compose up -d' to go back to the official console image.
services:
  console:
    image: ${FORK_IMAGE}:latest
    pull_policy: never
    # The packages of the software library must survive container updates
    volumes:
      - "./winget-repository:/bin/winget-repository:z"
    networks:
      openuem:
        aliases:
          - console.${OPENUEM_DOMAIN}
  openuem-certs:
    # Runs the official configuration and then adds the NATS permissions of the fork
    entrypoint: ["/bin/bash", "-c", "/bin/configure.sh && /bin/bash /fork/nats-permissions.sh /etc/nats/nats.cfg"]
    volumes:
      - "./fork/nats-permissions.sh:/fork/nats-permissions.sh:ro,z"
  nats-server:
    networks:
      openuem:
        aliases:
          - nats.${OPENUEM_DOMAIN}
  ocsp-responder:
    environment:
      - ENV=prod
    networks:
      openuem:
        aliases:
          - ocsp.${OPENUEM_DOMAIN}
  # Only the console, built from the current code, migrates the database. The published
  # images are older and would drop the columns the console adds.
  notification-worker:
    environment:
      - ENV=prod
  cert-manager-worker:
    environment:
      - ENV=prod
  agents-worker:
${AGENTS_WORKER_IMAGE}    environment:
      - ENV=prod
EOF

if [ "$ADD_HOSTS_ENTRIES" = "1" ]; then
    for name in console nats ocsp; do
        host="${name}.${OPENUEM_DOMAIN}"
        if ! getent hosts "$host" >/dev/null; then
            printf '%s %s # openuem\n' "$SERVER_IP" "$host" >>/etc/hosts
            warn "$host doesn't resolve, added it to this server's /etc/hosts. Your computers need a DNS record for it too"
        fi
    done
fi

# ----------------------------------------------------------------------------
# Console image from the fork
# ----------------------------------------------------------------------------
CONSOLE_COMMIT="$(git -C "$INSTALL_DIR/src/openuem-console" rev-parse --short HEAD)"
info "Building the console image from ${CONSOLE_REPO} (${CONSOLE_BRANCH} @ ${CONSOLE_COMMIT}), this takes a few minutes"
retry docker build --pull -t "${FORK_IMAGE}:${CONSOLE_COMMIT}" -t "${FORK_IMAGE}:latest" "$INSTALL_DIR/src/openuem-console" ||
    die "the console image could not be built, see the output above. If it's a download error, run the script again"

if [ "$BUILD_WORKER" = "1" ]; then
    WORKER_COMMIT="$(git -C "$INSTALL_DIR/src/openuem-worker" rev-parse --short HEAD)"
    info "Building the agents worker image from ${WORKER_REPO} (${WORKER_BRANCH} @ ${WORKER_COMMIT})"
    retry docker build --pull -t "${WORKER_IMAGE}:${WORKER_COMMIT}" -t "${WORKER_IMAGE}:latest" "$INSTALL_DIR/src/openuem-worker" ||
        die "the agents worker image could not be built, see the output above. If it's a download error, run the script again"
fi

# ----------------------------------------------------------------------------
# Start OpenUEM
# ----------------------------------------------------------------------------
cd "$INSTALL_DIR"

if [ ! -f certificates/users/admin.pfx ] || [ ! -f nats/nats.cfg ]; then
    info "Creating the database, the NATS configuration and the certificates"
    docker compose up -d openuem-certs
    status="$(docker wait openuem-certs)"
    if [ "$status" != "0" ] || [ ! -f certificates/users/admin.pfx ]; then
        docker compose logs openuem-certs | tail -n 30
        die "the certificates could not be created, see the log above"
    fi
fi

if [ "$FIRST_INSTALL" = "0" ]; then
    info "Pulling the latest official images"
    mapfile -t official_services < <(docker compose config --services | grep -vx -e console -e agents-worker)
    [ "$BUILD_WORKER" = "1" ] || official_services+=(agents-worker)
    docker compose pull --ignore-pull-failures --quiet "${official_services[@]}" || warn "some images could not be pulled"
fi

info "Starting OpenUEM"
docker compose up -d --remove-orphans
# NATS reads nats.cfg, regenerated and patched by openuem-certs, only when it starts.
# Agents and the console reconnect on their own.
[ "$FIRST_INSTALL" = "1" ] || docker compose restart nats-server
# Recreate the console after NATS and the workers, so it uses the rebuilt image and the
# new permissions, and adds the database columns that older workers may have dropped
[ "$FIRST_INSTALL" = "1" ] || docker compose up -d --force-recreate console
[ "$FIRST_INSTALL" = "1" ] || [ "$BUILD_WORKER" = "0" ] || docker compose up -d --force-recreate agents-worker

for _ in $(seq 1 30); do
    [ "$(docker inspect -f '{{.State.Running}}' openuem-console 2>/dev/null)" = "true" ] && break
    sleep 2
done
docker compose ps --format 'table {{.Name}}\t{{.Status}}'

# ----------------------------------------------------------------------------
# Agents from the fork
# ----------------------------------------------------------------------------
AGENTS_DIR=""
if [ "$BUILD_AGENTS" = "1" ]; then
    AGENT_COMMIT="$(git -C "$INSTALL_DIR/src/openuem-agent" rev-parse --short HEAD)"
    AGENTS_DIR="$INSTALL_DIR/agent-builds/$AGENT_COMMIT"
    info "Building the agent binaries from ${AGENT_REPO} (${AGENT_BRANCH} @ ${AGENT_COMMIT})"
    mkdir -p "$AGENTS_DIR"
    retry docker run --rm \
        -v "$INSTALL_DIR/src/openuem-agent:/src:ro" -v "$AGENTS_DIR:/out" \
        -v openuem-fork-gocache:/root/.cache -v openuem-fork-gomod:/go/pkg/mod \
        -w /src -e CGO_ENABLED=0 golang:1.26 sh -c '
            set -e
            GOOS=windows GOARCH=amd64 go build -trimpath -o /out/windows-amd64/openuem-agent.exe ./internal/service/windows
            GOOS=linux GOARCH=amd64 go build -trimpath -o /out/linux-amd64/openuem-agent ./internal/service/linux
            GOOS=linux GOARCH=arm64 go build -trimpath -o /out/linux-arm64/openuem-agent ./internal/service/linux
            GOOS=darwin GOARCH=arm64 go build -trimpath -o /out/darwin-arm64/openuem-agent ./internal/service/mac
            GOOS=darwin GOARCH=amd64 go build -trimpath -o /out/darwin-amd64/openuem-agent ./internal/service/mac' ||
        die "the agents could not be built, see the output above. If it's a download error, run the script again"
    ln -sfn "$AGENTS_DIR" "$INSTALL_DIR/agent-builds/latest"

    # ------------------------------------------------------------------------
    # Windows setup program: an Inno Setup installer (like the official
    # openuem-agent-setup.exe) that runs install-openuem-agent-fork.ps1 with the
    # bundled files, silently, so it can be rolled out with GPO, Intune or any
    # software deployment tool. It contains the agents' private key, like the
    # official setup with its certificates: keep it internal.
    # ------------------------------------------------------------------------
    info "Building the Windows setup program openuem-agent-fork-setup.exe (Inno Setup $INNO_SETUP_VERSION)"
    for value in "$SERVER_IP" "$OPENUEM_DOMAIN" "$NATS_PORT" "$AGENT_SFTP_PORT" "$AGENT_VNC_PORT" "$OFFICIAL_AGENT_VERSION" "$INNO_SETUP_VERSION" "$AGENT_COMMIT"; do
        [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid value for the setup program: $value"
    done
    SETUP_BUILD="$INSTALL_DIR/agent-builds/.setup-build"
    rm -rf "$SETUP_BUILD"
    mkdir -p -m 700 "$SETUP_BUILD/files"
    OFFICIAL_DIR="$INSTALL_DIR/agent-builds/official/$OFFICIAL_AGENT_VERSION"
    OFFICIAL_SETUP="$OFFICIAL_DIR/openuem-agent-setup.exe"
    if [ ! -s "$OFFICIAL_SETUP" ]; then
        mkdir -p "$OFFICIAL_DIR"
        retry curl -fsSL -o "$OFFICIAL_SETUP.part" "https://downloads.openuem.eu/agents/$OFFICIAL_AGENT_VERSION/windows/amd64/openuem-agent-setup.exe" ||
            die "the official agent installer $OFFICIAL_AGENT_VERSION could not be downloaded"
        mv "$OFFICIAL_SETUP.part" "$OFFICIAL_SETUP"
    fi
    # The official Linux packages, bundled into the Linux installer below; on
    # distributions without apt/dnf (e.g. Arch) they install the official layout
    for deb_arch in amd64 arm64; do
        OFFICIAL_DEB="$OFFICIAL_DIR/openuem-agent_${OFFICIAL_AGENT_VERSION}_${deb_arch}.deb"
        if [ ! -s "$OFFICIAL_DEB" ]; then
            retry curl -fsSL -o "$OFFICIAL_DEB.part" "https://apt.openuem.eu/pool/main/openuem-agent_${OFFICIAL_AGENT_VERSION}_${deb_arch}.deb" ||
                die "the official agent .deb $OFFICIAL_AGENT_VERSION ($deb_arch) could not be downloaded"
            mv "$OFFICIAL_DEB.part" "$OFFICIAL_DEB"
        fi
    done
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-openuem-agent-fork.ps1" ]; then
        cp "$SCRIPT_DIR/install-openuem-agent-fork.ps1" "$SETUP_BUILD/files/"
    else
        retry curl -fsSL -o "$SETUP_BUILD/files/install-openuem-agent-fork.ps1" "$AGENT_SCRIPT_URL" ||
            die "install-openuem-agent-fork.ps1 could not be downloaded from $AGENT_SCRIPT_URL"
    fi
    grep -q '\$FilesDir' "$SETUP_BUILD/files/install-openuem-agent-fork.ps1" ||
        die "install-openuem-agent-fork.ps1 is too old for the setup program (no -FilesDir)"
    cp "$OFFICIAL_SETUP" "$AGENTS_DIR/windows-amd64/openuem-agent.exe" \
        "$INSTALL_DIR/certificates/ca/ca.cer" "$INSTALL_DIR/certificates/agents/agent.cer" \
        "$INSTALL_DIR/certificates/agents/agent.key" "$INSTALL_DIR/certificates/console/sftp.cer" \
        "$SETUP_BUILD/files/"
    # The Inno Setup script: always silent. Started without /VERYSILENT it extracts the
    # bundled files to {tmp} and runs the PowerShell installer with -FilesDir right in
    # InitializeSetup (before any UI; a re-launch would be blocked by the setup mutex);
    # with /VERYSILENT the [Files] go to {tmp}\files and the worker runs at ssPostInstall.
    # Options: /ORG=<id> /SITE=<id> (organization and site of new computers),
    # /DOMAIN=<domain> and /SERVERIP=<ip> override the baked-in settings, /OVERWRITE
    # overwrites the installed agent's config with these settings.
    # Exit code 0 = OK, 1 = failed (log: %ProgramData%\OpenUEM-fork\install-agent.log).
    cat >"$SETUP_BUILD/setup.iss" <<ISS_EOF
; Generated by install-openuem-fork.sh, compiled with Inno Setup ${INNO_SETUP_VERSION},
; like the official openuem-agent-setup.exe
#define AppName "OpenUEM Agent (fork)"
#define AppVersion "${OFFICIAL_AGENT_VERSION}"
#define AgentCommit "${AGENT_COMMIT}"
#define ServerIP "${SERVER_IP}"
#define Domain "${OPENUEM_DOMAIN}"
#define NatsPort "${NATS_PORT}"
#define SftpPort "${AGENT_SFTP_PORT}"
#define VncPort "${AGENT_VNC_PORT}"

[Setup]
AppId={{7A5C1E42-9F3B-4D8A-B6E1-2C0F8D5A9E41}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion} (fork {#AgentCommit})
AppPublisher=OpenUEM contributors
AppPublisherURL=https://openuem.eu
AppSupportURL=https://openuem.eu/docs
DefaultDirName={autopf}\OpenUEM Agent Fork
DisableWelcomePage=yes
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
Uninstallable=no
PrivilegesRequired=admin
ArchitecturesInstallIn64BitMode=x64
OutputDir=output
OutputBaseFilename=openuem-agent-fork-setup
Compression=lzma2
SolidCompression=yes
MinVersion=6.1sp1
VersionInfoVersion={#AppVersion}
VersionInfoDescription={#AppName} installer (fork build {#AgentCommit})

[Files]
Source: "files\*"; DestDir: "{tmp}\files"; Flags: ignoreversion recursesubdirs createallsubdirs

[Code]
var
  WorkerExitCode: Integer;

procedure ExitProcess(uExitCode: Integer);
  external 'ExitProcess@kernel32.dll stdcall';

// Value of /NAME=value, or '1' when /NAME was given without a value, else ''
function GetParam(const ParamName: string): string;
var
  i, p: Integer;
  s: string;
begin
  Result := '';
  for i := 1 to ParamCount do
  begin
    s := ParamStr(i);
    if (Length(s) > 0) and (s[1] = '/') then
    begin
      s := Copy(s, 2, MaxInt);
      p := Pos('=', s);
      if p > 0 then
      begin
        if CompareText(Copy(s, 1, p - 1), ParamName) = 0 then
          Result := Copy(s, p + 1, MaxInt);
      end
      else if CompareText(s, ParamName) = 0 then
        Result := '1';
    end;
  end;
end;

// Runs install-openuem-agent-fork.ps1 with -FilesDir: it runs the official
// openuem-agent-setup.exe with the official flags and then swaps in the fork's binary
function RunWorker(const FilesDir: string): Integer;
var
  ps, params, serverIP, domain: string;
  exitCode: Integer;
begin
  ps := ExpandConstant('{win}\Sysnative\WindowsPowerShell\v1.0\powershell.exe');
  if not FileExists(ps) then
    ps := ExpandConstant('{win}\System32\WindowsPowerShell\v1.0\powershell.exe');
  serverIP := '{#ServerIP}';
  if GetParam('SERVERIP') <> '' then
    serverIP := GetParam('SERVERIP');
  domain := '{#Domain}';
  if GetParam('DOMAIN') <> '' then
    domain := GetParam('DOMAIN');
  params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    FilesDir + '\install-openuem-agent-fork.ps1" -FilesDir "' + FilesDir +
    '" -ServerIP "' + serverIP + '" -Domain "' + domain +
    '" -NatsPort {#NatsPort} -SftpPort {#SftpPort} -VncPort {#VncPort} -Log';
  if GetParam('ORG') <> '' then
    params := params + ' -OrgID "' + GetParam('ORG') + '" -SiteID "' + GetParam('SITE') + '"';
  if GetParam('OVERWRITE') <> '' then
    params := params + ' -Overwrite';
  Log('Running: ' + ps + ' ' + params);
  if Exec(ps, params, ExpandConstant('{tmp}'), SW_HIDE, ewWaitUntilTerminated, exitCode) then
    Result := exitCode
  else
    Result := 1;
end;

// Silent run (/VERYSILENT): the [Files] are extracted to {tmp}\files, then the worker runs
procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    WorkerExitCode := RunWorker(ExpandConstant('{tmp}\files'));
end;

// Exit code of the silent run: 0 = OK, 1 = the agent installation failed
function GetCustomSetupExitCode: Integer;
begin
  Result := WorkerExitCode;
end;

// Always silent, even when started without /VERYSILENT: run the worker right here,
// before any wizard form is created, and exit with its code (a re-launch of this exe
// would be blocked by the setup mutex of the running instance)
function InitializeSetup: Boolean;
var
  i: Integer;
  names: TArrayOfString;
begin
  Result := True;
  if not WizardSilent then
  begin
    SetArrayLength(names, 7);
    names[0] := 'install-openuem-agent-fork.ps1';
    names[1] := 'openuem-agent-setup.exe';
    names[2] := 'openuem-agent.exe';
    names[3] := 'ca.cer';
    names[4] := 'agent.cer';
    names[5] := 'agent.key';
    names[6] := 'sftp.cer';
    for i := 0 to GetArrayLength(names) - 1 do
      ExtractTemporaryFile(names[i]);
    WorkerExitCode := RunWorker(ExpandConstant('{tmp}'));
    DelTree(ExpandConstant('{tmp}'), True, True, True);
    ExitProcess(WorkerExitCode);
  end;
end;
ISS_EOF
    # Inno Setup compiler in a container (wine); the image is built once and cached
    INNO_IMAGE_DIR="$INSTALL_DIR/agent-builds/.innosetup-image"
    rm -rf "$INNO_IMAGE_DIR"
    mkdir -p -m 700 "$INNO_IMAGE_DIR"
    cat >"$INNO_IMAGE_DIR/Dockerfile" <<DOCKERFILE_EOF
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive WINEARCH=win32
RUN dpkg --add-architecture i386 \\
    && apt-get update -qq \\
    && apt-get install -y -qq --no-install-recommends wine wine32:i386 wine64 xvfb xauth curl ca-certificates >/dev/null \\
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL -o /tmp/innosetup.exe "https://github.com/jrsoftware/issrc/releases/download/${INNO_SETUP_TAG}/innosetup-${INNO_SETUP_VERSION}.exe" \\
    && xvfb-run -a wine /tmp/innosetup.exe /VERYSILENT /SUPPRESSMSGBOXES /ALLUSERS /SP- /NORESTART \\
    && rm -f /tmp/innosetup.exe
WORKDIR /build
DOCKERFILE_EOF
    retry docker build -q -t "openuem-fork-innosetup:${INNO_SETUP_VERSION}" "$INNO_IMAGE_DIR" ||
        die "the Inno Setup compiler image could not be built, see the output above. If it's a download error, run the script again"
    retry docker run --rm -v "$SETUP_BUILD:/build" -w /build "openuem-fork-innosetup:${INNO_SETUP_VERSION}" \
        sh -c 'for d in "/root/.wine/drive_c/Program Files (x86)/Inno Setup 6" "/root/.wine/drive_c/Program Files/Inno Setup 6"; do [ -f "$d/ISCC.exe" ] && exec wine "$d/ISCC.exe" /Q setup.iss; done; echo "ISCC.exe not found" >&2; exit 1' ||
        die "compiling setup.iss failed, see the output above"
    setup_exe="$(find "$SETUP_BUILD" -type f -name openuem-agent-fork-setup.exe | head -n1)"
    [ -n "$setup_exe" ] || die "ISCC produced no openuem-agent-fork-setup.exe"
    install -m 600 "$setup_exe" "$AGENTS_DIR/windows-amd64/openuem-agent-fork-setup.exe"
    rm -rf "$SETUP_BUILD" "$INNO_IMAGE_DIR"

    # ------------------------------------------------------------------------
    # Linux installer: install-openuem-agent-fork.sh with the certificates, the
    # agents (amd64, arm64), the official .deb packages (amd64, arm64) and the
    # settings appended. Debian, Arch and other systemd distributions. It contains
    # the agents' private key too.
    # ------------------------------------------------------------------------
    info "Building the Linux installer openuem-agent-fork-install.sh"
    LINUX_BUILD="$INSTALL_DIR/agent-builds/.linux-build"
    rm -rf "$LINUX_BUILD"
    mkdir -p -m 700 "$LINUX_BUILD/payload/linux-amd64" "$LINUX_BUILD/payload/linux-arm64" \
        "$LINUX_BUILD/payload/official"
    if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/install-openuem-agent-fork.sh" ]; then
        cp "$SCRIPT_DIR/install-openuem-agent-fork.sh" "$LINUX_BUILD/install.sh"
    else
        retry curl -fsSL -o "$LINUX_BUILD/install.sh" "$AGENT_LINUX_SCRIPT_URL" ||
            die "install-openuem-agent-fork.sh could not be downloaded from $AGENT_LINUX_SCRIPT_URL"
    fi
    grep -q '__OPENUEM_PAYLOAD__' "$LINUX_BUILD/install.sh" ||
        die "$AGENT_LINUX_SCRIPT_URL is not the Linux agent installer"
    cp "$AGENTS_DIR/linux-amd64/openuem-agent" "$LINUX_BUILD/payload/linux-amd64/"
    cp "$AGENTS_DIR/linux-arm64/openuem-agent" "$LINUX_BUILD/payload/linux-arm64/"
    cp "$INSTALL_DIR/certificates/ca/ca.cer" "$INSTALL_DIR/certificates/agents/agent.cer" \
        "$INSTALL_DIR/certificates/agents/agent.key" "$INSTALL_DIR/certificates/console/sftp.cer" \
        "$LINUX_BUILD/payload/"
    cp "$OFFICIAL_DIR/openuem-agent_${OFFICIAL_AGENT_VERSION}_amd64.deb" \
        "$OFFICIAL_DIR/openuem-agent_${OFFICIAL_AGENT_VERSION}_arm64.deb" \
        "$LINUX_BUILD/payload/official/"
    cat >"$LINUX_BUILD/payload/settings.env" <<SETTINGS_EOF
SERVER_IP="${SERVER_IP}"
DOMAIN="${OPENUEM_DOMAIN}"
NATS_PORT="${NATS_PORT}"
SFTP_PORT="${AGENT_SFTP_PORT}"
VNC_PORT="${AGENT_VNC_PORT}"
AGENT_COMMIT="${AGENT_COMMIT}"
OFFICIAL_AGENT_VERSION="${OFFICIAL_AGENT_VERSION}"
SETTINGS_EOF
    mkdir -p "$AGENTS_DIR/linux"
    {
        cat "$LINUX_BUILD/install.sh"
        printf '__OPENUEM_PAYLOAD__\n'
        tar -C "$LINUX_BUILD/payload" -cz .
    } >"$LINUX_BUILD/openuem-agent-fork-install.sh"
    install -m 600 "$LINUX_BUILD/openuem-agent-fork-install.sh" "$AGENTS_DIR/linux/openuem-agent-fork-install.sh"
    rm -rf "$LINUX_BUILD"
fi

# ----------------------------------------------------------------------------
# Password login
# ----------------------------------------------------------------------------
# Helper to set a new password for the built-in openuem user
cat >"$INSTALL_DIR/reset-openuem-password.sh" <<'RESET_EOF'
#!/usr/bin/env bash
# Sets a new random password for the openuem user, re-enables password logins and prints it
set -euo pipefail
cd "$(dirname "$0")"
sed -i 's/^CONSOLE_RESET_OPENUEM_USER=.*/CONSOLE_RESET_OPENUEM_USER=true/; s/^CONSOLE_RE_ENABLE_PASSWD_AUTH=.*/CONSOLE_RE_ENABLE_PASSWD_AUTH=true/' .env
since="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
docker compose up -d --force-recreate console
password=""
for _ in $(seq 1 30); do
    password="$(docker compose logs --since "$since" console 2>/dev/null | sed -n 's/.*initial password for the openuem user account is: //p' | tail -n1 | tr -d '\r')"
    [ -n "$password" ] && break
    sleep 2
done
# Don't reset the user again on the next restart
sed -i 's/^CONSOLE_RESET_OPENUEM_USER=.*/CONSOLE_RESET_OPENUEM_USER=/' .env
docker compose up -d console >/dev/null
[ -n "$password" ] || { echo "The new password wasn't found in the console log, see: docker compose logs console" >&2; exit 1; }
printf 'User:     openuem\nPassword: %s\nYou must change it at the first login.\n' "$password"
RESET_EOF
chmod 700 "$INSTALL_DIR/reset-openuem-password.sh"

# The console creates the openuem user with a random password on its first start
# and only writes it to its log
OPENUEM_PASSWORD=""
if [ "$FIRST_INSTALL" = "1" ]; then
    for _ in $(seq 1 30); do
        OPENUEM_PASSWORD="$(docker compose logs console 2>/dev/null | sed -n 's/.*initial password for the openuem user account is: //p' | tail -n1 | tr -d '\r')"
        [ -n "$OPENUEM_PASSWORD" ] && break
        sleep 2
    done
fi

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
cat <<EOF

$(printf '\033[1;32m')OpenUEM is running with the console from ${CONSOLE_REPO} (${CONSOLE_BRANCH} @ ${CONSOLE_COMMIT})$(printf '\033[0m')

Console:          https://console.${OPENUEM_DOMAIN}:${CONSOLE_PORT}

Log in with a password:
  User:           openuem
  Password:       ${OPENUEM_PASSWORD:-the one you set at your first login}
  New password:   ${INSTALL_DIR}/reset-openuem-password.sh

Or log in with the admin certificate:
  ${INSTALL_DIR}/certificates/users/admin.pfx (password: changeit)
  Import it into your browser and choose it when the browser asks. The login
  uses port ${CONSOLE_AUTH_PORT}; restart Firefox after importing it.

CA certificate:   ${INSTALL_DIR}/certificates/ca/ca.cer
                  Import it as a trusted root CA to avoid browser warnings.

Ports your computers and browser must reach on ${SERVER_IP}:
  ${CONSOLE_PORT}/tcp (console), ${CONSOLE_AUTH_PORT}/tcp (console login), ${NATS_PORT}/tcp (NATS), ${OCSP_PORT}/tcp (OCSP)

DNS: console.${OPENUEM_DOMAIN}, nats.${OPENUEM_DOMAIN} and ocsp.${OPENUEM_DOMAIN}
     must resolve to ${SERVER_IP} on every computer and in your browser.

Logs:      cd ${INSTALL_DIR} && docker compose logs -f console
Update:    run this script again (settings, certificates and data are kept)
Rollback:  rm ${INSTALL_DIR}/compose.override.yml && cd ${INSTALL_DIR} && docker compose up -d

New features of the fork:
  Deploy > Update                     update one package on selected computers
  Deploy > Update all software        update everything on selected computers,
                                      offline computers update when they connect
  Deploy > Update status              status of the update runs of all computers
  Deploy > Software library           private winget repository: upload MSI, EXE and
                                      MSIX installers, computers install and update
                                      them with winget
  Profiles > (task) > WinGet package  install packages of the software library
  Profiles > (task) > script          load the script from a file
  Computers > (computer) > Deploy >
    Software updates                  list a computer's updates, update some or all
EOF

if [ -n "$AGENTS_DIR" ]; then
    cat <<EOF

Agent binaries built from the fork: ${INSTALL_DIR}/agent-builds/latest/

  Windows setup program for all computers (silent, installs or updates):
    ${INSTALL_DIR}/agent-builds/latest/windows-amd64/openuem-agent-fork-setup.exe
    Built with Inno Setup ${INNO_SETUP_VERSION} like the official openuem-agent-setup.exe;
    it runs the official installer with the official flags and then swaps in the fork's
    binary. It contains the agents' private key: keep it internal. Run it as administrator
    or SYSTEM (GPO startup script, Intune Win32 app, PDQ, ...), exit code 0 = OK, 1 = failed.
    Silent even without /S (runs the worker directly, or with /VERYSILENT /SUPPRESSMSGBOXES).
    Log: %ProgramData%\\OpenUEM-fork\\install-agent.log on the computer.
    Options: /ORG=<id> /SITE=<id>, /DOMAIN=, /SERVERIP=, /OVERWRITE (overwrites the
    installed agent's config). DNS must resolve console/nats/ocsp.<domain>; no hosts
    entries are written.

  Linux installer (Debian/Ubuntu, RHEL/Fedora, Arch and other systemd distributions,
  amd64 and arm64; installs or updates via the official package):
    ${INSTALL_DIR}/agent-builds/latest/linux/openuem-agent-fork-install.sh
    Copy it to the computer and run: sudo bash openuem-agent-fork-install.sh
    It installs the official openuem-agent package (bundled .deb, or the OpenUEM
    apt/rpm repository), configures it (debconf preseed or openuem.ini), places the
    certificates, disables the official updater and swaps in the fork's binary.
    It contains the agents' private key too: keep it internal.

  Or install the official OpenUEM agent first, then replace its binary:
  Windows (PowerShell as administrator):
    Stop-Service openuem-agent
    # the path is shown by: sc.exe qc openuem-agent
    Copy-Item .\\openuem-agent.exe "<agent folder>\\openuem-agent.exe" -Force
    Start-Service openuem-agent
  Linux:
    systemctl stop openuem-agent
    # the path is shown by: systemctl cat openuem-agent (ExecStart=)
    install -m 755 openuem-agent <agent binary path>
    systemctl start openuem-agent
EOF
fi
