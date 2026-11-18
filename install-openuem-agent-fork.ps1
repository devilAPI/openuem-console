<#
.SYNOPSIS
    Installs the OpenUEM agent on Windows and replaces its binary with the one built from the fork.

.DESCRIPTION
    1. Adds console/nats/ocsp hosts entries for the OpenUEM server
    2. Copies the certificates and the fork's agent from the server over SSH (one password prompt)
    3. Downloads and silently installs the official OpenUEM agent
    4. Replaces the agent binary with the fork's build

    Run it again to update the agent to the latest build on the server.

    Settings that aren't given are taken, in this order, from:
      1. the last successful run on this computer (saved in
         %ProgramData%\OpenUEM-fork\install-agent.json)
      2. the installed agent's config (domain and ports) and the hosts entries or DNS
         (server IP)
      3. the defaults
    So on a computer that already has the agent, running the script without parameters
    updates it with the same settings.

    Run in PowerShell as administrator:
      powershell -ExecutionPolicy Bypass -File .\install-openuem-agent-fork.ps1

.EXAMPLE
    .\install-openuem-agent-fork.ps1 -ServerIP 192.0.2.10 -Domain uem.example.com -P 2222

.EXAMPLE
    # Update with the settings of the last run
    .\install-openuem-agent-fork.ps1

