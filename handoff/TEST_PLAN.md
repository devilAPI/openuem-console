# Test plan: software updates + private winget repository

What had to be tested on a real Windows computer, with the results of the run on
2026-11-18. Everything was tested end to end, unattended, on local VMs (see "Test lab"
below): a Debian 13 server installed with `install-openuem-fork.sh` and a Windows 11 Pro
client (build 26300, winget 1.11) installed with `install-openuem-agent-fork.ps1`, plus a
Linux agent on the server as a second computer. The console was driven with Playwright.

Bugs found on the way were fixed, pushed, and tested again on the VMs (see HANDOFF.md,
"Fixed after testing on Windows"). All boxes below were ticked with the fixed builds.

## 0. Setup

- [x] Server summary prints without errors, console reachable
- [x] Computer shows "Agent is online"
- [x] OpenUEM CA is trusted on the VM
- [x] Ports 1323 (console) and 8000 (OCSP) reachable from the VM
- [x] Server update (running the script again) keeps settings, certificates and data, and
      builds the agents worker from the fork
- [x] Windows agent script without parameters reuses the last settings; `.official` keeps
      the official binary across updates

Useful on the VM:
- Agent log: `C:\Program Files\OpenUEM Agent\logs\openuem-log.txt`
- Source state: `C:\Program Files\OpenUEM Agent\winget_source.json`. It's only written
  after a **successful** registration, and now records `"trusted": true`.
- winget's logs as SYSTEM: `C:\Windows\Temp\WinGet\defaultState\WinGet-*.log`

## 1. Private winget repository

### Registration
- [x] Agent log: `the winget source OpenUEM of the console has been registered` (on admission)
- [x] `winget_source.json` exists and its `url` starts with `https://console.<domain>:1323/winget/`
- [x] Clicking Register again: "registered on 1 of 1 computers", no second "registered"
      line (winget isn't run)
- [x] An agent that registered the source before it was trusted registers it again once

### MSI: upload, install, update, uninstall (7-Zip 24.08 / 24.09)
- [x] Name, publisher, version 24.08 and identifier filled in from the MSI; Type "MSI".
      The identifier is `IgorPavlov.7ZipX64Edition` (without the version)
- [x] 7-Zip 24.08 gets installed from Deploy > Install (row with the OpenUEM badge)
- [x] The computer's Deploy tab shows the deployment as installed
- [x] After uploading 24.09: Software updates lists 7-Zip, installed 24.08, available
      24.09, source OpenUEM, all users
- [x] Updating it: 7-Zip is 24.09 afterwards
- [x] Update status shows the result for the VM
- [x] Deploy > Uninstall removes it

### EXE and MSIX
- [x] Inno Setup (Inno Setup 7.1.1) and NSIS (Notepad++ 8.7) detected with "Detect";
      name, publisher and version filled in
- [x] Deploy > Install of each one installs it silently on the VM
- [x] Uninstall works
- [x] A setup .exe without switches (7-Zip's own `7z2409-x64.exe`) is refused with the
      message asking for silent switches; with `/S` it's accepted and installs
- [ ] Optional **.msix**: not tested on Windows. No small unbundled .msix was at hand
      (PowerShell's releases only ship bundles now) and a self-built one would need a
      trusted signing certificate. Parsing and manifests are covered by unit tests.

### Organization isolation
- [x] A package uploaded in a second organization isn't installable on the VM: the
      repository answers 204 (search, manifest) and 404 (installer)
- [x] It isn't offered in the first organization's Deploy > Install search nor in its
      profiles' task search (it was before the fix)

### Delete
- [x] Deleted versions are gone from the list and from Deploy > Install search

## 2. Profiles with library packages (worker fork)

- [x] The task search shows library packages with "· OpenUEM" after the identifier, for
      the profile's organization only
- [x] The profile (run with the computer's "Execute profile" button) installs the
      library package (Notepad++ from source OpenUEM)
- [x] A task with a community package (`voidtools.Everything`) still installs from winget

## 3. Software updates

- [x] **Per-user app:** Windows Terminal and App Installer are listed as "User" with the
      user name; Windows Terminal was updated in the user's session. App Installer fails
      there because its dependency needs elevation (winget limitation, clear error).
- [x] **Machine-wide program matched differently by the user's sources** (7-Zip MSI from
      the library) is only listed once, machine-wide (it was listed as a user package
      before the fix)
- [x] **Interrupted run:** restarting the "OpenUEM Agent" service during the run →
      Update status "Failed: the update run was interrupted"
- [x] **Offline computer on Windows:** VM shut down, Update all software → "Offline, the
      update will start when it connects"; after booting, the run started by itself and
      updated PuTTY (Update status "1 updated, 0 failed, 1 already up to date")
- [x] **Update tab** (Deploy > Update): PuTTY updated; Firefox (not installed) is
      reported as not installed, not as failed. The Update tab only offers computers
      of the package manager's OS, so the "second computer" case was tested with a
      package the VM doesn't have.
- [x] Linux computer without flatpak: Update all → "Nothing to update"

## 4. Tasks

- [x] **Failing PowerShell task:** `Write-Error "boom"; exit 1` (loaded with "Load the
      script from a file") shows "boom" in the profile's report

## 5. Regression checks

- [x] Normal winget install/uninstall from the community source (WinMerge)
- [x] Login with the admin certificate directly on the auth port (302 to the dashboard);
      no certificate and a forged `Client-Cert` header are refused
- [ ] Login behind a reverse proxy: not tested (no reverse proxy in the lab)
- [x] Pages with an organization/site selected (`/tenant/<id>/...` and
      `/tenant/<id>/site/<id>/...`) work for Install, Update, Update all, Update status
      and Software library

## Test lab

Local QEMU VMs without root (user-mode networking for internet, a QEMU multicast socket
as the LAN between the VMs):
- **Server:** Debian 13 genericcloud image with a cloud-init seed, 4 GB RAM.
- **Windows:** unattended install from the Windows 11 ISO with an `autounattend.xml` on a
  second CD (TPM/Secure Boot checks bypassed with `LabConfig`, local admin, OpenSSH
  server and a static LAN address set up at first logon), 6 GB RAM, SATA disk and
  e1000e NICs (no extra drivers). Start it with `-rtc base=localtime`, or the clock is an
  hour off after a reboot.
- Commands as SYSTEM on Windows run through a scheduled task.
- The console was driven with Playwright (Chromium, `--host-resolver-rules` for the
  domain). Playwright's client certificates don't work with that mapping, so the
  certificate login was tested with curl.
