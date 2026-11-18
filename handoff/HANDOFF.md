# Handoff: bulk software updates and private winget repository for OpenUEM

State as of 2026-11-18. This folder lives on the `install-script` branch of
`devilAPI/openuem-console`, which only holds tooling for the fork and is never part of a
pull request.

| File | What it is |
|---|---|
| `HANDOFF.md` | This document |
| `TEST_PLAN.md` | The Windows test plan with the results of the VM test run (2026-11-18) |
| `pr/*.md` | Pull request descriptions (nats, cert-manager, agent, console, worker) and the feature request issue (`issue.md`) |
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
4. **Smaller fixes along the way:**
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
| `software-updates` | **PR branches**: one squashed commit per feature step, on top of upstream `main`. Fixes are cherry-picked here from the feature branch. Their tree equals the feature branch apart from the `go.mod`/`go.sum` pins. |
| `remove-task-uploads` | Removal of the MSI task upload (item 3). **Merged** into the feature branches and added as a commit to the PR branches; the branch can be deleted. |
| `install-script` (console repo only) | Install scripts and this handoff |

### 2.2 Current heads

| Repository | `feature/bulk-software-updates` | `software-updates` (PR) | upstream PR |
|---|---|---|---|
| nats | `d9b855a` | `b3a4794` | #24 |
| openuem-agent | `a53b63b` | `2487602` | #216 |
| openuem-console | `ef3a9f2` | `1030b44` | #499 (issue #498) |
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
- **console:**
  - `c62c336` bulk updates, update status, MSI uploads for tasks
  - `99763b4` private winget repository
  - `2dc50cb` repository served on the console port
  - `c27d686` EXE and MSIX
  - `61ebb9f` profile tasks can use library packages
  - `61192ae` no version in derived package identifiers
  - `1aeb5f7` EXE test data that `.gitignore` left out
  - `fb60764` search results list every version of a package
  - `5ccda5a` other organizations' library packages hidden from the searches
  - `a4be997` no contact details in derived package identifiers
  - `86bc5f1` task search offers the packages of the profile's organization
  - `c7e7325` removes the MSI uploads for tasks
  - `39c7d64` an install reuses the package's deployment, duplicates merged (upstream bug)
  - `57cecf1` MSI headers checked before parsing (a crafted file crashed the console)
  - `50e7127` an identifier belongs to one organization; safe replace; crash leftovers removed
  - `cd13893` library identifiers can't take over community identifiers
  - `96f158e` package pickers without values in hyperscript (upstream sink)
  - `be35d00` installer URLs from the registered base URL (reverse proxies)
  - `d2f0be1` concurrent install requests saved one at a time
  - `1030b44` no second queued request while one is waiting
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

`go.sum` is kept minimal on purpose: don't commit the churn from `go mod tidy` (it removes unrelated upstream lines).

### 2.5 Merge order upstream

1. nats
2. cert-manager
3. agent
4. console
5. worker

The worker only reads the catalog that the console fills.

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

- **What it does:**
  - adds hosts entries, but only rewrites them when they're wrong;
  - copies the certificates and the fork agent over one SSH connection;
  - installs the official agent 0.11.0 if missing;
  - replaces its binary, keeping the original as `.official`.
- **Later runs need no parameters.** The settings come from the last run (`%ProgramData%\OpenUEM-fork\install-agent.json`), then from the installed agent's `config\openuem.ini`, the hosts file or DNS.
- **Defender:** ASR rules on managed company PCs block the unsigned agent, so test on a computer without those policies.

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
below, except the optional MSIX upload on Windows and the login behind a reverse proxy,
which weren't tested.

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

## 8. Testing without Windows (how the container tests were done)

- **Stack:** the official `openuem-docker` compose files plus the same `compose.override.yml` the install script writes. The images layer fork binaries built on the host (`FROM openuem/openuem-console`, `COPY openuem-console /bin/`), likewise for the worker.
- **Linux agent:** the fork agent in a `debian` container on the compose network, with `/etc/openuem-agent/openuem.ini`. Remove an empty `WebSocketPort=`, set the certificate paths, then admit it in the console.
- **Browser:** Playwright with Chromium. Map `console.<domain>` to 127.0.0.1 in `/etc/hosts` and run without the sandbox's HTTP proxy variables.
- **REST source:** the token is `base64url(HMAC-SHA256(CONSOLE_JWT_KEY, "openuem-winget-source:" + agentID))`. Validate the responses against `documentation/WinGet-1.0.0.yaml` / `WinGet-1.1.0.yaml` from microsoft/winget-cli-restsource with `jsonschema`.
- **Profiles:** insert a profile and tasks, then send `wingetcfg.profiles` `{"agentID":…}` over NATS with the agent certificate.
- **EXE test data:** built with `clang`, `llvm-rc` and `lld-link` (see `internal/wingetrepo/testdata/README.md` in the console).
