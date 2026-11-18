Related to open-uem/openuem-console#ISSUE (feature request: bulk software updates).

## Summary

The agent can now:
- list the packages that have an available update, for winget, flatpak and Homebrew,
- update several packages in one run, started directly or queued in JetStream for computers that are offline,
- find and update packages installed for the logged-in users on Windows,
- report the status of its last run,
- download MSI packages uploaded to the console for tasks, authenticating with the agent certificate,
- register the console's private winget repository on Windows, so packages uploaded to the console's Software library are installed and updated with winget.

It also fixes two existing bugs that made failed winget updates look successful, and the logging of failed PowerShell script tasks.

## Motivation

- **Machine-wide only:** the agent runs as SYSTEM, so `winget` only sees machine-wide packages. Packages installed for a single user (Spotify, the VS Code user installer, many Store apps, …) are invisible and never updated.
- **One package at a time:** the only update path is `agent.updatepackage`, for one package. There is no way to know which packages have updates, or to update them all.
- **Silent failures:** `UpdatePackage` piped winget through `Select-String`. The exit code of a PowerShell pipeline is that of its last command, so winget errors were lost and failed updates were reported as successful.

## How it works

### New subjects

| Subject | Kind | Purpose |
|---|---|---|
| `agent.listpackageupdates.<uuid>` | request/reply, queue `openuem-agent-management` | Replies with the available updates and the last bulk run (`AvailableUpdatesResponse`). While a run is in progress, only its progress is returned. With `{"statusonly": true}`, the package manager isn't run, so status pages can ask many agents cheaply. |
| `agent.updatepackages.<uuid>` | request/reply, queue `openuem-agent-management` | Starts a run for the given packages (or all if empty) and replies right away: empty means started, otherwise the reason (e.g. a run is already in progress). The console uses the reply to report offline or busy computers. |
| `agent.wingetsource.<uuid>` | request/reply, queue `openuem-agent-management` | Registers the console's winget REST source (`WinGetSourceConfig`). The agent replies right away and registers in the background. |
| `agent.update.packages.<uuid>` | JetStream, AGENTS_STREAM | The same request, queued. It's already covered by the stream's `agent.update.>` subject and is added to the filter of the agent's durable consumer, so computers that were offline receive it when they connect. |

The request/reply subjects need NATS permissions, which the openuem-cert-manager PR adds.

### Listing updates
- **Windows:** `winget upgrade` runs as SYSTEM and, through the user sessions (see below), as each logged-in user. Packages found only in a user session are reported as `scope: user` with the user names. If the SYSTEM listing fails partially, user sessions are skipped, so machine-wide packages can't be mistaken for user-scoped ones.
  - The output is a localized table, so columns are located by their position in the header (honouring East Asian wide characters), not by their names.
  - Footers, progress spinners and the "require explicit targeting" table are ignored.
  - Truncated ids (`…`) are skipped, as they can't be targeted.
- **Linux:** `flatpak remote-ls --updates` merged with `flatpak list`, for the system installation and for the logged-in user's `--user` installation.
- **macOS:** `brew outdated --json=v2` as the logged-in user, after a best-effort `brew update`. Pinned formulae are skipped.

### Packages installed for a user (Windows)
`runtime.GetUserSessions()` enumerates the sessions with `WTSEnumerateSessions` and gets each user's token with `WTSQueryUserToken`. winget then runs in each session through the user's app execution alias, `%LOCALAPPDATA%\Microsoft\WindowsApps\winget.exe`:
- with the user's environment,
- without a window,
- at below normal priority.

Unlike `RunAsUser`, which borrows the token of the first `explorer.exe` it finds, this covers every logged-in user (fast user switching, RDS). Users without the package are skipped.

### Update runs
- **One package at a time:** a mutex also keeps a single-package update from running at the same time as a bulk run.
- **Results are also deployment results:** each result is sent as a normal `deployresult`, so deployments made with OpenUEM keep their status. The worker ignores packages it doesn't track.
- **The last run is kept on the agent:** it's stored in `last_update_run.json` in the agent's data directory. A run interrupted by a restart is reported as interrupted.
- **Queued requests:**
  - ignored if older than 30 days, or if a run started after them (e.g. the update was requested several times while the computer was offline),
  - delivered again 10 minutes later if a run is in progress.
- **Inventory:** a report is sent after each run, so the console shows the new versions.

### MSI packages uploaded to the console
MSI task paths of the form `https://<console>:<auth port>/agent-files/<profile>/<sha256>/<name>` are downloaded by the agent before msiexec runs:
- **Authentication:** the agent presents the agent certificate and sends its id in `X-OpenUEM-Agent`. The console only serves the file to agents the profile applies to.
- **Trust:** OpenUEM's CA plus the system's CAs, for consoles behind a reverse proxy with a public certificate.
- **Verification:** the download must match the SHA-256 hash in the URL.
- **Local file:** saved as `<hash>.msi`, a name that's safe on a command line, and removed after msiexec ran.

