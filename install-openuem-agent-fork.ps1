<#
.SYNOPSIS
    Installs the OpenUEM agent on Windows and replaces its binary with the one built from the fork.

.DESCRIPTION
    1. Adds console/nats/ocsp hosts entries for the OpenUEM server
    2. Copies the certificates and the fork's agent from the server over SSH (one password prompt)
    3. Downloads and silently installs the official OpenUEM agent
    4. Replaces the agent binary with the fork's build

    Run in PowerShell as administrator:
      powershell -ExecutionPolicy Bypass -File .\install-openuem-agent-fork.ps1

.EXAMPLE
    .\install-openuem-agent-fork.ps1 -ServerIP 192.168.2.164 -Domain uem.linck-it.de -SshPort 50

.EXAMPLE
    # Download and run in one line
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1))) -SshPort 50
#>
[CmdletBinding()]
param(
    [string]$ServerIP = "192.168.2.164",
    [string]$Domain = "uem.linck-it.de",
    [string]$SshUser = "root",
    [int]$SshPort = 50,
    [string]$AgentVersion = "0.11.0",
    [int]$NatsPort = 4433,
    [int]$SftpPort = 2022,
    [int]$VncPort = 1443,
    [string]$WorkDir = "C:\openuem-agent",
    # Install only the official agent, without the fork's binary
    [switch]$OfficialOnly,
    # Don't add hosts entries, e.g. when DNS already resolves the names
    [switch]$SkipHosts
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

# --- Checks -------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in PowerShell as administrator"
}
foreach ($tool in "ssh.exe", "tar.exe") {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool was not found. Install the 'OpenSSH Client' optional feature (Settings > Apps > Optional features)"
    }
}

