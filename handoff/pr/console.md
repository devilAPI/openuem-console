Related to open-uem/openuem-console#ISSUE (feature request: bulk software updates).

## Summary

New pages and actions to keep the software of many computers up to date:

| Where | What |
|---|---|
| Deploy > **Update** | Search a package and update it on the selected computers |
| Deploy > **Update all software** | Update every package with an available update on the selected computers, including packages installed for the logged-in users. Offline computers start when they connect again. |
| Deploy > **Update status** | One row per computer with the progress or the result of its last update run |
| Computer > Deploy > **Software updates** | A computer's available updates, update some or all, follow the progress, results of the last run |
| Deploy > **Software library** | Upload MSI, EXE and MSIX installers to OpenUEM's own winget repository. Windows computers register it automatically and install, update and uninstall the packages with winget, over outbound HTTPS only. |
| Profiles > winget task | Library packages can be picked like community packages, and are installed from the repository |
| Profiles > task > **Load the script from a file** | Fill a PowerShell or shell script from a local file |

It also fixes the Dockerfile, the Homebrew type check, and the auth server trusting the `Client-Cert` header without a reverse proxy.

Requires the related agent, nats and openuem-cert-manager PRs.

## Deploy section

### Update
The same flow as install and uninstall, for update:
- search a package, select the computers, request,
- `agent.updatepackage` is sent to each computer, and deployments OpenUEM tracks are marked as pending.

The deploy views now take the action (`install`, `update`, `uninstall`, `updateall`) instead of an `install bool`, and a single navbar loops over the tabs. The former `filterByInstallationType=true|false` form values are still accepted, so bookmarked URLs keep working.

### Update all software
- **Selecting computers:** the existing agent selection (paging, filters, select all) without a package. The selection is scoped to the current organization and site.
- **Queuing:** a request is published to AGENTS_STREAM (`agent.update.packages.<uuid>`) for each selected computer that belongs to the current organization and site. Online computers start right away. Offline computers start when they connect, through their durable consumer.
- **Result page:** it lists:
  - the computers that started,
  - the offline computers that will start later,
  - the computers whose request couldn't be sent or queued.

  An offline computer whose agent doesn't support queued requests gets nothing from the stream, because interest-based retention drops messages no consumer wants. This is detected by looking the message up after publishing, and reported as such.

### Update status
- **Rows:** one per computer of the current organization or site, paged and sorted by name.
- **Status:** running (x of y), finished (updated / failed / already up to date), failed with the error, offline, offline with an update queued, or the agent doesn't support software updates.
- **Sources:**
  - agents are asked with `{"statusonly": true}`, so the package manager doesn't run,
  - queued requests are read from AGENTS_STREAM,
  - offline agents answer "no responders" right away.
- **Refresh:** the page uses the console's usual refresh button and interval. Each computer links to its Software updates page.

## Computer page: Software updates

A **Software updates** button on the Deploy tab opens the page. It's a separate page because the Deploy tab refreshes itself periodically, which would throw away a list that takes the agent up to a few minutes to build. The page:
- lists the available updates with name, id, installed and available version, source, and whether the package is installed for all users or for a user (user names in a tooltip),
- updates the selected packages or all of them through `agent.updatepackages`,
- polls the progress every 15 seconds while the agent works,
- shows the result of the last run with winget's message for failed packages.

Requests only reach agents of the current organization and site. A timeout is reported separately from "not reachable".

## Scripts

PowerShell and shell script tasks get a "Load the script from a file" input. The browser reads the file into the script field, and the script is stored with the task and sent only to the profile's agents, as before.

## Private winget repository

Instead of copying packages to computers, the console hosts its own winget REST source. Computers register it automatically and download packages from the console over HTTPS, so they only need outbound access to the console, which also works for consoles on a VPS.

### Software library (Deploy > Software library)
- **Upload:** an installer, and the form can stay empty: any field can be overridden. The package identifier defaults to `Publisher.Name` in winget's style, without the version that product names often contain ("7-Zip 24.08 (x64 edition)" becomes `IgorPavlov.7ZipX64Edition`), so every version of a program is the same package and the newer one is offered as its update. E-mail and web addresses in an EXE's publisher are left out.
  - **MSI:** name, publisher, version and product code come from the Property table (`internal/wingetrepo/msi.go` reads the compound file).
  - **EXE:** name, publisher and version come from the version resource (`exe.go`). Inno Setup and NSIS installers are recognized by the signatures they carry, WiX Burn bundles by their `.wixburn` section; winget knows the silent switches of all three. Other setup programs must be given their silent switches, otherwise winget would start them without arguments and wait for a click. The manifest lists the program's Apps & features entry, so winget finds the installed version.
  - **MSIX:** name, publisher, version and architecture come from `AppxManifest.xml` (`msix.go`). The package family name, by which winget recognizes the installed package, is computed from the publisher. Bundles aren't supported.
  - All packages are installed with machine scope, as the agent runs winget as SYSTEM with `--scope machine`.
