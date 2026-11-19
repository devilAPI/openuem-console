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

**Windows-Rollout ohne SSH** (silent, als SYSTEM, z. B. GPO-Startskript/Intune/PDQ):
`agent-builds/latest/windows-amd64/openuem-agent-fork-setup.exe` vom Server kopieren,
Aufruf `setup.exe /S /ORG=<id> /SITE=<id>` (IDs siehe Adresszeile der Konsole
`/tenant/<org>/site/<site>/`), Log in `%ProgramData%\OpenUEM-fork\install-agent.log`.

**Linux** (jede systemd-Distribution, als root) — Installer vom Server holen und:

```bash
sudo bash openuem-agent-fork-install.sh [--org <id> --site <id>] [--server-ip 192.0.2.10] [--domain uem.example.com]
```

Übernimmt auch eine bestehende offizielle `.deb`/pacman/rpm-Installation (Binary wird als
`.official` gesichert, Konfiguration bleibt erhalten). Erneutes Ausführen aktualisiert den Agenten.

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
