# Handoff: bulk software updates and private winget repository for OpenUEM

State as of 2026-11-18. This folder lives on the `install-script` branch of
`devilAPI/openuem-console`, which only holds tooling for the fork and is never part of a
pull request.

| File | What it is |
|---|---|
| `HANDOFF.md` | This document |
| `TEST_PLAN.md` | The Windows test plan with the results of the VM test run (2026-11-18) |
| `pr/*.md` | Pull request descriptions (nats, cert-manager, agent, console, worker; `scheduler-pr.md` for the scheduler) and the feature request issues (`issue.md`, `scheduler-issue.md`) |
| `worker-patches/*.patch` | The openuem-worker commits as patches (the fork's `software-updates` branch has them too) |
| `../install-openuem-fork.sh` | Installs or updates the server (Debian 13, Docker) with the fork |
| `../install-openuem-agent-fork.ps1` | Installs or updates the fork's agent on Windows |

## 1. What was built

Upstream OpenUEM could only update one package on one computer at a time. The fork adds:

1. **Bulk software updates.** These live under Deploy → Update / Update all software / Update status, and Computer → Deploy → Software updates.
   - List the available updates of a computer: winget, flatpak or Homebrew.
   - Update some or all packages, on one or many computers.
   - **Per-user packages on Windows:** packages installed for a single user are found and updated in that user's session. The agent runs as SYSTEM, whose winget doesn't see them.
   - **Per-package results:** each package's result is reported; packages that are already up to date or not installed don't count as failures.
   - **Offline computers:** requests for them are queued in JetStream and run when they connect. Requests older than 30 days are dropped.
   - **Update status page:** one row per computer with its last update run.
2. **Private winget repository** (Deploy → Software library). This replaced the first idea, an SFTP transfer, after feedback on the upstream PR.
   - **Upload:** MSI, EXE (Inno Setup, NSIS, WiX Burn, or any setup program given its silent switches) and MSIX installers. Name, publisher and version are read from the file.
   - **REST source:** the console serves them as a WinGet REST source at `https://<console>:<console port>/winget/<agent id>/<token>/`, which only needs outbound HTTPS.
   - **Registration:** Windows agents register the source automatically, as `OpenUEM`. This happens on admission, every 30 minutes, and with a button.
   - **Deploy integration:** library packages show up in Deploy → Install search (with an "OpenUEM" badge). They're installed, updated and uninstalled with winget like any other package, and only computers of the package's organization see them.
   - **Profiles:** profile winget tasks can pick library packages (needs the agents-worker change, see below).
3. ~~MSI upload for profile tasks~~ (`/agent-files` on the auth server): **removed**, superseded by 2. once a profile installed a library package on Windows (`remove-task-uploads` is merged).
4. **Dashboard statistics of the fork's features** (Console → Dashboard). A second row of pie charts shows:
   - **Deployments by status**, from the database: installed, failed or waiting for the agent's result (`CountDeploymentsByStatus`). Covers the bulk installs and the library packages like the existing `NDeployments` counter does.
   - **Computers by software updates needed**, in four buckets: no updates, under five, five to twenty and more than twenty. Counting the updates runs the computers' package managers, which takes minutes on Windows, so the console counts them in the background (`available_updates.go`: once when the console starts, then hourly; concurrency 16, 10 min per computer) and the dashboard only reads the count. Computers that don't answer aren't counted.
   - a new `Computers that need software updates` counter row links to the Deploy update status page, and `Packages in the software library` counter row links to the software library.
   - **every pie chart card shows a tooltip** when it's hovered (`Chart` in `chart.templ`, the `charts.tip_*` keys), explaining what the chart is based on.
   - the software library packages by installer type pie **was removed again** (2026-11-20) on request.
   - **Computers by last software update run.** Like the update status page, the console asks every agent (except the waiting ones) `agent.listpackageupdates` with `{"statusonly":true}` (20 s page render at the most, concurrency 16, 5 s per agent) and classifies it: finished without failures, with failures, running, never ran an update, or no answer (offline or an agent without support). Without a NATS connection every computer counts as not answering.
6. **Scheduled tasks** (Deploy → Scheduled tasks). Tasks the console runs automatically against every enabled and admitted computer of the organization (or one site):
   - **Types:** update all software (queued in JetStream like the manual action, so offline computers run when they connect), power off, restart, Wake on LAN.
   - **Schedules:** daily, weekly or monthly at a time of day, or any standard cron expression — recurring; or a date and time in the future — only once, interpreted in the console's local time. The server re-validates: cron expressions with `robfig/cron`, one-time dates in the future.
   - **The list:** schedule, next run, last run and result (failed in red) per task, enable/disable, run now (async, the result is recorded when it finishes), edit (frequency prefilled), delete with a confirm. Untracked and manageable only from its own scope, like everything in Deploy.
   - **Persistence:** a new ent entity (`scheduled_event`); the console registers the jobs of enabled events from the database at startup, so tasks survive restarts. One-time tasks are disabled and unregistered after their run; a one-time task whose date passed is disabled instead of run. Jobs run in gocron singleton mode.
   - The schema addition will be contributed to `open-uem/ent`; until then the branches pin `github.com/devilAPI/ent` with a `replace`.
   - **User behavior:** the codes exist in all seven locales; result summaries are stored in English because jobs run without a request locale.
5. **Smaller fixes along the way:**
   - the console Dockerfile (Go toolchain, `$GOPATH`) and the worker Dockerfile;
   - the Homebrew type check;
   - the auth server trusted the `Client-Cert` header without a reverse proxy;
   - failed winget updates were reported as successful;
   - failed PowerShell tasks now report the script's output;
   - styling with classes missing from `main.css`.

## 2. Repositories and branches

All forks are under `github.com/devilAPI/`. Upstream is `github.com/open-uem/`, and its `main` hasn't moved since the work started (checked 2026-11-06).

### 2.1 Branch roles

| Branch | Role |
|---|---|
| `feature/bulk-software-updates` | Development history. **The install scripts build these**, so this is what runs on the test server. |
| `software-updates` | **PR branch** (#499), squashed (2026-11-20) from one commit per feature step into three commits (features, fixes, dashboard), on top of upstream `main`. Its tree is unchanged.
| `scheduled-tasks` | **PR branch** for the scheduler (item 6): three commits on top of `software-updates`' tree plus the cherry-picked scheduler commit of the feature branch. |
| `scheduled-events` (ent repo) | The `scheduled_event` schema on a fork of `open-uem/ent` (`devilAPI/ent`), to be contributed upstream. |
| `remove-task-uploads` | Removal of the MSI task upload (item 3). **Merged** into the feature branches and added as a commit to the PR branches; the branch can be deleted. |
| `install-script` (console repo only) | Install scripts and this handoff |

### 2.2 Current heads

| Repository | `feature/bulk-software-updates` | `software-updates` (PR) | upstream PR |
|---|---|---|---|
| nats | `d9b855a` | `b3a4794` | #24 |
| openuem-agent | `a53b63b` | `2487602` | #216 |
| openuem-console | `5c6a762` | `d9e1794` (squash of 25 commits) | #499 (issue #498) |
| openuem-console `scheduled-tasks` | – | `37923c4` | scheduler, not opened yet (issue draft in `pr/scheduler-issue.md`) |
| openuem-ent | – | `1b23ef3` (`scheduled-events`) | schema addition, not opened yet |
| openuem-cert-manager | – | `626b464` | #17 |
| openuem-worker | – | `826d9d0` | not opened yet |
| install-script (console repo) | | this commit | – |

### 2.3 Commits of the PR branches

- **nats:**
  - `d19f31f` types to list available package updates and run bulk updates
  - `b3a4794` message to register the console's winget repository (`WinGetSourceConfig`)
- **cert-manager:** NATS permissions in `scripts/generate-nats-conf.sh`:
  - `dda0193` the update subjects
  - `626b464` `agent.wingetsource.>`
- **agent:**
  - `a79aaad` bulk, queued and user-scoped updates (and the MSI download, removed by `1cd77ea`)
  - `ea46457` registers the winget repository
  - `3a8e4b2` logs winget's own error lines when that fails
  - `1ad7aa3` registers the repository as a trusted source
  - `9482bb8` lists only user-scoped packages in user sessions
  - `1cd77ea` removes the download of MSI packages uploaded for tasks
  - `e5e6a2a` uses the newest App Installer whose winget.exe can run
  - `fb9203e` installs and uninstalls without PowerShell, reporting failures (upstream bug)
  - `ccbba2e` only the source name OpenUEM, no token in the state file
  - `7e99049` hardened winget in users' sessions (local LOCALAPPDATA, capped output, WaitDelay)
  - `649d568` failed uninstalls reported as failed (upstream bug)
  - `fbb9dfb` queued requests no longer dropped because a later run started
  - `2487602` package ids validated for flatpak and Homebrew
- **console:** `software-updates` was squashed into three commits (2026-11-20) with identical content:
  - `ad4cf63` features: software library (MSI/EXE/MSIX, REST source, profiles integration, MSI task uploads removed) and bulk software updates with the update status page
  - `a3a02bf` fixes: identifiers per organization and safe replacement, MSI header check, URLs behind reverse proxies, organization scoping of searches, deployment reuse, one queued run at a time, hyperscript sink
  - `d9e1794` dashboard statistics of the fork's features (deployments by status, library packages found and marked with the OpenUEM badge, updates-needed pie with tooltips and the needs-updates counter)
  - the same steps exist per-feature-commit in the history of the feature branch; the dashboard commits there are `a5964e1`…`7dd965d` and the scheduler is `5c6a762`
- **console `scheduled-tasks`** (scheduler PR branch):
  - `37923c4` scheduled tasks (cron and one-time, four task types, persistence with the devilAPI/ent pin) — equals `5c6a762` of the feature branch
- **ent (devilAPI/ent, `scheduled-events`):**
  - `1b23ef3` the `scheduled_event` schema (cron/when, enabled, last run/result, tenant edge required, optional site edge with cascade delete)
- **worker:**
  - `c6980f8` profile tasks use the source `OpenUEM` for library packages
  - `826d9d0` Dockerfile fix

### 2.4 Temporary dependency pins

The agent and console use `replace github.com/open-uem/nats => github.com/devilAPI/nats …`:

| Branch | Pinned nats version |
|---|---|
| feature branches | `v0.0.0-20261105200231-d9b855acd99e` |
| PR branches | `v0.0.0-20261106070022-b3a4794d5abe` (the nats PR branch) |

Both nats commits have the same tree. Once the nats PR is merged upstream, drop the `replace` and `go get github.com/open-uem/nats@<merged commit>`.

The console's scheduler also uses `replace github.com/open-uem/ent => github.com/devilAPI/ent v0.0.0-20261120111527-1b23ef397c05` (both the feature branch and `scheduled-tasks`): the `scheduled_event` schema isn't upstream yet. Once the open-uem/ent PR is merged, drop the `replace` and `go get github.com/open-uem/ent@<merged commit>`. `go mod tidy` removes some old `open-uem/ent` lines from `go.sum` while the replace is active — that is expected and stays.

`go.sum` is kept minimal on purpose: don't commit the churn from `go mod tidy` (it removes unrelated upstream lines).

### 2.5 Merge order upstream

1. nats
2. cert-manager
3. agent
4. console
5. worker

The worker only reads the catalog that the console fills.

The scheduler PR depends on its own pieces, besides the console PR #499:

1. `open-uem/ent`: the `scheduled_event` schema (until then: the `devilAPI/ent` pin)
2. console `scheduled-tasks` (issue draft in `pr/scheduler-issue.md`, PR body in `pr/scheduler-pr.md`)

## 3. How it works

### 3.1 NATS subjects

| Subject | Kind | Purpose |
|---|---|---|
| `agent.listpackageupdates.<id>` | request/reply, queue `openuem-agent-management` | Available updates and the last run; `{"statusonly":true}` only returns the run |
| `agent.updatepackages.<id>` | request/reply, same queue | Start an update run (empty = everything) |
| `agent.update.packages.<id>` | JetStream AGENTS_STREAM, the agent's durable consumer | Same request, queued for offline computers |
| `agent.wingetsource.<id>` | request/reply, same queue | Register the winget repository (`WinGetSourceConfig`) |
| `wingetcfg.profiles` | existing, answered by the agents worker | Profiles; winget tasks use the source `OpenUEM` for library packages |

These need NATS permissions:
- **Agent** `sub.allow`: `agent.listpackageupdates.>`, `agent.updatepackages.>` and `agent.wingetsource.>`, with the queue group.
- **Console** `publish`: `$JS.API.STREAM.MSG.GET.AGENTS_STREAM`, plus the leader-election KV permissions that upstream `main` already has but the published image lacks.

The server install script patches them in. The `openuem-certs` container regenerates `nats.cfg` on every start, so the patch runs inside that container's entrypoint (`fork/nats-permissions.sh`).

### 3.2 The winget repository

- **Storage:** `internal/wingetrepo/` in the console holds the library store (`<dir>/<id>/<version>/package.json` and the installer), the MSI, EXE and MSIX readers, the REST API types, search and manifests, and the agent tokens.
- **Authentication:** winget can't present client certificates, so each agent gets its own URL with an HMAC-SHA256 token of its id, keyed with the console's JWT key. Only enabled agents get answers, and only for their organizations' packages.
- **Served on the console port (1323), not the auth port (1324).** The auth server asks every client for a certificate (`tls.RequestClientCert`, for the certificate login). WinHTTP, which winget uses through cpprestsdk, then fails the request, and `winget source add` exits with `0x8A150045`. The routes live in `authserver/handlers/winget.go` but are registered on the web server's router (`RegisterWinGetSource`, `internal/common/db.go`).
- **Errors:** the console's error handler renders HTML with status 200, so the winget routes answer errors themselves as JSON with real status codes. An unknown package gives 204, because winget treats 404 as an error.
- **Revocation:** winget checks the console certificate's revocation over OCSP at `http://ocsp.<domain>:8000`. The responder answers both POST and GET, but the computers must be able to reach it.
- **Registration on Windows** (`openuem-agent/internal/commands/deploy/winget_source_windows.go`):
  1. `certutil -addstore Root ca.cer` when there's no reverse proxy;
  2. `winget source remove`, then `winget source add --type Microsoft.Rest --verbose-logs`;
  3. on failure, the matching lines of winget's own log are appended to the error;
  4. the state is kept in `winget_source.json` next to the agent, only after success, so winget doesn't run every 30 minutes.
- **Install scope:** the agent installs with `winget install --scope machine`, so every manifest declares machine scope.

### 3.3 Install scripts (`install-script` branch)

**Server** (`install-openuem-fork.sh`, run as root on Debian 13):

```bash
curl -fsSL https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-fork.sh | bash
```

- **Install:** a fresh install sets up Docker plus the official `openuem-docker` stack, then builds the console image and the agent binaries from the fork.
- **Update:** running it again updates. It keeps `.env`, the certificates and the database, and appends new upstream settings.
- **Settings:** environment variables, e.g. `OPENUEM_DOMAIN`, `SERVER_IP`, `CONSOLE_BRANCH`, `AGENT_BRANCH`, `WORKER_REPO`/`WORKER_BRANCH`, `BUILD_AGENTS`.
- **Worker:** it builds the agents worker from `WORKER_REPO` when that repository exists; otherwise it keeps the official one and prints a warning.
- **Retries:** builds are retried 3 times, because downloads from the Go proxy sometimes break.
- **Workers don't migrate:** `ENV=prod` is set for the published workers and the OCSP responder, so only the console migrates the database. Older workers otherwise drop the console's new columns.
- **Compose override:** `compose.override.yml` holds the fork images, volumes, network aliases for the domain and the NATS permission hook. Delete it to go back to the official images.

**Windows agent** (`install-openuem-agent-fork.ps1`, admin PowerShell):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1))) -ServerIP <ip> -Domain <domain> [-P <ssh port>]
```

- **Official flow** (https://openuem.eu/docs/Installation/Agent/windows), then only the binary swap:
  - copies the certificates and the fork agent over one SSH connection (or takes them from `-FilesDir`);
  - runs the **official** `openuem-agent-setup.exe` as admin with the official flags
    `/server=<nats-host>:<port> /sftp=<port> /vnc=<port> /VERYSILENT /SUPPRESSMSGBOXES /NORESTART`,
    the certificates next to the installer and also via `/cacert= /cert= /key= /sftpcert=`,
    plus `/tenantid=<id> /siteid=<id>` when `-OrgID`/`-SiteID` are given;
  - replaces the installed agent binary, keeping the original as `.official`.
  - **Also on updates** the official installer is run again (verified on the VM: a re-run
    exits 0, keeps UUID/TenantID/SiteID/ports in `config\openuem.ini` and only replaces the
    binary), then the fork binary is swapped in again.
  - No hosts entries are written: `console./nats./ocsp.<domain>` must resolve over DNS.
  - `-Overwrite` rewrites the installed agent's config (NATS server, ports) with the settings of the run.
- **Later runs need no parameters.** The settings come from the last run (`%ProgramData%\OpenUEM-fork\install-agent.json`), then from the installed agent's `config\openuem.ini` or DNS.
- **Defender:** ASR rules on managed company PCs block the unsigned agent, so test on a computer without those policies.
- **Key handling:** the work folder (`C:\openuem-agent`) is limited to administrators and SYSTEM, and the copied certificates, key and installers are deleted when the script ends, also when it fails. Earlier versions left `agent.key` there, readable by all users; running the new script removes it.

**Windows setup program for rollouts** (`openuem-agent-fork-setup.exe`):

- **Built with Inno Setup 6.6.1 like the official installer** (ISCC in a `debian:trixie-slim`
  container with wine/xvfb; image cached as `openuem-fork-innosetup:6.6.1`). The built exe
  carries the same packager signatures as the official `openuem-agent-setup.exe`
  (`Inno Setup Setup Data (6.6.1)` / `Inno Setup Messages (6.5.0)`) and is detected as
  `inno` by the console's own `wingetrepo.ReadExeInfo` detector (verified with a Go probe
  against the built exe).
- It bundles the official agent installer (`OFFICIAL_AGENT_VERSION`, default 0.11.0), the
  fork's agent, the certificates and `install-openuem-agent-fork.ps1`; the `.iss` extracts
  them to `{tmp}` and runs the script with `-FilesDir`, so no SSH and no internet access are
  needed on the computers. Internally the script runs the official setup with the official
  flags (see above) and then swaps the binary.
- **Wizard by default (2026-11-20, like the official setup):** started without switches it
  shows Inno's setup wizard (welcome, directory, installing, finished) and runs the worker
  after the install step; a failed installation is reported in a message box. Silent
  installs use Inno's switches, e.g. `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`, and return
  the worker's code via `GetCustomSetupExitCode`. Exit code 0 on success, 1 on failure. Runs
  as administrator or SYSTEM (GPO startup script, Intune Win32 app, PDQ and similar).
  *Before 2026-11-20 it forced itself silent:* it ran the worker in `InitializeSetup` before
  any wizard form and exited with `ExitProcess`.
- **Install and update:** a computer without the agent gets the official agent plus the
  fork's binary; a computer with the agent gets the official installer re-run plus the new binary.
- **Settings baked in:** `SERVER_IP`, the domain, the NATS port and `AGENT_SFTP_PORT`/`AGENT_VNC_PORT`.
  No hosts entries are written; DNS must resolve the names.
- **Options:** `/ORG=<id> /SITE=<id>` (organization and site of a new computer, passed to the
  script as `-OrgID`/`-SiteID` and to the official installer as `/tenantid=`/`/siteid=`; together
  with `/OVERWRITE` an already installed agent registers again as a NEW computer of that
  organization and site, with a fresh UUID — the old computer entry stays in the console until
  it's deleted there),
  `/DOMAIN=` and `/SERVERIP=` override the baked-in settings, `/OVERWRITE` overwrites the
  installed agent's config with them.
- **Log:** `%ProgramData%\OpenUEM-fork\install-agent.log` on the computer.
- **Secret:** it contains the agents' private key, like the certificate files the official
  installer needs. The file is root-only (600) on the server; keep it on internal shares.
- **Not an MSI:** GPO software installation needs an MSI, so use a startup script (`\\server\share\openuem-agent-fork-setup.exe`) instead.

**Linux installer** (`install-openuem-agent-fork.sh`, built as `agent-builds/latest/linux/openuem-agent-fork-install.sh`):

- **Official flow** (https://openuem.eu/docs/Installation/Agent/linux), then only the binary swap:
  - **Package:** debconf preseed (`openuem-agent/nats-server`, `/sftp-port`, `/vnc-proxy-port`,
    `/org`, `/site`) + `apt install` of the bundled official `.deb`, or `apt install openuem-agent`
    from the OpenUEM repository when no .deb is bundled; `dnf install openuem-agent` from the
    RPM repository on dnf systems; on distributions without apt/dnf (e.g. Arch) the bundled
    official `.deb` is extracted (`dpkg-deb`/`bsdtar`/`ar`), which installs the official layout
    (`/opt/openuem-agent/bin`, `/etc/systemd/system` units).
  - **Config:** the package's own mechanism — debconf on apt systems, otherwise
    `/etc/openuem-agent/openuem.ini` (`[NATS] NATSServers=`, `SFTPPort`, `VNCProxyPort`,
    `TenantID`, `SiteID`). An existing ini (UUID, org/site, console changes) is kept; only
    `NATSServers` is rewritten.
  - **Certificates** into `/etc/openuem-agent/certificates/` (ca.cer, sftp.cer, agent.cer,
    agent.key) with the package's ownership/permissions, then `systemctl restart openuem-agent`.
  - **Fork only:** the official updater `openuem-agent-updater` is disabled (`disable --now`,
    on apt systems additionally `apt-mark hold openuem-agent` so `apt upgrade` doesn't replace
    the fork binary), and `/opt/openuem-agent/bin/openuem-agent` is replaced with the fork build
    (official kept as `openuem-agent.official`).
- **Self-contained:** the server script appends a tarball with the certificates, the amd64 and
  arm64 agents, the official .deb packages (amd64/arm64) and `settings.env` (server IP, domain,
  ports, commit, `OFFICIAL_AGENT_VERSION`). Run it with
  `sudo bash openuem-agent-fork-install.sh [--org <id> --site <id>] [--domain …] [--nats-port …] [--server-ip …] [--files-dir …]`
  (DNS must resolve the names; no hosts entries are written).
- **Distributions:** any systemd distribution. The agent is a static Go binary, so the kernel
  version and the C library don't matter. Inventory and update status come from the upstream
  agent, which reads dpkg and rpm: on Arch only Flatpak and Snap apps are listed, and the
  update status is "unknown".
- **Tested on the VMs (2026-11-19, old custom flow, kept for history):** see the two blocks below.
- **Tested on the VMs (2026-11-19, rework to the official flow):**
  - **Windows, official setup re-run:** running the official `openuem-agent-setup.exe` again on an
    installed agent exits 0, keeps UUID/TenantID/SiteID/ports in `config\openuem.ini` and only
    replaces the binary — so the fork installer can always run the official setup and swap after.
  - **Windows fork setup (Inno build), update as SYSTEM:** `openuem-agent-fork-setup.exe /OVERWRITE`
    → exit code 0, official installer re-run with the official flags, fork binary swapped
    (`.official` kept), `config\openuem.ini` rewritten by `-Overwrite`, service running, log at
    `%ProgramData%\OpenUEM-fork\install-agent.log`, `C:\openuem-agent` empty afterwards. Also with
    explicit `/VERYSILENT /SUPPRESSMSGBOXES` → exit 0. Without any silent switch → the worker runs
    in `InitializeSetup` (no UI) → exit 0. (First attempts with a self re-launch failed: Inno's
    AppId setup mutex blocks the child; and `ExtractTemporaryFile` needs base names, not `files\…`.)
  - **Inno detection:** the built `openuem-agent-fork-setup.exe` carries `Inno Setup Setup Data
    (6.6.1)` / `Inno Setup Messages (6.5.0)` (same as the official 0.11.0 setup) and
    `wingetrepo.ReadExeInfo` reports `type=inno`, name "OpenUEM Agent (fork)".
  - **ISCC pipeline:** `debian:trixie-slim` + wine (win32 prefix) + xvfb/xauth + Inno Setup 6.6.1
    from `github.com/jrsoftware/issrc/releases/download/is-6_6_1/…` (files.jrsoftware.org 404s
    since March 2026); `xvfb-run -a wine innosetup-6.6.1.exe /VERYSILENT …` installs it;
    ISCC.exe is found under `C:\Program Files\Inno Setup 6` in a win32 prefix.
  - **Linux on Arch (no apt/dnf):** `sudo bash openuem-agent-fork-install.sh` → exit 0; the bundled
    official `.deb` is extracted (`ar p … data.tar.xz | tar -x` — plain `bsdtar -xf` on a .deb only
    extracts the ar members), installing the **official** `openuem-agent.service`/`openuem-agent-updater.service`
    and `/opt/openuem-agent/bin/*`; updater unit present but `disabled`/`inactive`; fork binary
    installed, old one kept as `openuem-agent.official`; certs in `/etc/openuem-agent/certificates/`
    (openuem-agent:openuem-agent); existing `openuem.ini` kept (UUID, TenantID/SiteID), only
    `NATSServers` rewritten; service active; no hosts entries written; no stray ar members in `/`.
- **Tested on the VMs (2026-11-19, old custom flow):**
  - Arch Linux on mainline kernel 7.3.4: a fresh install with `--org 2 --site 2` landed in site 2, then an update;
  - the same VM on `linux-lts` 6.18.64 after a reboot: the agent is running and connected;
  - Debian 13 on 6.12 LTS: took over an existing configuration;
  - `--org` without `--site` is refused;
  - **takeover of an installed official .deb** (2026-11-19, `uemlegacy`, Debian 13, official `openuem-agent` 0.11.0 .deb, active agent and updater, own UUID): the installer exited 0, saved the official binary as `openuem-agent.official` (SHA-256 verified), installed the fork build (SHA-256 matches the server's `agent-builds`), kept the configuration (UUID, org/site untouched; only `NATSServers` was switched to the fork server), replaced the certificates with the server's, disabled and stopped `openuem-agent-updater` and left the service running (no hosts entries are written anymore; the VM already had them). The computer appeared on the fork server as waiting for admission, was admitted in the console, shows as Enabled with inventory (Debian 13.7) and answers "Check for updates" (dpkg). A second run is an idempotent update: exit 0, the fork binary stays, `.official` is not overwritten (the message now says "is kept as" instead of "was saved as"). The package stays installed (`dpkg-query` still reports it), so a later `apt upgrade` would replace the binary again; re-running the installer restores the fork build. (In the rework the package is additionally put on `apt-mark hold`.)
- **Tested on the VMs (2026-11-19, old NSIS setup, kept for history):**
  - update as SYSTEM (`/S`): exit code 0, binary replaced;
  - fresh install as SYSTEM on a computer without agent, config or hosts entries: exit code 0, official agent plus the fork's binary installed, computer appeared as waiting for admission, admitted, reported and registered the winget source;
  - failure (NATS not reachable): exit code 1 with the reason in the log;
  - afterwards `C:\openuem-agent` is empty and only administrators and SYSTEM have access, and the setup's temp folder is gone;
  - the server script piped from GitHub and run as a local file both build it.

## 4. Status

### Verified

**In containers.** That's the full Docker stack plus a Linux agent built from the fork, driven with Playwright, and checked with curl and Microsoft's OpenAPI documents. All of these work:
- admission, and the NATS permissions with no violations;
- the Software updates page;
- update all, online and offline: the queued run runs once when the computer reconnects;
- the update status page;
- MSI, Inno, generic EXE and MSIX uploads;
- the winget REST source over HTTPS: tokens, search, manifests (schema-valid), and installer downloads matching their SHA-256;
- the worker answering profiles with `source: OpenUEM` and `source: winget`.

**On a Windows 11 VM**, earlier rounds:
- available updates listed;
- update all;
- PowerShell tasks;
- the OpenUEM CA added to the trusted roots;
- ports 1323 and 8000 reachable.

**On Windows 11 VMs, 2026-11-18 (unattended run):** the whole `TEST_PLAN.md`, with the
server and agent installed by the install scripts. Everything passed after the fixes
below, except the optional MSIX upload on Windows, which wasn't tested.

**Behind a reverse proxy (Caddy), 2026-11-19, on the server VM:** enabled the official
`compose.caddy.yml` (see the known upstream issue in section 7: the shipped Caddyfile
crash-loops, delete the `//`-commented block first), generated
`certificates/console/proxy.cer`/`proxy.key` for `console.<domain>` signed by the
OpenUEM CA, and set `REVERSE_PROXY_HOST=console.<domain>`,
`REVERSE_PROXY_CONSOLE_PORT=443`, `REVERSE_PROXY_AUTH_PORT=8443` in `.env`. Verified with
curl from the VM:
- `GET https://console.<domain>/auth` (via Caddy :443) redirects to
  `https://console.<domain>:8443/auth` — the console uses the proxy settings;
- `GET :8443/auth` with the admin user certificate (Caddy `require_and_verify`, forwards
  the `Client-Cert` header) → 302 to `https://console.<domain>/tenant/1/site/1/dashboard`
  with a session cookie, and the dashboard returns 200 through the proxy with that cookie;
  the auth log records "user admin has logged in with a digital certificate";
- `:8443` without a client certificate is rejected in the TLS handshake;
- the direct ports are unaffected: `:1323` serves the console, agents keep reporting, and
  `:1324` still accepts the `Client-Cert` header while proxy mode is on (keep 1324
  unreachable from outside when a proxy is configured).
Not repeated in a browser (the VM's proxy ports aren't forwarded to the host); the
server-side chain is fully verified, and Chromium's client-certificate login on the direct
port was verified in an earlier round.

### Fixed after testing on Windows

| Where | Problem | Fix |
|---|---|---|
| agent | Every install from the repository failed as SYSTEM with `0x8A150001` after "Installer hash verified": winget checks installers of untrusted sources with `IAttachmentExecute`, which needs an interactive session | Source added with `--trust-level trusted`; existing registrations are redone once |
| console | The derived identifier contained the version (`IgorPavlov.7Zip2408X64Edition`), so each upload was a new package and never an update | Version left out of the identifier |
| console | `manifestSearch` by product code returned only the matching version, so `winget upgrade` never offered the newer one | All versions of a matching package are returned |
| agent | User sessions listed machine-wide programs too; a library package (source only registered for SYSTEM) showed up as the community package "for the user" | User sessions list with `--scope user` |
| agent | While App Installer updated itself, its new folder had an empty `winget.exe` and every winget command failed ("%1 is not a valid Win32 application") | Newest version with a usable `winget.exe`, compared as numbers |
| console | The shared package catalog showed every organization's library packages in Deploy search and task search | Other organizations' packages are left out |
| console | The task search (`/packages`) has no organization in its URL and used the default organization | The task form sends its profile; global profiles get only packages for all organizations |
| console | Contact details in an EXE's publisher ended up in the identifier (`DonHODonHFreeFr.Notepad`) | E-mail and web addresses removed |
| console | The EXE test data was never committed (`*.exe` in `.gitignore`), so the tests failed on a fresh clone | Added with `git add -f` |
| install script (Windows) | `cmd /c ssh … > file` hung on larger output when the script ran without a console (SSH, remote management) | `Start-Process -RedirectStandardOutput` |

### Production readiness round (2026-11-18, second session)

Asked whether the build is ready for a live system, this round did:
- **Two independent code reviews** (console and agent, security and correctness, with fuzzing of the installer parsers and race tests). Every finding is fixed except the documented limitations below.
- **Two upstream bugs that the fork makes more visible, fixed:** installs recorded as successful when winget failed, and duplicate deployments stuck "In Progress".
- **Upgrade of an existing official installation:** the published images (console, workers) with an admitted official 0.11.0 agent, a profile with a task and a deployment were upgraded with `install-openuem-fork.sh`. All 41 tables kept their rows, the official agent kept working with the fork console, the profile is shown with its task, and the rollback (`rm compose.override.yml && docker compose up -d`) to the published images works on the migrated database.

**Setup wizard round (2026-11-20):** `fd4b182` on `install-script`. On the Windows 11 VM as SYSTEM:
without switches the setup and its Inno `.tmp` engine sat waiting for 45 s without touching the agent
(the install log unchanged, the service untouched) — the wizard waits for the user, it no longer
self-installs; with `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART` the update ran through: exit code 0,
the service running, the log ending in "The fork's agent is installed, the official binary was saved
as ...exe.official". (The wizard's window can't be read from a headless session; with an interactive
logon the window shows like the official setup's.)

**Dashboard round 2 (2026-11-20, updates needed pie and tooltips):** `0e9b68a`+`7dd965d`. Verified live like the round
below: the new pie shows `No updates=1` (the online Windows 11 VM, whose winget is up to date) with the center 1, because only
computers that answer the hourly count are counted; the hover tooltips of all six pie cards appear; the
"Computers that need software updates" counter row (0) links to the Deploy update status page.

**Dashboard round (2026-11-20):** `feat(dashboard)` in the console's two branches adds the fork's
statistics to the dashboard (see §1 item 4). Verified on the server VM after `install-openuem-fork.sh`
rebuilt the console from `feature/bulk-software-updates` @ `2e6852d`: the three new pies render with
the lab's data (deployments 6 installed / 1 failed; library 5 packages over MSI, Inno, NSIS and a
generic EXE; update runs 1 finished without failures, 3 no answer, total 4 computers), the new
"Packages in the software library" counter links to the software library, and `go test` of the
models, handlers and wingetrepo packages passes (the pre-existing `TestUserTestSuite/TestConfirmEmail`
failure also fails on a clean checkout).

**Documented limitations (not fixed, decide before going live):**
- **Repository tokens don't expire**; disabling or deleting an agent revokes its token, rotating the console's JWT key revokes all (and everything else signed with it).
- **The OpenUEM CA goes into the computers' Root store** when the console has no reverse proxy. Whoever has the CA key can then issue certificates the computers trust for any host. With a reverse proxy that has a public certificate, it isn't added (`TrustCA` false).
- **Listing a computer's updates** keeps the HTTP request open up to a few minutes; behind a reverse proxy, raise its read timeout (e.g. nginx `proxy_read_timeout 600s`).
- **A queued run is acknowledged when it starts**: interrupted by a reboot, it's shown as interrupted and has to be requested again.
- **Remote Desktop servers with many sessions:** updates are listed session after session.
- **Single-role console** (upstream): every console user can act on every organization.
- **`go.mod` replaces `open-uem/nats` with `devilAPI/nats`** until the nats PR is merged; the live build depends on that repository.
- **Back up the database before upgrading** a live system (`docker compose exec db pg_dump …`); the script doesn't.

## 5. Next steps

1. ~~Fork the worker~~, ~~update server and VM~~, ~~run `TEST_PLAN.md`~~, ~~merge `remove-task-uploads`~~: done 2026-11-18.
2. ~~Update the agent and console PR descriptions and titles~~: done (#216, #499), with `#ISSUE` replaced by `#498`.
   **Open the worker PR** with `pr/worker.md` (replace `#ISSUE` with `#498`), title `feat: install profile packages of the console's winget repository from it`, from `devilAPI:software-updates` into `open-uem/openuem-worker:main`. The unattended session wasn't allowed to open a new upstream PR.
3. Optional: test an `.msix` on Windows and the certificate login behind a reverse proxy (the installer URL fix for proxies is unit-tested only).
4. Delete the merged `remove-task-uploads` branches (console, agent).
5. **After the nats PR is merged:** replace the `replace` pins (see 2.4).

## 6. Rules agreed with the user

- **Commit and push after every change.** No force-push and no history rewrite without explicit approval.
- **Commit identity:** `devilAPI <devilAPI@users.noreply.github.com>`, never a personal e-mail.
- **No names in commits or files:** never mention the user's company, domain, server IPs or personal names in commits, code or documents. Use `uem.example.com` / `192.0.2.10` in examples.
- **PRs should merge easily upstream:**
  - conventional commits, and no unrelated changes such as `go.sum` tidy churn or gofmt of upstream files;
  - translations for all 7 locales (en, de, es, ca, fr, pt, no);
  - only CSS classes that exist in the precompiled `main.css`;
  - `templ fmt` and `templ generate` with templ v0.3.1001.
- **Contributing process:** there's no contributing guide upstream. The org README asks for an issue first (`pr/issue.md`), and the PR descriptions follow the console's issue templates.

## 7. Known upstream issues (not caused by the fork, not changed)

- **Error pages:** `customHTTPErrorHandler` renders error pages with HTTP status 200.
- **No release data:** without release data (no access to `releases.openuem.eu`), the dashboard and every computer page panic on a nil `agent.Edges.Release`.
- **Failing tests:** `internal/models` `TestUserTestSuite` and `TestSMTPTestSuite` fail on `main`.
- **Leader election:** `nats.cfg` files from the published openuem-cert-manager image lack the console's leader election permissions, so the package search stays empty. The install script adds them.
- **NATS OCSP cache.** NATS caches OCSP answers for 24 hours in the container itself. If it starts before the OCSP responder can answer (e.g. after a reboot), it caches "unknown" and refuses the workers with `client not OCSP valid`. Fix: `docker compose up -d --force-recreate nats-server`.
- **Login:** the first login with the generated password forces a password change (min. 15 characters), and `/login/userpass` is rate-limited.
- ~~winget installs reported as successful when they failed~~ and ~~duplicate deployments~~: fixed in the fork (see 2.3), as they hit library packages.
- **The official agent's Debian package hangs in unattended installs**: its debconf `config` script loops `while [ -z "$nats_server" ]` around the prompt, so `DEBIAN_FRONTEND=noninteractive apt-get install` spins forever unless `openuem-agent/nats-server` is preseeded with `debconf-set-selections`.
- **New organizations default to "default organization: Yes"** in the form, so creating one silently makes it the default for newly registered agents.
- **Profile tasks re-run on installed packages** ("Run only once" aside); with the fork's install fix they now end as "already installed and up to date".
- **The shipped reverse proxy is broken as delivered:** `caddy/Caddyfile` uses `//` comments, which Caddy doesn't support (comments are `#`), so `openuem-reverse-proxy` crash-loops with "Unexpected '}'" as soon as `compose.caddy.yml` is included; the commented block also references an unset `NATS_WEBSOCKETPORT`. Delete the commented block. Also, `certificates/console/proxy.cer`/`proxy.key` are not created by the cert-manager and must be issued for the console domain signed by the OpenUEM CA before Caddy can start. Verified working after fixing both (see section 4).
- **curl/openssl don't complete certificate login on the auth port, browsers do:** `GET :1324/auth` with a client certificate sent by curl or openssl s_client is answered with "Please provide valid credentials" (the Go handler sees no peer certificate), on upstream `main` too. Chromium presents the certificate correctly, so use a browser for this test.

## 8. Testing without Windows (how the container tests were done)

- **Stack:** the official `openuem-docker` compose files plus the same `compose.override.yml` the install script writes. The images layer fork binaries built on the host (`FROM openuem/openuem-console`, `COPY openuem-console /bin/`), likewise for the worker.
- **Linux agent:** the fork agent in a `debian` container on the compose network, with `/etc/openuem-agent/openuem.ini`. Remove an empty `WebSocketPort=`, set the certificate paths, then admit it in the console.
- **Browser:** Playwright with Chromium. Map `console.<domain>` to 127.0.0.1 in `/etc/hosts` and run without the sandbox's HTTP proxy variables.
- **REST source:** the token is `base64url(HMAC-SHA256(CONSOLE_JWT_KEY, "openuem-winget-source:" + agentID))`. Validate the responses against `documentation/WinGet-1.0.0.yaml` / `WinGet-1.1.0.yaml` from microsoft/winget-cli-restsource with `jsonschema`.
- **Profiles:** insert a profile and tasks, then send `wingetcfg.profiles` `{"agentID":…}` over NATS with the agent certificate.
- **EXE test data:** built with `clang`, `llvm-rc` and `lld-link` (see `internal/wingetrepo/testdata/README.md` in the console).
