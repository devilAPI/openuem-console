# OpenUEM-Fork (devilAPI)

Fork von [OpenUEM](https://github.com/open-uem) mit Massen-Software-Updates, einem
privaten Winget-Repository und Installations-Skripten für Server und Agenten.
Deutschsprachige Kurzdoku — Details siehe `handoff/HANDOFF.md` (Englisch).

## Was der Fork zusätzlich kann

- **Massen-Updates:** verfügbare Updates eines Rechners auflisten (winget, Flatpak,
  Homebrew) und einzelne oder alle Pakete auf einem oder vielen Rechnern aktualisieren —
  auch bei offline Rechnern (queued über JetStream). Statusseite: Deploy → Update status.
- **Private Winget-Bibliothek** (Deploy → Software library): MSI, EXE (Inno, NSIS, WiX,
  beliebig mit Silent-Switches) und MSIX hochladen; die Konsole stellt sie als
  WinGet-REST-Quelle unter `https://<console>:1323/winget/<agent-id>/<token>/` bereit.
  Windows-Agenten registrieren die Quelle automatisch als `OpenUEM`.
- **Installations-Skripte** (dieser Branch): Server, Windows-Agent, Linux-Agent.

## Server installieren (Debian 13, root, Docker)

```bash
curl -fsSL https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-fork.sh | bash
```

Erneutes Ausführen aktualisiert die Installation (`.env`, Zertifikate und Datenbank
bleiben erhalten). Einstellungen über Umgebungsvariablen, z. B. `OPENUEM_DOMAIN=uem.example.com`,
`SERVER_IP=192.0.2.10`. Der Server baut dabei auch die Agenten-Installer unter
`agent-builds/latest/`.

## Agenten installieren

**Windows (PowerShell als Admin):**

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1))) -ServerIP 192.0.2.10 -Domain uem.example.com
```

Installiert genau wie die offiziellen Docs: offizieller `openuem-agent-setup.exe` mit
`/server=<nats>:<port> /sftp=<port> /vnc=<port> /VERYSILENT` (Zertifikate liegen neben
dem Installer bzw. `/cacert= /cert= /key= /sftpcert=`, optional `/tenantid= /siteid=`),
danach Binary-Tausch gegen das Fork-Build (`.official` bleibt). Erneutes Ausführen ohne
Parameter aktualisiert (Einstellungen der letzten Runde werden übernommen).

**Windows-Rollout ohne SSH** (silent, als SYSTEM, z. B. GPO-Startskript/Intune/PDQ):
`agent-builds/latest/windows-amd64/openuem-agent-fork-setup.exe` vom Server kopieren.
Der Setup ist genau wie der offizielle `openuem-agent-setup.exe` mit **Inno Setup**
gebaut (gleiche Packager-Signatur, wird vom EXE-Detektor der Konsole als Inno erkannt)
und immer silent (auch ohne `/S`; er startet sich ggf. selbst mit `/VERYSILENT
/SUPPRESSMSGBOXES` neu). Intern führt er den offiziellen Installer mit den offiziellen
Flags aus (`/server=<nats>:<port> /sftp=<port> /vnc=<port> /VERYSILENT`, Zertifikate
liegen neben dem Installer bzw. werden über `/cacert= /cert= /key= /sftpcert=`
übergeben, optional `/tenantid= /siteid=`) und tauscht danach das installierte
Agent-Binary gegen das Fork-Build (das offizielle bleibt als `<binary>.official`).
Aufruf: `setup.exe /ORG=<id> /SITE=<id> /DOMAIN=... /SERVERIP=... /OVERWRITE`
(IDs siehe Adresszeile der Konsole `/tenant/<org>/site/<site>/`, `/OVERWRITE` schreibt
die installierte Agent-config um), Exit-Code 0/1, Log in
`%ProgramData%\OpenUEM-fork\install-agent.log`.

**Linux** (jede systemd-Distribution, als root) — Installer vom Server holen und:

```bash
sudo bash openuem-agent-fork-install.sh [--org <id> --site <id>] [--domain uem.example.com] [--nats-port 4433] [--server-ip 192.0.2.10]
```

Folgt der offiziellen Linux-Installation: installiert das offizielle Paket
(gebündeltes `.deb` per debconf-Preseed + `apt install`, sonst `apt install openuem-agent`
aus dem OpenUEM-Repository, auf dnf-Systemen `dnf install openuem-agent` aus dem
RPM-Repository, auf Distributionen ohne apt/dnf wie Arch wird das gebündelte offizielle
`.deb` entpackt — offizielles Layout und systemd-Units), konfiguriert es über debconf
bzw. `/etc/openuem-agent/openuem.ini` (`[NATS] NATSServers=`, `SFTPPort`,
`VNCProxyPort`, `TenantID`, `SiteID`), legt die Zertifikate nach
`/etc/openuem-agent/certificates/` und startet `openuem-agent` neu. Fork-spezifisch:
der offizielle Updater (`openuem-agent-updater`) wird deaktiviert (bei apt zusätzlich
`apt-mark hold`), damit das Fork-Binary nicht wieder ersetzt wird, und
`/opt/openuem-agent/bin/openuem-agent` wird gegen das Fork-Build getauscht
(offizielles bleibt als `.official`). Eine bestehende Installation (UUID, Org/Site,
Konsole-Änderungen) bleibt erhalten; erneutes Ausführen aktualisiert den Agenten.

## Ports

| Port | Dienst |
|---|---|
| 1323 | Konsole (HTTPS, auch Winget-REST-Quelle) |
| 1324 | Auth-Server (Zertifikats-Login) |
| 4433 | NATS |
| 8000 | OCSP-Responder |
| 2022 / 1443 | SFTP / VNC-Proxy des Agenten |

DNS: `console.<domain>`, `nats.<domain>`, `ocsp.<domain>` müssen auf den Server zeigen
(bei Split-Brain-DNS die internen Records nachtragen).

## Doku und Upstream-PRs

- `handoff/HANDOFF.md` — kompletter Entwicklungsstand, Tests, bekannte Einschränkungen
- `handoff/TEST_PLAN.md` — Windows-Testplan mit Ergebnissen
- Upstream: Agent-PR open-uem/openuem-agent#216, Konsole open-uem/openuem-console#499 (Issue #498),
  nats #24, cert-manager #17, Worker-PR siehe `handoff/pr/worker.md`
