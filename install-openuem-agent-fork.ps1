<#
.SYNOPSIS
    Installs the OpenUEM agent on Windows exactly like the official docs and then
    replaces its binary with the one built from the fork.

.DESCRIPTION
    The installation is the official one (https://openuem.eu/docs/Installation/Agent/windows):
    1. The certificates (ca.cer, agent.cer, agent.key, sftp.cer) and the fork's agent are
       copied from the server over SSH (one password prompt), or taken from -FilesDir
    2. The official openuem-agent-setup.exe is run as administrator with the official
       flags: /server=<nats-host>:<port> /sftp=<port> /vnc=<port> /VERYSILENT
       (optionally /tenantid=<id> /siteid=<id>), with the certificates next to the
       installer (also passed via /cacert= /cert= /key= /sftpcert=)
    3. The installed agent binary is replaced with the fork's build, the official one is
       kept as <binary>.official

    It is run again on an already installed computer to update the fork's agent: the
    official installer is run again (it keeps the existing config, UUID, organization
    and site) and then the binary is swapped again.

    The names console.<domain>, nats.<domain> and ocsp.<domain> must resolve over DNS;
    no hosts entries are written.

    openuem-agent-fork-setup.exe, built by install-openuem-fork.sh (Inno Setup, like the
    official installer), contains this script, the certificates, the official installer
    and both agents and runs it with -FilesDir, without SSH.

    Settings that aren't given are taken, in this order, from:
      1. the last successful run on this computer (saved in
         %ProgramData%\OpenUEM-fork\install-agent.json)
      2. the installed agent's config (domain and ports) and DNS (server IP)
      3. the defaults
    So on a computer that already has the agent, running the script without parameters
    updates it with the same settings.

    Run in PowerShell as administrator:
      powershell -ExecutionPolicy Bypass -File .\install-openuem-agent-fork.ps1

.EXAMPLE
    .\install-openuem-agent-fork.ps1 -ServerIP 192.0.2.10 -Domain uem.example.com -P 2222

.EXAMPLE
    # Add a new computer to organization 2, site 3
    .\install-openuem-agent-fork.ps1 -ServerIP 192.0.2.10 -Domain uem.example.com -OrgID 2 -SiteID 3

.EXAMPLE
    # Update and overwrite the installed agent's config with these settings
    .\install-openuem-agent-fork.ps1 -ServerIP 192.0.2.10 -Domain uem.example.com -Overwrite

.EXAMPLE
    # Re-register the installed agent as a new computer of organization 3, site 3
    .\install-openuem-agent-fork.ps1 -ServerIP 192.0.2.10 -Domain uem.example.com -Overwrite -OrgID 3 -SiteID 3

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
    # Overwrite the installed agent's config (nats server, ports, and organization/site
    # when -OrgID/-SiteID are given) with the settings of this run. With -OrgID/-SiteID
    # the installed agent also gets a fresh UUID, so it registers again as a NEW
    # computer of that organization and site (the old entry stays in the console
    # until it's deleted)
    [switch]$Overwrite,
    # Take the certificates, the fork's agent and the official setup from this folder
    # instead of copying them from the server over SSH (used by the setup program)
    [string]$FilesDir,
    # Write the output to %ProgramData%\OpenUEM-fork\install-agent.log
    [switch]$Log,
    # Organization (tenant) and site IDs, both or none: the computer is added to this site
    # instead of the default one when it registers for the first time. The IDs are in the
    # console's address bar: .../tenant/<OrgID>/site/<SiteID>/...
    [ValidatePattern('^[0-9]*$')][string]$OrgID,
    [ValidatePattern('^[0-9]*$')][string]$SiteID
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step($message) { Write-Host "`n==> $message" -ForegroundColor Cyan }

# Sets key = value in a section of an INI file
function Set-IniValue($path, $section, $key, $value) {
    $lines = [System.Collections.Generic.List[string]]@(Get-Content $path)
    $inSection = $false; $sectionEnd = -1; $done = $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$') {
            if ($inSection) { $sectionEnd = $i; break }
            $inSection = ($Matches[1] -eq $section)
            if ($inSection) { $sectionEnd = $lines.Count }
        } elseif ($inSection -and $lines[$i] -match "^\s*$([regex]::Escape($key))\s*=") {
            $lines[$i] = "$key = $value"; $done = $true; break
        }
    }
    if (-not $done) {
        if ($sectionEnd -ge 0) { $lines.Insert($sectionEnd, "$key = $value") } else { $lines.Add("[$section]"); $lines.Add("$key = $value") }
    }
    [System.IO.File]::WriteAllLines($path, $lines, (New-Object System.Text.UTF8Encoding $false))
}

