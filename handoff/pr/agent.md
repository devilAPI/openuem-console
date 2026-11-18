Related to open-uem/openuem-console#ISSUE (feature request: bulk software updates).

## Summary

The agent can now:
- list the packages that have an available update, for winget, flatpak and Homebrew,
- update several packages in one run, started directly or queued in JetStream for computers that are offline,
- find and update packages installed for the logged-in users on Windows,
- report the status of its last run,
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
- **Windows:** `winget upgrade` runs as SYSTEM and, through the user sessions (see below), as each logged-in user with `--scope user`. Packages found in a user session are reported as `scope: user` with the user names. Without the scope, a user's winget would also list machine-wide programs, and one that the user's sources match with another package than SYSTEM's (e.g. a library package, whose source is only registered for SYSTEM) would be updated as the user's. If the SYSTEM listing fails partially, user sessions are skipped, so machine-wide packages can't be mistaken for user-scoped ones.
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

The user controls the session's environment and the alias, so `LOCALAPPDATA` is only used when it's a local drive path (a network path would make SYSTEM access the share with the computer's account), the output kept is capped at 4 MB, and the agent stops waiting for the output 30 seconds after a command ended or was killed (installers started by winget may hold the pipe). Sessions are listed one after another, so on Remote Desktop servers with many users a listing takes accordingly long.

### Update runs
- **One package at a time:** a mutex also keeps a single-package update from running at the same time as a bulk run.
- **Results are also deployment results:** each result is sent as a normal `deployresult`, so deployments made with OpenUEM keep their status. The worker ignores packages it doesn't track.
- **The last run is kept on the agent:** it's stored in `last_update_run.json` in the agent's data directory. A run interrupted by a restart is reported as interrupted.
- **Queued requests:**
  - ignored if older than 30 days (the console doesn't queue a second request while one is waiting),
  - delivered again 10 minutes later if a run is in progress,
  - acknowledged when the run starts: a run interrupted by a restart is reported as interrupted and has to be requested again.
- **Inventory:** a report is sent after each run, so the console shows the new versions.

### Private winget repository (Windows)

The console hosts a winget REST source with the packages uploaded to its Software library (see the console PR). Computers only need outbound HTTPS to the console; nothing is pushed to them.

- **Registration:** only the source name `OpenUEM` is accepted (a request can't replace winget's own sources). On `agent.wingetsource.<uuid>`, the agent runs `winget source remove` and `winget source add --name OpenUEM --arg <url> --type Microsoft.Rest --trust-level trusted --accept-source-agreements --disable-interactivity`. If that fails, the matching lines of winget's own log are added to the error.
- **Trusted source:** winget checks installers of untrusted sources with `IAttachmentExecute`, which fails without an interactive session: as SYSTEM, every install from the repository ended with `0x8A150001` right after "Installer hash verified". The repository is the console's own, served over HTTPS, and winget still verifies each installer's SHA-256.
- **Certificate:** winget needs a certificate it trusts. With `TrustCA`, which the console sets when it has no reverse proxy with a public certificate, the agent first adds the OpenUEM CA to the machine's trusted root store with `%SystemRoot%\System32\certutil.exe -addstore -f Root`. Whoever has the CA key can then issue certificates these computers trust for any host; a reverse proxy with a public certificate avoids adding it.
- **No unnecessary runs:** a hash of the last registered source is kept in `winget_source.json` (local users can read the agent's folder, so not the URL with the agent's token). The console sends the registration every 30 minutes, and winget only runs when the name, URL or CA setting changed, the last registration failed, or the source was registered before it was trusted.
- **Other systems** reply and ignore the message.

## Bug fixes

- **Failed winget updates reported as successful.** winget now runs directly, without PowerShell, and its exit code is mapped with `wingetcfg.ErrorCodes`.
- **The `0x8A15002B` ("no applicable update") check never matched.** It compared a lower-cased code with an upper-cased one. It's now `deploy.ErrNoApplicableUpdate`, and an up-to-date package is reported as updated, as before.
- **Packages not installed machine-wide reported as failed.** When no scope is given, the agent now tries the logged-in users' sessions. If nobody has the package, it's reported as not installed instead of failed. This matters when a package is updated on many computers from the console.
- **Empty reason for failed PowerShell script tasks.** The logged reason was the output of the previous `Set-ExecutionPolicy` command, which is empty. It's now what the script wrote.
- **Package ids are validated** before they're passed to a package manager (winget, flatpak and Homebrew): not empty, no leading `-`, no whitespace or shell metacharacters.
- **winget installs and uninstalls ran through PowerShell** (`& winget install <id> | Select-String`): the exit code was PowerShell's, so failed installs were recorded as installed, and the package id and version were put into the PowerShell command line unvalidated. winget now runs directly with an argument list; "already installed, no newer version" (install) and "not installed" (uninstall) count as success, other failures are reported with winget's error.
- **Failed uninstalls were sent with `Failed=false`.**
- **winget.exe of an App Installer update that isn't complete.** `locateWinGet` took the last `DesktopAppInstaller` folder in name order. While App Installer updates itself, the new version's folder exists with an empty `winget.exe` (paused for SYSTEM), and every winget command failed with "%1 is not a valid Win32 application". It now takes the newest version, compared as numbers, whose `winget.exe` can run.

## Compatibility and upgrade notes

- **winget 1.4 or newer** is required (`--disable-interactivity`), and a version that knows `source add --trust-level` for the private repository (tested with winget 1.11).
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
- **winget source:** the `source add` arguments; registration is skipped when nothing changed, retried after a failure, and repeated once for sources registered before they were trusted.
- **Source requests:** only the name `OpenUEM` with an https URL is accepted.
- **Hardening:** local drive paths only for a user's `LOCALAPPDATA`; capped command output; install, uninstall and version argument lists and version validation.
- **Locating winget.exe:** newest version compared as numbers, empty or missing `winget.exe` and other architectures skipped.

### Builds
`GOOS=windows|linux|darwin go vet ./...` and `go test ./...` pass.

### Manual tests
Tested on a Windows 11 endpoint (build 26300, winget 1.11) with a Docker deployment:
- [x] available updates listed on the computer's Software updates page, machine-wide and per user
- [x] update all software run from the console, including a per-user app (Windows Terminal) updated in the user's session
- [x] the OpenUEM winget source is registered, and a library package is found, installed, updated and uninstalled with winget (MSI, Inno Setup, NSIS, setup .exe with switches)
- [x] the agent restarted during a run reports it as interrupted
- [x] an update requested while the computer was shut down runs when it starts
- [x] a package that isn't installed is reported as not installed, not as failed
- [x] a failing PowerShell task shows the script's error
- [x] winget keeps working while App Installer updates itself
- [x] a failing install (unknown package) is reported as failed with winget's reason; installing an installed package, uninstalling a removed one count as success
- [x] the state file holds a hash, no token
- [x] the official 0.11.0 agent keeps working with the console of this series after an existing installation is upgraded

End to end with the console, NATS and a Linux agent in containers:
- [x] the agent connects, is admitted and its subscriptions are accepted
- [x] Update all software on an online computer starts a run, and the status page shows it
- [x] an update requested while the computer was offline runs once when it connects

Linux was tested without flatpak installed (nothing to update). flatpak updates and macOS (Homebrew) are covered by unit tests only.

Known limitation: a per-user package whose update needs administrator rights (e.g. App Installer, whose Windows App Runtime dependency asks for elevation) fails in the user's session; the error says so.

## Merge order

1. open-uem/nats: message types
2. open-uem/openuem-cert-manager: NATS permissions
3. **This PR**, after replacing the temporary `replace` with the merged nats version
4. open-uem/openuem-console

## Checklist

- [x] Conventional commit title
- [x] Builds and vets on Windows, Linux and macOS
- [x] Unit tests added
- [x] Tested on a Windows endpoint

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01FVN6i1yNq2pA1uqE9wBGDr