- **Availability:** the current organization or all organizations. An identifier belongs to one of them: an upload for an identifier another organization (or "all organizations") uses is refused, so an upload can't replace or shadow another organization's package. Identifiers of other sources (e.g. `Mozilla.Firefox` of winget's community repository) are refused too, as the identifier decides which source a task installs from.
- **Robust parsing:** the MSI header is checked against the file size before the compound file reader allocates its tables (a crafted 3.5 KB file made it allocate gigabytes and the process die). The EXE, MSI and MSIX readers were fuzzed without findings otherwise; the MSIX manifest is limited to 1 MiB.
- **List and delete:** packages and their versions.
- **Register now:** sends the registration to this organization's computers right away.
- **Storage:** `winget-repository` in the working directory (`--winget-repository-dir`, `WINGET_REPOSITORY_DIR`; with Docker, `/bin/winget-repository` needs a volume). Each version is a directory with `package.json` and the installer. Uploads are staged in a temporary file first and moved into place, so an interrupted upload never shows up as a package; a replaced version is prepared next to the old one and swapped in, and leftovers of a crash are removed at startup.

### REST source (console web server, `/winget/<agent id>/<token>/...`)
- **Why the console port and not the auth server:** the auth server asks every client for a certificate (`tls.RequestClientCert`, for the certificate login). winget uses WinHTTP through cpprestsdk, and WinHTTP fails a request with `ERROR_WINHTTP_CLIENT_AUTH_CERT_NEEDED` when the server asks for a certificate and the client doesn't answer; neither winget nor cpprestsdk does. `winget source add` then fails with `0x8A150045`. The web server uses the same certificate without asking, so the source is served there: `https://<server>:<console port>/winget/...`, or `https://<reverse proxy server>/winget/...` behind a reverse proxy. The handlers live with the auth server's (`RegisterWinGetSource`) and are registered on the web server's router before it starts.
- **Endpoints:** `GET information`, `POST manifestSearch` (query, inclusions and filters with the exact, case-insensitive, starts-with and substring match types; 204 when nothing matches), `GET packageManifests/{id}`, and `GET installers/{id}/{version}/{file}`.
- **Search results list every version** of a matching package. winget finds an installed program by the product code of the installed version and offers the newest version of the response as its update, so a response with only the matching version would never offer an update.
- **API versions:** 1.0.0 and 1.1.0. The responses were validated against Microsoft's OpenAPI documents from winget-cli-restsource.
- **Manifests:** an MSI installer with its SHA-256, product code, `AppsAndFeaturesEntries` (so winget matches the installed program and offers updates), silent install modes and machine scope. The installer URL is built from the request's host, so it works behind a reverse proxy.
- **Authentication:** winget can't present client certificates, so each agent gets its own source URL with an HMAC-SHA256 token of its id, keyed with the console's JWT key. Requests are only answered for **enabled** agents, and only with the packages of the agent's organizations plus the global ones. A package of another organization is "not found".
- **Errors** are answered as JSON with their status code. The console's error handler renders HTML pages with status 200, which winget can't read.
- **No CSRF** on these routes (the router skips `/winget/`), as they're called by winget, not by browsers.

### Registration on computers
- `agent.wingetsource.<agent id>` with the name `OpenUEM`, the agent's URL and `TrustCA` when no reverse proxy is configured (the agent then trusts the OpenUEM CA, which signs the console's certificate).
- Sent when an agent is admitted, every 30 minutes to all enabled Windows agents, and with the Register button. The agent only runs winget when something changed.

### Profiles
A profile's winget install task can now pick library packages: the task form's search shows them with "· OpenUEM", and the task installs them from the source `OpenUEM`. The search sends the profile, so it offers the packages of the profile's organization, and for a global profile (or one of several organizations) only the packages available to all organizations. The profiles sent to the agents are generated by the agents worker, which needs the same change (related openuem-worker PR).

This replaces the MSI upload for profile tasks that an earlier version of this PR had: library packages are versioned, updated by the software updates and served without client certificates.

### Integration with Deploy
Library packages are added to the software catalog with the source `openuem` (synced with the library every 30 minutes and on every change). They appear in Deploy > Install search, are installed through the existing winget deployment, and are updated by the software updates like any other winget package. The catalog is shared by all organizations, so the searches leave out the packages of other organizations (unless all organizations are selected).