# --- Hosts entries ------------------------------------------------------------
$names = "console", "nats", "ocsp" | ForEach-Object { "$_.$Domain" }
if (-not $SkipHosts) {
    Write-Step "Adding hosts entries for $($names -join ', ') -> $ServerIP"
    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $pattern = "\s(" + (($names | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")(\s|$)"
    $lines = @(Get-Content $hostsFile | Where-Object { $_ -notmatch $pattern })
    $lines += $names | ForEach-Object { "$ServerIP $_ # openuem" }
    Set-Content -Path $hostsFile -Value $lines -Encoding ASCII
    ipconfig /flushdns | Out-Null
}

$natsServer = "nats.$Domain"
Write-Step "Checking the connection to ${natsServer}:$NatsPort"
if (-not (Test-NetConnection $natsServer -Port $NatsPort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Can't reach ${natsServer}:$NatsPort. Check the hosts entries / DNS and that the server is running"
}

# --- Files from the server ----------------------------------------------------
Write-Step "Copying certificates and the fork's agent from $SshUser@${ServerIP}:$SshPort (enter the SSH password)"
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
Set-Location $WorkDir

$remoteFiles = @(
    "certificates/ca/ca.cer",
    "certificates/agents/agent.cer",
    "certificates/agents/agent.key",
    "certificates/console/sftp.cer"
)
if (-not $OfficialOnly) { $remoteFiles += "agent-builds/latest/windows-amd64/openuem-agent.exe" }

# One SSH connection: the server packs the files with tar. cmd.exe is used for the
# redirection because PowerShell 5.1 would corrupt the binary output.
$tarFile = Join-Path $WorkDir "openuem-files.tar"
$remoteCmd = "tar -C /opt/openuem -chf - " + ($remoteFiles -join " ")
cmd.exe /c "ssh -p $SshPort $SshUser@$ServerIP `"$remoteCmd`" > `"$tarFile`""
if ($LASTEXITCODE -ne 0) { throw "Copying the files from the server failed" }
tar.exe -xf $tarFile -C $WorkDir
if ($LASTEXITCODE -ne 0) { throw "Could not extract $tarFile" }
Remove-Item $tarFile

# The installer looks for the certificates next to it
foreach ($file in $remoteFiles) {
    Copy-Item (Join-Path $WorkDir $file) $WorkDir -Force
}
Remove-Item (Join-Path $WorkDir "certificates"), (Join-Path $WorkDir "agent-builds") -Recurse -Force -ErrorAction SilentlyContinue

# --- Official agent -----------------------------------------------------------
$service = Get-Service openuem-agent -ErrorAction SilentlyContinue
if ($service) {
    Write-Step "The OpenUEM agent is already installed, skipping the installer"
} else {
    $setup = Join-Path $WorkDir "openuem-agent-setup.exe"
    Write-Step "Downloading the official OpenUEM agent $AgentVersion"
    Invoke-WebRequest "https://downloads.openuem.eu/agents/$AgentVersion/windows/amd64/openuem-agent-setup.exe" -OutFile $setup -UseBasicParsing

    Write-Step "Installing the official OpenUEM agent"
    $arguments = "/server=${natsServer}:$NatsPort /sftp=$SftpPort /vnc=$VncPort /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
    $process = Start-Process $setup -ArgumentList $arguments -WorkingDirectory $WorkDir -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "The installer failed with exit code $($process.ExitCode)" }

    for ($i = 0; $i -lt 60 -and -not (Get-Service openuem-agent -ErrorAction SilentlyContinue); $i++) { Start-Sleep 2 }
    if (-not (Get-Service openuem-agent -ErrorAction SilentlyContinue)) { throw "The openuem-agent service was not created" }
}

# --- Fork's agent -------------------------------------------------------------
$agentExe = $null
$serviceInfo = Get-CimInstance Win32_Service -Filter "Name='openuem-agent'"
if ($serviceInfo.PathName -match '^"?([^"]+\.exe)') { $agentExe = $Matches[1] }
if (-not $agentExe -or -not (Test-Path $agentExe)) { throw "Could not find the agent binary of the openuem-agent service ($($serviceInfo.PathName))" }

if (-not $OfficialOnly) {
    Write-Step "Replacing $agentExe with the fork's agent"
    # The agent may not answer a stop request while it sends its first report
    try { Stop-Service openuem-agent -Force -ErrorAction Stop } catch { Write-Host "The service didn't stop in time, killing it" }
    taskkill.exe /F /IM openuem-agent.exe 2>$null | Out-Null
    for ($i = 0; $i -lt 30 -and (Get-Process -Name openuem-agent -ErrorAction SilentlyContinue); $i++) { Start-Sleep 1 }
    if (-not (Test-Path "$agentExe.official")) { Copy-Item $agentExe "$agentExe.official" }
    Copy-Item (Join-Path $WorkDir "openuem-agent.exe") $agentExe -Force
}

$startTime = Get-Date
try {
    Start-Service openuem-agent -ErrorAction Stop
} catch {
    $asr = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1121; StartTime = $startTime.AddMinutes(-1) } -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'openuem' } | Select-Object -First 1
    if ($asr) {
        Write-Warning "Microsoft Defender's attack surface reduction rules blocked the fork's agent (unsigned, unknown file)."
        Write-Warning "Use a computer without these company policies, or add an ASR exclusion for $agentExe."
    }
    if (-not $OfficialOnly -and (Test-Path "$agentExe.official")) {
        Write-Warning "Restoring the official agent"
        Copy-Item "$agentExe.official" $agentExe -Force
        Start-Service openuem-agent -ErrorAction SilentlyContinue
    }
    throw "The openuem-agent service could not be started: $($_.Exception.Message)"
}
Start-Sleep 5
$status = (Get-Service openuem-agent).Status

Write-Host ""
Write-Host "OpenUEM agent service: $status" -ForegroundColor Green
if (-not $OfficialOnly) { Write-Host "The fork's agent is installed, the official binary was saved as $agentExe.official" }
Write-Host "Next: admit this computer in https://console.${Domain}:1323 (Agents)"
Write-Host "Log:  $(Split-Path $agentExe)\logs\openuem-log.txt"
Write-Host "Don't use 'update agents' in the console for this computer, it would replace the fork's agent."