if ($Log) {
    $logFile = Join-Path $env:ProgramData "OpenUEM-fork\install-agent.log"
    New-Item -ItemType Directory -Force -Path (Split-Path $logFile) | Out-Null
    Start-Transcript -Path $logFile -Force | Out-Null
}

# --- Settings -----------------------------------------------------------------
# Settings that aren't given come from the last run, then from what is installed
$configFile = Join-Path $env:ProgramData "OpenUEM-fork\install-agent.json"
$rememberedSettings = "ServerIP", "Domain", "SshUser", "SshPort", "NatsPort", "SftpPort", "VncPort", "WorkDir"
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

# 3. The server IP from DNS (console.<domain>)
if (-not $ServerIP -and $Domain) {
    try {
        $address = [System.Net.Dns]::GetHostAddresses("console.$Domain") |
            Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1
        if ($address) { Use-Setting "ServerIP" $address.IPAddressToString "DNS" }
    } catch { }
}

# The server only accepts both IDs together and rejects the computer if they don't match
if (([bool]$OrgID) -ne ([bool]$SiteID)) {
    throw "-OrgID and -SiteID must be given together (see the console's address bar: /tenant/<OrgID>/site/<SiteID>/)"
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
foreach ($tool in $(if ($FilesDir) { @() } else { "ssh.exe", "tar.exe" })) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        throw "$tool was not found. Install the 'OpenSSH Client' optional feature (Settings > Apps > Optional features)"
    }
}

$natsServer = "nats.$Domain"
Write-Step "Checking the connection to ${natsServer}:$NatsPort (DNS must resolve it)"
if (-not (Test-NetConnection $natsServer -Port $NatsPort -InformationLevel Quiet -WarningAction SilentlyContinue)) {
    throw "Can't reach ${natsServer}:$NatsPort. Check the DNS records for $Domain and that the server is running"
}

# --- Files from the server ----------------------------------------------------
# The folder gets the agents' private key: only administrators and SYSTEM may read it,
# and the copies are deleted when the script ends
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
icacls.exe $WorkDir /inheritance:r /grant:r "*S-1-5-32-544:(OI)(CI)F" "*S-1-5-18:(OI)(CI)F" | Out-Null
if ($LASTEXITCODE -ne 0) { throw "Could not restrict the permissions of $WorkDir" }
Set-Location $WorkDir
function Remove-CopiedFiles {
    foreach ($name in "ca.cer", "agent.cer", "agent.key", "sftp.cer", "openuem-agent.exe", "openuem-agent-setup.exe", "openuem-files.tar") {
        Remove-Item (Join-Path $WorkDir $name) -Force -ErrorAction SilentlyContinue
    }
}
# Also when the script fails (a trap applies to the whole script, also before this line)
trap { if (Get-Command Remove-CopiedFiles -ErrorAction SilentlyContinue) { Remove-CopiedFiles }; break }

$remoteFiles = @(
    "certificates/ca/ca.cer",
    "certificates/agents/agent.cer",
    "certificates/agents/agent.key",
    "certificates/console/sftp.cer"
)
if (-not $OfficialOnly) { $remoteFiles += "agent-builds/latest/windows-amd64/openuem-agent.exe" }

if ($FilesDir) {
    Write-Step "Copying certificates and the fork's agent from $FilesDir"
    foreach ($file in $remoteFiles) {
        $source = Join-Path $FilesDir (Split-Path $file -Leaf)
        if (-not (Test-Path $source)) { throw "$source is missing" }
        Copy-Item $source $WorkDir -Force
    }
} else {
    Write-Step "Copying certificates and the fork's agent from $SshUser@${ServerIP}:$SshPort (enter the SSH password)"

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
}

# The settings work: remember them for the next run
$config = [ordered]@{}
foreach ($name in $rememberedSettings) {
    $value = Get-Variable $name -ValueOnly
    if ($value -is [System.Management.Automation.SwitchParameter]) { $value = $value.IsPresent }
    $config[$name] = $value
}
New-Item -ItemType Directory -Force -Path (Split-Path $configFile) | Out-Null
$config | ConvertTo-Json | Set-Content -Path $configFile -Encoding UTF8

# --- Official agent (the official installer, the official flags) ---------------
# https://openuem.eu/docs/Installation/Agent/windows: download openuem-agent-setup.exe,
# put ca.cer, sftp.cer, agent.cer and agent.key next to it (or pass /cacert= /cert=
# /key= /sftpcert=), then run as administrator:
#   openuem-agent-setup.exe /server=<nats-host>:<port> /sftp=<port> /vnc=<port> /VERYSILENT
#   (optionally /tenantid=<id> /siteid=<id>)
$service = Get-Service openuem-agent -ErrorAction SilentlyContinue
$wasInstalled = [bool]$service
if ($service) {
    Write-Step "The OpenUEM agent is already installed, running the official installer again to update it (it keeps the existing config)"
} else {
    Write-Step "Installing the official OpenUEM agent"
}