.EXAMPLE
    # Download and run in one line
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/devilAPI/openuem-console/install-script/install-openuem-agent-fork.ps1))) -ServerIP 192.0.2.10 -Domain uem.example.com
#>
[CmdletBinding()]
param(
    # IP address of the OpenUEM server
    [string]$ServerIP,
    # Domain used when installing the server (console.<domain>, nats.<domain>, ocsp.<domain>)
    [string]$Domain,
    [string]$SshUser = "root",
    # SSH port of the server, -P like scp
    [Alias("P")][int]$SshPort = 22,
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

# --- Settings -----------------------------------------------------------------
# Settings that aren't given come from the last run, then from what is installed
$configFile = Join-Path $env:ProgramData "OpenUEM-fork\install-agent.json"
$rememberedSettings = "ServerIP", "Domain", "SshUser", "SshPort", "NatsPort", "SftpPort", "VncPort", "WorkDir", "SkipHosts"
$settingSource = @{}
foreach ($name in $rememberedSettings) {
    $settingSource[$name] = if ($PSBoundParameters.ContainsKey($name)) { "parameter" } else { "default" }
}
# Sets a setting that is still at its default. Scope 1 is the script body, also when the
# script runs as a script block (irm ... one-liner), where the script: scope is the caller's.
function Use-Setting($name, $value, $source) {
    if ($settingSource[$name] -eq "default" -and $null -ne $value -and "$value" -ne "") {
        Set-Variable -Name $name -Value $value -Scope 1
        $settingSource[$name] = $source
    }
}

# 1. The last successful run
if (Test-Path $configFile) {
    try {
        $saved = Get-Content $configFile -Raw | ConvertFrom-Json
        foreach ($name in $rememberedSettings) { Use-Setting $name $saved.$name "last run" }
    } catch {
        Write-Warning "Ignoring ${configFile}: $($_.Exception.Message)"
    }
}

# 2. The installed agent: <agent folder>\config\openuem.ini has nats.<domain>:<port> and the ports
$installed = Get-CimInstance Win32_Service -Filter "Name='openuem-agent'" -ErrorAction SilentlyContinue
if ($installed -and $installed.PathName -match '^"?([^"]+\.exe)') {
    $iniFile = Join-Path (Split-Path $Matches[1]) "config\openuem.ini"
    if (Test-Path $iniFile) {
        foreach ($line in Get-Content $iniFile) {
            if ($line -match '^\s*NATSServers\s*=\s*nats\.([^:,\s]+):(\d+)') {
                Use-Setting "Domain" $Matches[1] "installed agent"
                Use-Setting "NatsPort" ([int]$Matches[2]) "installed agent"
            } elseif ($line -match '^\s*SFTPPort\s*=\s*(\d+)') {
                Use-Setting "SftpPort" ([int]$Matches[1]) "installed agent"
            } elseif ($line -match '^\s*VNCProxyPort\s*=\s*(\d+)') {
                Use-Setting "VncPort" ([int]$Matches[1]) "installed agent"
            }
        }
    }
}

# -Domain is the base domain; accept a host name like nats.<domain> too
if ($Domain -match '^(console|nats|ocsp)\.(.+\..+)$') {
    Write-Warning "-Domain must be the base domain, using $($Matches[2]) instead of $Domain"
    $Domain = $Matches[2]
}

# 3. The server IP: the hosts entry of console.<domain> (written by this script), then DNS
if (-not $ServerIP) {
    $hostsPattern = if ($Domain) { '^\s*([0-9A-Fa-f:.]+)\s+console\.' + [regex]::Escape($Domain) + '(\s|$)' } else { '^\s*([0-9A-Fa-f:.]+)\s+console\.(\S+).*#\s*openuem' }
    $hostsLine = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction SilentlyContinue |
        Where-Object { $_ -match $hostsPattern } | Select-Object -First 1
    if ($hostsLine -and $hostsLine -match $hostsPattern) {
        Use-Setting "ServerIP" $Matches[1] "hosts file"
        if (-not $Domain) { Use-Setting "Domain" $Matches[2] "hosts file" }
    }
}
if (-not $ServerIP -and $Domain) {
    try {
        $address = [System.Net.Dns]::GetHostAddresses("console.$Domain") |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if ($address) { Use-Setting "ServerIP" $address.IPAddressToString "DNS" }
    } catch { }
}

if (-not $ServerIP -or -not $Domain) {
    throw "The server IP and domain are unknown on this computer. Run the script once with -ServerIP <ip> -Domain <domain>; later runs reuse them"
}

Write-Step "Settings"
foreach ($name in $rememberedSettings) {
    Write-Host ("    {0,-10} {1,-24} ({2})" -f $name, (Get-Variable $name -ValueOnly), $settingSource[$name])
}

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
    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $current = @(Get-Content $hostsFile)

    # Which addresses do the names have now? (comments ignored)
    $mapped = @{}
    foreach ($line in $current) {
        $entry = @(($line -replace '#.*$', '').Trim() -split '\s+' | Where-Object { $_ })
        for ($i = 1; $i -lt $entry.Count; $i++) {
            if ($names -contains $entry[$i]) {
                if (-not $mapped.ContainsKey($entry[$i])) { $mapped[$entry[$i]] = @() }
                $mapped[$entry[$i]] += $entry[0]
            }
        }
    }
    $outdated = @($names | Where-Object { -not $mapped.ContainsKey($_) -or $mapped[$_].Count -ne 1 -or $mapped[$_][0] -ne $ServerIP })

    if ($outdated.Count -eq 0) {
        Write-Step "The hosts entries for $($names -join ', ') already point to $ServerIP"
    } else {
        Write-Step "Adding hosts entries for $($names -join ', ') -> $ServerIP"
        $pattern = "\s(" + (($names | ForEach-Object { [regex]::Escape($_) }) -join "|") + ")(\s|$)"
        $newEntries = @($names | ForEach-Object { "$ServerIP $_ # openuem" })
        $lines = @($current | Where-Object { $_ -notmatch $pattern }) + $newEntries
        $text = ($lines -join "`r`n") + "`r`n"

        $item = Get-Item $hostsFile
        if ($item.IsReadOnly) { $item.IsReadOnly = $false }
        # Antivirus software often has the hosts file open for a moment, so retry
        for ($attempt = 1; ; $attempt++) {
            try {
                [System.IO.File]::WriteAllText($hostsFile, $text, [System.Text.Encoding]::ASCII)
                break
            } catch {
                if ($attempt -ge 10) {
                    throw "Could not write $hostsFile ($($_.Exception.Message)). An antivirus may be locking or protecting it. Add these lines yourself, then run the script again:`n$($newEntries -join "`n")"
                }
                Start-Sleep 1
            }
        }
        ipconfig /flushdns | Out-Null
    }
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

# One SSH connection: the server packs the files with tar. Start-Process writes the
# binary output to the file unchanged (PowerShell 5.1's redirection would corrupt it).
# A cmd.exe redirection hangs on larger output when the script itself runs without a
# console (over SSH or a remote management tool). ssh still asks for the password on
# the console.
$tarFile = Join-Path $WorkDir "openuem-files.tar"
$remoteCmd = "tar -C /opt/openuem -chf - " + ($remoteFiles -join " ")
$ssh = Start-Process -FilePath "ssh.exe" -ArgumentList "-p $SshPort $SshUser@$ServerIP `"$remoteCmd`"" `
    -RedirectStandardOutput $tarFile -NoNewWindow -Wait -PassThru
if ($ssh.ExitCode -ne 0) { throw "Copying the files from the server failed (ssh exit code $($ssh.ExitCode))" }
tar.exe -xf $tarFile -C $WorkDir
if ($LASTEXITCODE -ne 0) { throw "Could not extract $tarFile" }
Remove-Item $tarFile

# The installer looks for the certificates next to it
foreach ($file in $remoteFiles) {
    Copy-Item (Join-Path $WorkDir $file) $WorkDir -Force
}
Remove-Item (Join-Path $WorkDir "certificates"), (Join-Path $WorkDir "agent-builds") -Recurse -Force -ErrorAction SilentlyContinue

# The settings work: remember them for the next run
$config = [ordered]@{}
foreach ($name in $rememberedSettings) {
    $value = Get-Variable $name -ValueOnly
    if ($value -is [System.Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
    $config[$name] = $value
}
New-Item -ItemType Directory -Force -Path (Split-Path $configFile) | Out-Null
$config | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8

# --- Official agent -----------------------------------------------------------
$service = Get-Service openuem-agent -ErrorAction SilentlyContinue
if ($service) {
    Write-Step "The OpenUEM agent is already installed, updating it to the latest build on the server"
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
    Get-Process -Name openuem-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
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