## Fixes

- **Dockerfile:**
  - the source was copied to `/go`, which is `$GOPATH`, so Go printed `ignoring go.mod in $GOPATH` and built without the module,
  - `golang:1.26.1` sets `GOTOOLCHAIN=local`, while `go.mod` requires 1.26.2.

  The build stage now uses `WORKDIR /src` and `golang:1.26`. The runtime stage is unchanged and matches the published image.
- **Homebrew types:** they were checked with `slices.Contains([]string{"cask,formula"}, t)`, a single string, so every brew type was rejected.
- **`Client-Cert` header:** the auth server accepted a client certificate from this header on any connection that had no TLS client certificate. The header doesn't prove possession of the private key, so anyone who knows a certificate could send it. It's now only used when a reverse proxy is configured (`REVERSE_PROXY_AUTH_PORT`). This also applies to the certificate login; deployments behind NGINX or Caddy keep working.
- **Duplicate deployments:** every install request created a deployment unless the previous one had failed, so installing a package again left two; the agent's next result then failed with `deployment not singular` and both stayed "In Progress". Install requests now reuse the deployment, merge existing duplicates and are saved one at a time.
- **Package pickers of the task form** put the package id and name into hyperscript strings; a quote in a name broke the picker and a crafted name could run its own hyperscript. The values are now data attributes.
- **Test data:** `*.exe` is in `.gitignore`, so the small test executables of `internal/wingetrepo/testdata` are added with `git add -f` (built as described in its README).

## Required NATS permissions (openuem-cert-manager PR)

| User | Permission | Needed for |
|---|---|---|
| `CN=OpenUEM Agent` | subscribe `agent.listpackageupdates.> openuem-agent-management`, `agent.updatepackages.> openuem-agent-management` | Software updates page, update all, update status |
| `CN=OpenUEM Agent` | subscribe `agent.wingetsource.> openuem-agent-management` | Registering the winget repository |
| `CN=OpenUEM Console` | publish `$JS.API.STREAM.MSG.GET.AGENTS_STREAM` | Optional: showing queued updates |

Separately, `nats.cfg` files generated by the currently published openuem-cert-manager image lack the console's leader election permissions (`$JS.API.INFO`, `$KV.leaders.openuem`, …), which are already in the script on `main`. With such a file, the election fails with `Publish Violation "$JS.API.INFO"`, and the package search stays empty. This isn't caused by this PR, but upgraded deployments need a regenerated `nats.cfg`.

## Translations

All new texts are translated into en, de, es, fr, ca, pt and no. The new templates only use classes that exist in the precompiled `main.css`.

## Tests