$setup = Join-Path $WorkDir "openuem-agent-setup.exe"
$bundledSetup = if ($FilesDir) { Join-Path $FilesDir "openuem-agent-setup.exe" }
if ($bundledSetup -and (Test-Path $bundledSetup)) {
    Write-Step "Using the bundled official OpenUEM agent installer $AgentVersion"
    Copy-Item $bundledSetup $setup -Force
} else {
    Write-Step "Downloading the official OpenUEM agent installer $AgentVersion"
    Invoke-WebRequest "https://downloads.openuem.eu/agents/$AgentVersion/windows/amd64/openuem-agent-setup.exe" -OutFile $setup -UseBasicParsing
}

Write-Step "Running the official installer with /server=${natsServer}:$NatsPort /sftp=$SftpPort /vnc=$VncPort /VERYSILENT"
# The certificates lie next to the installer (they were copied to $WorkDir above) and are
# also passed explicitly with the official flags
$arguments = "/server=${natsServer}:$NatsPort /sftp=$SftpPort /vnc=$VncPort /VERYSILENT /SUPPRESSMSGBOXES /NORESTART"
$arguments += " /cacert=`"$WorkDir\ca.cer`" /cert=`"$WorkDir\agent.cer`" /key=`"$WorkDir\agent.key`" /sftpcert=`"$WorkDir\sftp.cer`""
if ($OrgID) { $arguments += " /tenantid=$OrgID /siteid=$SiteID" }
$process = Start-Process $setup -ArgumentList $arguments -WorkingDirectory $WorkDir -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "The official installer failed with exit code $($process.ExitCode)" }

for ($i = 0; $i -lt 60 -and -not (Get-Service openuem-agent -ErrorAction SilentlyContinue); $i++) { Start-Sleep 2 }
if (-not (Get-Service openuem-agent -ErrorAction SilentlyContinue)) { throw "The openuem-agent service was not created" }
# Stop the agent before it reports with the official binary: the fork's binary must be
# in place when the computer registers for the first time
try { Stop-Service openuem-agent -Force -ErrorAction Stop } catch { }
Get-Process -Name openuem-agent -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

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
# The installer copied the certificates to the agent's folder
Remove-CopiedFiles

$iniFile = Join-Path (Split-Path $agentExe) "config\openuem.ini"
if ($OrgID -or $Overwrite) {
    if (-not (Test-Path $iniFile)) { throw "$iniFile was not found" }
    Stop-Service openuem-agent -Force -ErrorAction SilentlyContinue
    if ($OrgID) {
        Write-Step "Setting organization $OrgID, site $SiteID (also passed to the official installer as /tenantid /siteid)"
        if ($wasInstalled) {
            Write-Warning "Without -Overwrite this does not move the registered computer: -OrgID/-SiteID only apply to new computers. Move it in the console (computer > Overview), or run with -Overwrite to register it again as a new computer of that organization and site."
        }
        Set-IniValue $iniFile "Agent" "TenantID" $OrgID
        Set-IniValue $iniFile "Agent" "SiteID" $SiteID
        if ($wasInstalled -and $Overwrite) {
            # The console assigns the organization by the report's tenant, and an
            # existing agent keeps whatever site the database says. So the only way to
            # put an installed agent into the new organization and site is to make it a
            # NEW computer: with a fresh UUID the agent registers on its next start,
            # with the organization and site of the INI file. The old entry of this
            # computer stays in the console until it's deleted there
            Write-Step "-Overwrite: resetting the agent's UUID so it registers again as a new computer of organization $OrgID, site $SiteID"
            Set-IniValue $iniFile "Agent" "UUID" ""
        }
    }
    if ($Overwrite) {
        Write-Step "Overwriting $iniFile with the settings of this run"
        Set-IniValue $iniFile "NATS" "NATSServers" "${natsServer}:$NatsPort"
        Set-IniValue $iniFile "Agent" "SFTPPort" "$SftpPort"
        Set-IniValue $iniFile "Agent" "VNCProxyPort" "$VncPort"
    }
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
if (-not $wasInstalled) { Write-Host "Next: admit this computer in https://console.${Domain}:1323 (Agents)" }
Write-Host "Log:  $(Split-Path $agentExe)\logs\openuem-log.txt"
Write-Host "Don't use 'update agents' in the console for this computer, it would replace the fork's agent."
