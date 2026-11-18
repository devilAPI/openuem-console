# Handoff: bulk software updates and private winget repository for OpenUEM

State as of 2026-11-18. This folder lives on the `install-script` branch of
`devilAPI/openuem-console`, which only holds tooling for the fork and is never part of a
pull request.

| File | What it is |
|---|---|
| `HANDOFF.md` | This document |
| `TEST_PLAN.md` | What still has to be tested on a real Windows computer, with ticks so far |
| `pr/*.md` | Pull request descriptions (nats, cert-manager, agent, console, worker) and the feature request issue (`issue.md`) |
| `worker-patches/*.patch` | The openuem-worker commits, until the fork exists (see "Next steps") |
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
3. **MSI upload for profile tasks** (`/agent-files` on the auth server). It's **superseded by 2.** and its removal is ready on separate branches (see 2.3).
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
| `remove-task-uploads` | Removal of the MSI task upload (item 3), on top of the feature branch. **Not merged yet**, see "Next steps". |
| `install-script` (console repo only) | Install scripts and this handoff |

### 2.2 Current heads

| Repository | `feature/bulk-software-updates` | `software-updates` (PR) | `remove-task-uploads` |
|---|---|---|---|
| nats | `d9b855a` | `b3a4794` | – |
| openuem-agent | `1c0972c` | `3a8e4b2` | `80dcb93` |
| openuem-console | `193fefc` | `61ebb9f` | `6e6dbb1` |
| openuem-cert-manager | – | `626b464` | – |
| openuem-worker | – | `057f2d8`, **fork doesn't exist yet**, see `worker-patches/` | – |
| install-script (console repo) | | | this commit |

### 2.3 Commits of the PR branches

- **nats:**
  - `d19f31f` types to list available package updates and run bulk updates
  - `b3a4794` message to register the console's winget repository (`WinGetSourceConfig`)
- **cert-manager:** NATS permissions in `scripts/generate-nats-conf.sh`:
  - `dda0193` the update subjects
  - `626b464` `agent.wingetsource.>`
- **agent:**
  - `a79aaad` bulk, queued and user-scoped updates (and the MSI download, removed by `remove-task-uploads`)
  - `ea46457` registers the winget repository
  - `3a8e4b2` logs winget's own error lines when that fails
- **console:**
  - `c62c336` bulk updates, update status, MSI uploads for tasks
  - `99763b4` private winget repository
  - `2dc50cb` repository served on the console port
  - `c27d686` EXE and MSIX
  - `61ebb9f` profile tasks can use library packages
- **worker:**
  - `f2d0514` profile tasks use the source `OpenUEM` for library packages
  - `057f2d8` Dockerfile fix

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

### Not verified yet (see `TEST_PLAN.md`)

- **Registering the winget source on Windows with the port 1323 fix.** The last failed attempts (`0x8A150045`) were all from before the server update, so the fix hasn't been tried.
- Installing, updating and uninstalling library packages with winget on Windows (MSI, EXE, MSIX).
- A profile installing a library package (needs the worker fork).
- Per-user app updates, an interrupted run, an offline Windows computer, and the regression checks.

## 5. Next steps

1. **Fork `open-uem/openuem-worker` to `devilAPI`**, then push the branch, either from a clone that has it or by applying `worker-patches/`:
   ```bash
   git clone https://github.com/devilAPI/openuem-worker && cd openuem-worker
   git checkout -b software-updates origin/main
   git am /path/to/handoff/worker-patches/*.patch
   git push -u origin software-updates
   ```
   The next server update then builds the worker from the fork.
2. **Update the server and the VM** (commands in `TEST_PLAN.md`), click **Register** in Deploy → Software library, and check the agent log. If it fails, the log now contains winget's own lines (an HRESULT such as `80072F8F` or `80072F0C`). Those decide the next fix.
3. **Run the rest of `TEST_PLAN.md`.**
4. **Once a profile installs a library package on Windows, merge `remove-task-uploads`** (the user's condition: remove the task upload only if the functionality is preserved):
   - merge it into `feature/bulk-software-updates` in the console and agent;
   - in the PR branches, squash it into the first console/agent commits, or add it as a commit;
   - remove the `task-files` volume from `install-openuem-fork.sh`;
   - update `pr/console.md` and `pr/agent.md`: remove the "Uploaded MSI packages" sections and the `/agent-files` tests.
5. **Update the PR descriptions** on GitHub from `pr/*.md`, and open the worker PR with `pr/worker.md`. Then tick the manual tests that passed.
6. **After the nats PR is merged:** replace the `replace` pins (see 2.4).

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

## 8. Testing without Windows (how the container tests were done)

- **Stack:** the official `openuem-docker` compose files plus the same `compose.override.yml` the install script writes. The images layer fork binaries built on the host (`FROM openuem/openuem-console`, `COPY openuem-console /bin/`), likewise for the worker.
- **Linux agent:** the fork agent in a `debian` container on the compose network, with `/etc/openuem-agent/openuem.ini`. Remove an empty `WebSocketPort=`, set the certificate paths, then admit it in the console.
- **Browser:** Playwright with Chromium. Map `console.<domain>` to 127.0.0.1 in `/etc/hosts` and run without the sandbox's HTTP proxy variables.
- **REST source:** the token is `base64url(HMAC-SHA256(CONSOLE_JWT_KEY, "openuem-winget-source:" + agentID))`. Validate the responses against `documentation/WinGet-1.0.0.yaml` / `WinGet-1.1.0.yaml` from microsoft/winget-cli-restsource with `jsonschema`.
- **Profiles:** insert a profile and tasks, then send `wingetcfg.profiles` `{"agentID":…}` over NATS with the agent certificate.
- **EXE test data:** built with `clang`, `llvm-rc` and `lld-link` (see `internal/wingetrepo/testdata/README.md` in the console).