Other paths (URLs, shares, local paths) are passed to msiexec as before.

### Private winget repository (Windows)

The console hosts a winget REST source with the MSI packages uploaded to its Software library (see the console PR). Computers only need outbound HTTPS to the console; nothing is pushed to them.

- **Registration:** on `agent.wingetsource.<uuid>`, the agent runs `winget source remove` and `winget source add --name OpenUEM --arg <url> --type Microsoft.Rest --accept-source-agreements --disable-interactivity`.
- **Certificate:** winget needs a certificate it trusts. With `TrustCA`, which the console sets when it has no reverse proxy with a public certificate, the agent first adds the OpenUEM CA to the machine's trusted root store with `certutil -addstore -f Root`.
- **No unnecessary runs:** the last registered source is kept in `winget_source.json` (mode 0600, it contains the agent's token URL). The console sends the registration every 30 minutes, and winget only runs when the name, URL or CA setting changed or the last registration failed.
- **Other systems** reply and ignore the message.

## Bug fixes

- **Failed winget updates reported as successful.** winget now runs directly, without PowerShell, and its exit code is mapped with `wingetcfg.ErrorCodes`.
- **The `0x8A15002B` ("no applicable update") check never matched.** It compared a lower-cased code with an upper-cased one. It's now `deploy.ErrNoApplicableUpdate`, and an up-to-date package is reported as updated, as before.
- **Packages not installed machine-wide reported as failed.** When no scope is given, the agent now tries the logged-in users' sessions. If nobody has the package, it's reported as not installed instead of failed. This matters when a package is updated on many computers from the console.
- **Empty reason for failed PowerShell script tasks.** The logged reason was the output of the previous `Set-ExecutionPolicy` command, which is empty. It's now what the script wrote.
- **Package ids are validated** before they're passed to a package manager: not empty, no leading `-`, no whitespace or shell metacharacters.

## Compatibility and upgrade notes

- **winget 1.4 or newer** is required (`--disable-interactivity`).
- **Unknown messages:** existing consoles don't send the new messages. New consoles talking to old agents get "no responders", and the console reports it.
- **Timeouts:**
  - Listing runs with a 3-minute timeout per invocation (SYSTEM and each user), so a full listing stays within the console's timeout.
  - Each upgrade has a 60-minute timeout.
- **Priority:** machine-wide upgrades now use `--id <id> --exact` and below normal priority, instead of a query and idle priority.
- **Temporary dependency:** `go.mod` replaces `github.com/open-uem/nats` with the fork that contains the new types, until the nats PR is merged.

## Tests

### Unit tests
- **winget table parser:** spinner output, a truncated id, a version with `<`, a footer, the explicit targeting table, German headers with a French footer that has as many words as a row, wide characters, no updates.
- **flatpak and Homebrew parsers:** including Homebrew warnings around the JSON and an old string format of `installed_versions`.
- **Package id validation.**
- **Run tracker:** concurrent start, copies, interrupted runs, errors.
- **MSI downloads:** URL detection, verified download (hash mismatch, HTTP errors, no leftovers), extension handling.
- **winget source state:** registration is skipped when nothing changed and retried after a failure.

### Builds
`GOOS=windows|linux|darwin go vet ./...` and `go test ./...` pass.

### Manual tests
Tested on a Windows 11 endpoint with a Docker deployment:
- [x] available updates listed on the computer's Software updates page
- [x] update all software run from the console
- [x] a PowerShell script task runs

End to end with the console, NATS and a Linux agent in containers:
- [x] the agent connects, is admitted and its subscriptions are accepted
- [x] Update all software on an online computer starts a run, and the status page shows it
- [x] an update requested while the computer was offline runs once when it connects

Still to be verified on real endpoints before merging:
- [ ] the OpenUEM winget source is registered (`winget source list`), and a library package is found, installed, updated and uninstalled with winget
- [ ] a per-user app is listed with its user and updated in the user's session
- [ ] the agent restarted during a run reports it as interrupted
- [ ] an uploaded MSI is installed through a task
- [ ] a failing PowerShell task shows the script's error

Linux (flatpak) and macOS (Homebrew) are covered by unit tests only.

## Merge order

1. open-uem/nats: message types
2. open-uem/openuem-cert-manager: NATS permissions
3. **This PR**, after replacing the temporary `replace` with the merged nats version
4. open-uem/openuem-console

## Checklist

- [x] Conventional commit title
- [x] Builds and vets on Windows, Linux and macOS
- [x] Unit tests added
- [x] Tested on a Windows endpoint (see the manual tests above for what is still to be verified)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01FVN6i1yNq2pA1uqE9wBGDr