### Unit tests
- **Parsing deploy actions.**
- **`wingetrepo`:** EXE version resources and installer detection on a minimal real executable built with LLVM (`testdata/README.md`), MSIX manifests and package family names (Microsoft's own publisher id as reference), per-type validation and manifests, MSI properties (including long strings and non-ASCII names), stream name decoding, package validation, library add/list/versions/remove with tenant visibility, version comparison, search by query, inclusions and filters (exact, substring, product code, normalized name and publisher, unsupported fields), manifests, tokens.
- **`/winget` handler (end to end over HTTP):** information, wrong token, another agent's token, agent waiting for admission, search limited to the agent's organization, 204 when nothing matches, manifest with the agent's installer URL, installers of another organization, wrong file names, JSON errors.
- **Package identifiers** built from publisher and name: accented letters, versions in product names (and numbers that aren't the version), contact details in publishers.
- **Search** of an installed older version by its product code returns all versions.
- **Library ownership:** another organization's upload of an identifier is refused (also with other case), versions are replaced safely, crash leftovers removed; corrupt MSI headers are refused without allocating (run under a memory limit).
- **Deployments:** an install request reuses the deployment and merges duplicates; concurrent requests.
- **Installer URLs** use the registered base URL, not the request's Host (as behind nginx).
- **Organizations:** library packages hidden from other organizations in Deploy search, its count and the task search (model tests on SQLite), and for global profiles.

### Build and test status
- `go build ./...`, `go vet ./...` and the new tests pass.
- `internal/models` has two suites (`TestUserTestSuite`, `TestSMTPTestSuite`) that fail on `main` too.
- The new views were rendered in en and de with the real translations, checking for missing keys and format errors.

### End-to-end test
The full stack (this console, the published workers, NATS, PostgreSQL) ran in Docker with a Linux agent from the agent PR in a container, driven in a browser with Playwright:
- [x] agent admitted, no NATS permission violations
- [x] Computer > Software updates reaches the agent
- [x] Update all software: an online computer starts, an offline one is listed as queued, and its request runs once when it reconnects; Update status shows each state
- [x] Software library: MSI uploaded with an empty form, properties read from the MSI, package listed and found in Deploy > Install search
- [x] winget REST source over HTTPS with the OpenUEM CA: 401 for a wrong token, 403 before admission, search, manifest, installer download matching its SHA-256; responses valid against Microsoft's 1.0.0 and 1.1.0 OpenAPI documents

### Manual tests
Tested with the Docker deployment (installed with the fork's install script on Debian 13) and a Windows 11 endpoint (build 26300, winget 1.11), plus a Linux agent as a second computer:
- [x] Software updates page lists the computer's updates, machine-wide and per user, with their source
- [x] Update all software on an online computer; on an offline computer it's queued and runs when the computer starts
- [x] Update status: running, finished with counts, interrupted, offline with an update queued, nothing to update
- [x] Update tab: an installed package is updated, a computer without the package isn't reported as failed
- [x] the Windows computer registers the OpenUEM winget source on admission and with the Register button, and doesn't run winget again when nothing changed
- [x] MSI (7-Zip 24.08) uploaded with an empty form, installed from Deploy > Install, 24.09 uploaded and offered as its update, updated, uninstalled
- [x] Inno Setup and NSIS installers detected, installed silently and uninstalled; a setup .exe without switches is refused, with `/S` it's accepted and installs
- [x] a package of another organization isn't offered (Deploy search, task search) and the repository answers 204/404 for it
- [x] library packages deleted are gone from the list and the search
- [x] a profile installs a library package and a community package
- [x] a failing PowerShell task shows the script's error in the profile's report
- [x] login with the admin certificate directly; the `Client-Cert` header is refused without a reverse proxy
- [x] organization and site URLs (`/tenant/:tenant/...`, `/tenant/:tenant/site/:site/...`) of all deploy pages
- [x] Docker image builds with the fixed Dockerfile
- [x] uploads of another organization's identifier and of a community identifier are refused with a message
- [x] Update all software clicked twice for an offline computer queues one request (checked in AGENTS_STREAM)
- [x] installing a package again merges the duplicate deployments left by earlier versions, and the agent's result is saved
- [x] an existing installation of the published images (with an admitted official 0.11.0 agent, a profile, a task and a deployment) upgraded to this console: no row lost, the official agent keeps working, the profile is shown; going back to the published images works on the migrated database

Not tested: login behind a reverse proxy, an MSIX package on Windows (its parsing and manifests are covered by unit tests).

## Security notes

A separate security review of this PR's code was done before deploying it; its findings are fixed (see the commits above) except these, which are documented limitations:
- **Repository tokens don't expire.** An agent's source URL is `HMAC(console JWT key, agent id)`: it stays valid while the agent is enabled. Disabling or deleting the agent revokes it; rotating the JWT key revokes all. It gives read access to the installers the agent's organizations can install. The agent doesn't store it in a file local users can read.
- **The OpenUEM CA is added to the computers' trusted roots** when the console has no reverse proxy, because winget only accepts sources with a trusted certificate. Whoever has the CA key can then issue certificates the computers trust for any host. A reverse proxy with a public certificate avoids it.
- **Listing a computer's updates** keeps the HTTP request open while the agent works (up to a few minutes); behind a reverse proxy, its read timeout must allow it.
- Console users aren't limited to organizations (upstream design): the organization scoping decides which computers can install a package, not which console users can manage it.

## Notes

- winget checks the revocation of the console's certificate. Without a reverse proxy, the certificate's OCSP address (`http://ocsp.<domain>:<OCSP port>`) must be reachable from the computers. The OpenUEM OCSP responder answers both POST and GET requests (Windows uses GET).
- winget packages aren't signed by OpenUEM: winget checks the installer's SHA-256 from the manifest, and the manifest is served over HTTPS by the console the computer already trusts. Authenticode signatures of the MSI itself are checked by Windows as usual.
- `go.mod` temporarily replaces `github.com/open-uem/nats` with the fork that contains the new types. Once the nats PR is merged, the replace is replaced by a bump to the merged version.

## Merge order

1. open-uem/nats
2. open-uem/openuem-cert-manager
3. open-uem/openuem-agent
4. **This PR**

## Checklist

- [x] Conventional commit title
- [x] Builds, vets, unit tests added
- [x] Translations for all languages
- [x] Backwards compatible URLs and form values
- [x] Manual tests above completed (except login behind a reverse proxy and MSIX on Windows, see above)

🤖 Generated with [Claude Code](https://claude.com/claude-code)

https://claude.ai/code/session_01FVN6i1yNq2pA1uqE9wBGDr
