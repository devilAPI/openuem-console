# Test plan: software updates + private winget repository

What still needs a real Windows computer. Everything under "Already verified" was tested
end to end in containers and doesn't need repeating.

Tick the boxes as you go. The PR descriptions have the same open items, so whatever you
tick here can be ticked there too.

## 0. Setup (done)

- [x] Server summary prints without errors, console reachable
- [x] Computer shows "Agent is online"
- [x] OpenUEM CA is trusted on the VM
- [x] Ports 1323 (console) and 8000 (OCSP) reachable from the VM

Useful on the VM:
- Agent log: `C:\Program Files\OpenUEM Agent\logs\openuem-log.txt`
- Source state: `C:\Program Files\OpenUEM Agent\winget_source.json`. It's only written
  after a **successful** registration, so it's missing while registration fails.

## Update first

**Before that, once:** fork https://github.com/open-uem/openuem-worker to `devilAPI` (like the
other repositories) and tell me, so I can push its branch. Without the fork, the server
script keeps the official agents worker and prints a warning; everything except the profile
test in step 2 works anyway.

1. Server, as root (also builds the agents worker from the fork once it exists):

   ```bash
   curl -fsSL https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-fork.sh | bash
   ```

2. Windows VM, PowerShell as administrator. No parameters needed, the last settings are
   reused. The new agent writes winget's own error lines to its log when registration fails.

   ```powershell
   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1)))
   ```

- [ ] Server update finished; it printed whether the agents worker was built from the fork
- [ ] VM: "OpenUEM agent service: Running"

## 1. Private winget repository (most important)

### Registration
Your last log only had attempts from **before** the server update (15:08 and 15:28; the
update restarted NATS at 15:33), so the fix (repository on port 1323) hasn't been tried yet.

1. Deploy → Software library → **Register on this organization's computers now**.
- [ ] Agent log: `the winget source OpenUEM of the console has been registered`
- [ ] `winget_source.json` exists and its `url` starts with `https://console.<domain>:1323/winget/`
- [ ] Clicking Register again: no second "registered" line (nothing changed, winget isn't run)

If it fails, the error line in the agent log now continues with `winget's log (...)` and the
lines that explain it (an HRESULT like `80072F8F` or `80072F0C`). Send me that part.

Note: the agent registers the source for SYSTEM, which runs the deployments. winget keeps
sources per user, so `winget source list` in your own PowerShell may not show it. That's
expected.

### MSI: upload, install, update, uninstall
Get two versions of one MSI, e.g. 7-Zip from 7-zip.org: `7z2408-x64.msi` (24.08) and
`7z2409-x64.msi` (24.09). Uninstall 7-Zip from the VM first if it's there.

2. Software library: choose `7z2408-x64.msi`, leave every field empty, Upload.
- [ ] Name, publisher, version 24.08 and identifier filled in from the MSI; Type "MSI"
3. Deploy → Install, search `7-Zip`, pick the row with the **OpenUEM** badge, select the VM.
- [ ] 7-Zip 24.08 gets installed (Apps & features)
- [ ] The computer's Deploy tab shows the deployment as installed
4. Software library: upload `7z2409-x64.msi`. Then Computer → Deploy → **Software updates** →
   Check for updates.
- [ ] 7-Zip listed, installed 24.08, available 24.09
- [ ] Update it (or Update all software): 7-Zip is 24.09 afterwards
- [ ] Update status shows "1 updated" for the VM
5. Deploy → Uninstall, search 7-Zip, select the VM.
- [ ] 7-Zip removed

### EXE and MSIX (new)
6. Upload an **Inno Setup** installer (e.g. WinSCP or Git for Windows) and an **NSIS**
   installer (e.g. Notepad++ or VLC). Leave the type on "Detect".
- [ ] Type shows "Inno Setup" / "NSIS (Nullsoft)"; name, publisher and version filled in
- [ ] Deploy → Install of each one installs it silently on the VM
- [ ] Uninstall works
7. Upload some other setup .exe without switches.
- [ ] Refused with the message asking for silent switches; with the right switches
      (e.g. `/S` or `/quiet`) it's accepted and installs
8. Optional: an **.msix** package (not .msixbundle).
- [ ] Name, publisher, version and architecture read from it; Deploy → Install installs it

### Organization isolation (needs a second organization)
9. Create a second organization, switch to it, upload any installer as "This organization".
- [ ] It isn't installable on the VM (the VM's organization doesn't see it)

### Delete
10. Software library: delete the uploaded versions.
- [ ] Gone from the list and from Deploy → Install search

## 2. Profiles with library packages (new, needs the worker fork)

This replaces the MSI upload in tasks, which will be removed once this works.

11. Profiles → a profile that applies to the VM → new task of the winget package install type →
    search the name of a library package.
- [ ] The search shows it with "· OpenUEM" after its identifier
- [ ] Save; on the VM's next profile run (every 30 minutes), the package is installed
- [ ] A task with a normal community package (e.g. `7zip.7zip`) still installs from winget

## 3. Software updates (still open from the first round)

- [ ] **Per-user app:** install something just for your user (e.g. Spotify or the VS Code *user*
      installer, an older version). While you're logged in, Software updates lists it with
      your user name, and updating it works.
- [ ] **Interrupted run:** start Update all software with several updates, restart the
      "OpenUEM Agent" service during the run. Update status then shows "Failed: the update run was interrupted".
- [ ] **Offline computer on Windows:** shut the VM down, Update all software → listed as
      offline/queued. Start the VM → the run starts by itself, Update status shows the result.
- [ ] **Update tab** (Deploy → Update): update one package on the VM. If you have a second
      computer without that package, it must not be reported as failed.

## 4. Tasks

- [ ] **Failing PowerShell task:** a script with `Write-Error "boom"; exit 1` shows "boom"
      in the task's error.

## 5. Regression checks

- [ ] Normal winget install/uninstall from the community source still works
- [ ] Login with the admin certificate (directly on port 1323; behind a reverse proxy if you use one)
- [ ] Pages with an organization/site selected (URLs with `/tenant/<id>/site/<id>/...`)
      work for Deploy, Update status and Software library

## Already verified (containers, Linux agent, browser automation)

- Agent admission, NATS permissions, no violations
- Software updates page reaches the agent
- Update all: online start, offline queued, queued run executed once after reconnect,
  Update status for each state, "Nothing to update"
- Software library: MSI, Inno EXE, generic EXE (refused without switches, accepted with
  them) and MSIX uploads with an empty form, metadata read from the files
- winget REST source over HTTPS on port 1323, which doesn't ask for a client certificate
  (1324 does): wrong token 401, not admitted 403, search, manifest, installer download
  with matching SHA-256; MSI, EXE, Inno and MSIX manifests valid against Microsoft's API
  spec
- Agents worker: a profile with a library package and a community package is sent with
  `source: OpenUEM` and `source: winget`
