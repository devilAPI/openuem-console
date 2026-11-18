**Is your feature request related to a problem? Please describe.**

Keeping the software on many computers up to date is currently hard with OpenUEM:

- **One package at a time:** the existing update button only updates one package that OpenUEM deployed, on one computer at a time. There's no way to update a package on several computers at once, or to update everything installed on a computer.
- **No overview:** the console doesn't show which packages on a computer have a newer version available, whether OpenUEM installed them or not.
- **Packages installed for one user are invisible:** the agent runs as SYSTEM, so winget only sees machine-wide packages. Packages installed for a single user (Spotify, the VS Code user installer, many Microsoft Store apps, …) never get updated.
- **Failures look like success:** the agent pipes winget through PowerShell's `Select-String`, which hides winget's exit code. A failed update is reported as successful.
- **Offline computers are skipped:** update requests are only sent to computers that are online at that moment. Laptops that are switched off never get them.
- **MSI tasks need a download URL:** the package has to be hosted somewhere every computer can reach. Anyone who has the URL can download it.

**Describe the solution you'd like**

1. **Deploy > Update:** search a package and update it on the selected computers, like install and uninstall.
2. **Deploy > Update all software:** select computers (or all computers of an organization or site) and update every package with an available update, including packages installed for the logged-in users. Computers that are offline start the update when they connect again.
3. **Deploy > Update status:** one row per computer with the progress or the result of its last update run.
4. **Computer > Deploy > Software updates:** list the packages of a computer that have an available update, with the installed and the available version and whether they are installed for all users or for a user. Update the selected packages or all of them, follow the progress and see the result of the last run.
5. **Upload button in MSI tasks:** the package is stored by the console and can only be downloaded by the agents of the profile. PowerShell and shell script tasks can load the script from a file.

**Describe alternatives you've considered**

- **A PowerShell task running `winget upgrade --all`.**
  - It runs as SYSTEM, so it doesn't reach packages installed for users.
  - There's no per-package result.
  - It only runs when the profile is applied.
- **Running `winget upgrade --all` blindly on the agent.** That gives no overview, and there's no result per package to show in the console.
- **Storing update results in the database.** That needs schema changes (ent) and worker changes. The agent can keep the result of its last run itself and report it on request, and the worker already updates the deployments OpenUEM tracks.
- **A separate file server for MSI packages.** It still exposes the packages to anyone who has the URL.

**Additional context**

I have a working implementation, split into pull requests for the repositories involved:
- nats: message types
- openuem-agent
- openuem-console
- openuem-cert-manager: NATS permissions

It has been tested on Windows endpoints with a Docker deployment. Linux (flatpak) and macOS (Homebrew) support is included, but has only been unit tested.
