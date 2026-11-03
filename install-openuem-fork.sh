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

FORK_IMAGE="openuem-console-fork"

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

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
mkdir -p "$INSTALL_DIR/task-files"
chmod 700 "$INSTALL_DIR/task-files"

info "Writing $INSTALL_DIR/compose.override.yml"
cat >"$INSTALL_DIR/compose.override.yml" <<EOF
# Generated by install-openuem-fork.sh. Delete this file and run
# 'docker compose up -d' to go back to the official console image.
services:
  console:
    image: ${FORK_IMAGE}:latest
    pull_policy: never
    # Files uploaded for tasks (MSI packages) must survive container updates
    volumes:
      - "./task-files:/bin/task-files:z"
    networks:
      openuem:
        aliases:
          - console.${OPENUEM_DOMAIN}
  nats-server:
    networks:
      openuem:
        aliases:
          - nats.${OPENUEM_DOMAIN}
  ocsp-responder:
    networks:
      openuem:
        aliases:
          - ocsp.${OPENUEM_DOMAIN}
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
docker build --pull -t "${FORK_IMAGE}:${CONSOLE_COMMIT}" -t "${FORK_IMAGE}:latest" "$INSTALL_DIR/src/openuem-console"

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

# NATS only lets agents subscribe to an explicit list of subjects, the fork's agent
# needs two more to list available updates and to start bulk update runs
NATS_CONFIG_CHANGED=0
for subject in listpackageupdates updatepackages; do
    grep -q "\"agent.${subject}.> openuem-agent-management\"" nats/nats.cfg && continue
    if grep -q '"agent.runprofile.> openuem-agent-management"' nats/nats.cfg; then
        sed -i "s|\"agent.runprofile.> openuem-agent-management\"|&, \"agent.${subject}.> openuem-agent-management\"|" nats/nats.cfg
        NATS_CONFIG_CHANGED=1
        printf 'Allowed agents to subscribe to agent.%s in nats/nats.cfg\n' "$subject"
    else
        warn "could not allow agent.${subject} in nats/nats.cfg, software updates won't work until it's added to the agent's subscribe permissions"
    fi
done

# The console elects a leader with a NATS key-value bucket to fill the software package
# database used by the package search. nats.cfg files generated by older cert-manager
# images don't allow it, the election fails and the package search returns nothing.
# The fork's update status page also reads queued update requests from AGENTS_STREAM.
# shellcheck disable=SC2016 # NATS subject names, the $ is literal
for permission in '$JS.API.INFO' '$JS.API.STREAM.INFO.KV_leaders' '$JS.API.DIRECT.GET.KV_leaders.>' '$JS.API.CONSUMER.CREATE.KV_leaders.>' '$KV.leaders.openuem' '$JS.API.STREAM.MSG.GET.AGENTS_STREAM'; do
    sed -n '/CN=OpenUEM Console/,/publish:/p' nats/nats.cfg | grep -qF "\"$permission\"" && continue
    sed -i "/CN=OpenUEM Console/,/publish:/ s|publish: \[|publish: [\"$permission\", |" nats/nats.cfg
    NATS_CONFIG_CHANGED=1
    printf 'Allowed the console to use %s in nats/nats.cfg\n' "$permission"
done

if [ "$FIRST_INSTALL" = "0" ]; then
    info "Pulling the latest official images"
    mapfile -t official_services < <(docker compose config --services | grep -vx console)
    docker compose pull --ignore-pull-failures --quiet "${official_services[@]}" || warn "some images could not be pulled"
fi

info "Starting OpenUEM"
docker compose up -d --remove-orphans
# NATS reads its configuration only when it starts; agents reconnect on their own
if [ "$NATS_CONFIG_CHANGED" = "1" ] && [ "$FIRST_INSTALL" = "0" ]; then
    docker compose restart nats-server
fi
# Recreate the console after NATS, so it uses the rebuilt image and the new permissions
[ "$FIRST_INSTALL" = "1" ] || docker compose up -d --force-recreate console

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
    docker run --rm \
        -v "$INSTALL_DIR/src/openuem-agent:/src:ro" -v "$AGENTS_DIR:/out" \
        -v openuem-fork-gocache:/root/.cache -v openuem-fork-gomod:/go/pkg/mod \
        -w /src -e CGO_ENABLED=0 golang:1.26 sh -c '
            set -e
            GOOS=windows GOARCH=amd64 go build -trimpath -o /out/windows-amd64/openuem-agent.exe ./internal/service/windows
            GOOS=linux GOARCH=amd64 go build -trimpath -o /out/linux-amd64/openuem-agent ./internal/service/linux
            GOOS=linux GOARCH=arm64 go build -trimpath -o /out/linux-arm64/openuem-agent ./internal/service/linux
            GOOS=darwin GOARCH=arm64 go build -trimpath -o /out/darwin-arm64/openuem-agent ./internal/service/mac
            GOOS=darwin GOARCH=amd64 go build -trimpath -o /out/darwin-amd64/openuem-agent ./internal/service/mac'
    ln -sfn "$AGENTS_DIR" "$INSTALL_DIR/agent-builds/latest"
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
  Profiles > (task) > MSI package     upload the MSI package instead of giving a URL,
                                      only the profile's computers can download it
  Profiles > (task) > script          load the script from a file
  Computers > (computer) > Deploy >
    Software updates                  list a computer's updates, update some or all
EOF

if [ -n "$AGENTS_DIR" ]; then
    cat <<EOF

Agent binaries built from the fork: ${INSTALL_DIR}/agent-builds/latest/
  Windows, all in one step (PowerShell as administrator, on a computer without
  Defender ASR policies that block unsigned programs). Run it again to update:
    Set-ExecutionPolicy -Scope Process Bypass -Force; & ([scriptblock]::Create((irm https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1))) -ServerIP ${SERVER_IP} -Domain ${OPENUEM_DOMAIN}
    Add -SshPort <port> if SSH doesn't listen on port 22.

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
