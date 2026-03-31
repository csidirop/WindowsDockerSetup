# This script sets up Docker Engine inside a WSL distribution, and creates PowerShell functions and cmd.exe shims to allow using Docker from the Windows side while ensuring the WSL Docker daemon is running when needed.

[CmdletBinding()]
param(
    [string]$Distro,
    [switch]$CreateCmdShim = $true,
    [switch]$ForceDockerInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:DistroWasSpecified = $PSBoundParameters.ContainsKey('Distro')

# Helper functions:
function Write-Info($Message) { Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Ok($Message) { Write-Host "[ OK ] $Message" -ForegroundColor Green }
function Write-WarnLine($Message) { Write-Warning $Message }

# Normalizes text returned by wsl.exe so parsing does not depend on formatting quirks or embedded NUL characters.
function ConvertFrom-WslText {
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return ''
    }

    $lines = @($Value | ForEach-Object {
        if ($null -eq $_) { '' } else { [string]$_ }
    })

    $text = ($lines -join "`n").Replace([string][char]0, '')
    return $text.TrimEnd()
}

# Returns a cleaned list of non-empty lines from wsl.exe output.
function Get-WslOutputLines {
    param([AllowNull()]$Value)

    $text = ConvertFrom-WslText -Value $Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return @()
    }

    return @(
        $text -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
}

# Checks if a command is available in the current PowerShell session:
function Test-CommandExists {
    param([Parameter(Mandatory)][string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

# Invokes a shell command inside WSL and captures output and exit code:
function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string]$ShellCommand,
        [switch]$AsRoot,
        [switch]$IgnoreExitCode
    )

    $args = @('-d', $Distro)
    if ($AsRoot) { $args += @('-u', 'root') }
    $args += @('--', 'sh', '-lc', $ShellCommand)

    $output = & wsl.exe @args 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $text = ConvertFrom-WslText -Value $output
        throw "WSL command failed (exit $exitCode): $ShellCommand`n$text"
    }
    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ConvertFrom-WslText -Value $output
    }
}

# Returns the list of installed WSL distro names without relying on the formatted verbose table output.
function Get-WslDistroNames {
    $raw = & wsl.exe --list --quiet 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query WSL distributions. Output:`n$(ConvertFrom-WslText -Value $raw)"
    }

    $names = Get-WslOutputLines -Value $raw
    if (-not $names) {
        throw 'WSL responded, but no usable distro names could be parsed from ''wsl --list --quiet''.'
    }

    return $names
}

# Resolves the current default WSL distro by invoking WSL without '-d' and reading WSL_DISTRO_NAME.
function Get-DefaultWslDistroName {
    $raw = & wsl.exe -- sh -lc 'printf %s "$WSL_DISTRO_NAME"' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to resolve the default WSL distribution. Output:`n$(ConvertFrom-WslText -Value $raw)"
    }

    $name = ConvertFrom-WslText -Value $raw
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw 'WSL did not report a default distribution name.'
    }

    return $name
}

# Resolves the target distro name, defaulting to the machine's current default WSL distribution when -Distro is omitted.
function Resolve-TargetDistroName {
    if ($script:DistroWasSpecified) {
        if ([string]::IsNullOrWhiteSpace($Distro)) {
            throw 'The -Distro parameter was provided but no distro name was supplied.'
        }

        return $Distro.Trim()
    }

    return (Get-DefaultWslDistroName)
}

# Reads the WSL version for a known distro from the verbose table after normalizing wsl.exe output.
function Get-WslDistroVersion {
    param([Parameter(Mandatory)][string]$Name)

    $raw = & wsl.exe -l -v 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to query WSL distribution versions. Output:`n$(ConvertFrom-WslText -Value $raw)"
    }

    $lines = Get-WslOutputLines -Value $raw
    $pattern = '^\*?\s*(?<name>' + [regex]::Escape($Name) + ')\s{2,}(?<state>.+?)\s+(?<version>\d+)\s*$'

    foreach ($line in $lines) {
        if ($line -match 'NAME\s+STATE\s+VERSION') { continue }
        if ($line -match $pattern) {
            return [int]$matches.version
        }
    }

    $output = ConvertFrom-WslText -Value $raw
    throw @"
The WSL distribution '$Name' was found, but its WSL version could not be determined from 'wsl -l -v'.

WSL output:
$output
"@
}

# Ensures that WSL is installed and can be invoked successfully:
function Ensure-WslPresent {
    $installTarget = if ($script:DistroWasSpecified -and -not [string]::IsNullOrWhiteSpace($Distro)) { $Distro } else { 'Ubuntu' }

    if (-not (Test-CommandExists -Name 'wsl.exe')) {
        throw @"
WSL is not available on this machine.

Install it from an elevated PowerShell:
  wsl --install -d $installTarget

Then reboot Windows, launch $installTarget once to complete first-time setup, and re-run this script.
"@
    }

    $statusOutput = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw @"
WSL appears to be unavailable or not initialized.

Try from an elevated PowerShell:
  wsl --install -d $installTarget

Then reboot Windows, launch $installTarget once, and re-run this script.

WSL output:
$(ConvertFrom-WslText -Value $statusOutput)
"@
    }

    Write-Ok 'WSL is installed.'
}

# Ensures that the specified WSL distribution is installed, uses WSL 2, and can be invoked non-interactively:
function Ensure-DistroPresent {
    $availableDistros = Get-WslDistroNames
    $targetName = $availableDistros | Where-Object { $_ -ieq $Distro } | Select-Object -First 1

    if (-not $targetName) {
        $knownDistros = ($availableDistros | Sort-Object) -join ', '
        throw @"
The WSL distribution '$Distro' is not installed.

Discovered WSL distributions:
  $knownDistros

Install it with:
  wsl --install -d $Distro

Then launch it once to create your Linux user, and re-run this script.
"@
    }

    $Distro = $targetName
    $script:Distro = $targetName
    $version = Get-WslDistroVersion -Name $targetName

    if ($version -ne 2) {
        Write-Info "Converting '$Distro' from WSL $version to WSL 2..."
        & wsl.exe --set-version $Distro 2
        if ($LASTEXITCODE -ne 0) {
            throw @"
Failed to convert '$Distro' to WSL 2.

Try manually:
  wsl --set-version $Distro 2
"@
        }
        Write-Ok "'$Distro' now uses WSL 2."
    }
    else {
        Write-Ok "'$Distro' is installed and already uses WSL 2."
    }

    try {
        $probe = Invoke-Wsl -ShellCommand 'printf ok'
        if ($probe.Output -notmatch '^ok$') {
            throw 'Unexpected probe output.'
        }
    }
    catch {
        throw @"
The distro '$Distro' exists but is not ready for non-interactive use.

Open it once manually:
  wsl -d $Distro

Finish the first-time Linux user setup, then re-run this script.
"@
    }
}

# Gets the default Linux user for the distribution by invoking 'id -un' inside WSL:
function Get-DefaultLinuxUser {
    $user = Invoke-Wsl -ShellCommand 'id -un'
    return $user.Output.Trim()
}

# Checks if Docker is installed and working inside WSL by running 'docker compose version':
function Test-DockerInstalled {
    $result = Invoke-Wsl -ShellCommand 'command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1' -IgnoreExitCode
    return $result.ExitCode -eq 0
}

# Installs Docker Engine inside the WSL distribution using the official Docker installation script for Ubuntu:
function Install-DockerInWsl {
    Write-Info "Installing Docker Engine inside '$Distro'..."

    $installScript = @'
set -eu
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get remove -y docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc >/dev/null 2>&1 || true
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat >/etc/apt/sources.list.d/docker.sources <<SRC
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
SRC

apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
'@

    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($installScript))
    Invoke-Wsl -AsRoot -ShellCommand "printf '%s' '$encoded' | base64 -d | sh"
    Write-Ok 'Docker Engine packages installed inside WSL.'
}

# Ensures the default Linux user is added to the 'docker' group for permission to use Docker without sudo:
function Ensure-DockerPermissions {
    $linuxUser = Get-DefaultLinuxUser
    if ($linuxUser -eq 'root') {
        Write-WarnLine "The default Linux user for '$Distro' is root. Skipping docker group setup."
        return
    }

    Invoke-Wsl -AsRoot -ShellCommand "getent group docker >/dev/null 2>&1 || groupadd docker"
    Invoke-Wsl -AsRoot -ShellCommand "usermod -aG docker '$linuxUser'"
    Write-Ok "Added Linux user '$linuxUser' to the docker group."
    Write-WarnLine "You may need to run 'wsl --shutdown' once after setup so new group membership is applied."
}

# Starts dockerd inside WSL and waits until the daemon responds.
function Ensure-DockerDaemonRunning {
    Invoke-Wsl -AsRoot -ShellCommand 'pgrep -x dockerd >/dev/null 2>&1 || nohup dockerd >/tmp/dockerd.log 2>&1 &' | Out-Null

    for ($i = 0; $i -lt 20; $i++) {
        $ready = Invoke-Wsl -AsRoot -ShellCommand 'docker info >/dev/null 2>&1' -IgnoreExitCode
        if ($ready.ExitCode -eq 0) {
            return
        }

        Start-Sleep -Milliseconds 500
    }

    throw @"
Docker daemon in '$Distro' did not become ready in time.

Inspect the daemon log inside WSL:
  tail -n 200 /tmp/dockerd.log
"@
}

# Runs a final test against the user-facing Docker commands after setup.
function Test-DockerPostSetup {
    Write-Info "Running Docker test in '$Distro'..."

    Ensure-DockerDaemonRunning

    $smokeTest = Invoke-Wsl -ShellCommand 'docker version >/dev/null 2>&1 && docker ps >/dev/null 2>&1 && docker compose version >/dev/null 2>&1' -IgnoreExitCode
    if ($smokeTest.ExitCode -eq 0) {
        Write-Ok "Docker test succeeded in '$Distro'."
        return
    }

    $linuxUser = Get-DefaultLinuxUser
    $groupOutput = ''
    if ($linuxUser -ne 'root') {
        $groupInfo = Invoke-Wsl -ShellCommand 'id -nG' -IgnoreExitCode
        $groupOutput = $groupInfo.Output
    }

    $details = Invoke-Wsl -ShellCommand @'
docker version 2>&1 || true
echo __WSL_DOCKER_SMOKE_SEPARATOR__
docker ps 2>&1 || true
echo __WSL_DOCKER_SMOKE_SEPARATOR__
docker compose version 2>&1 || true
'@ -IgnoreExitCode

    if ($linuxUser -ne 'root' -and $groupOutput -notmatch '(^|\s)docker($|\s)') {
        throw @"
Docker was installed, but the final test failed because the current WSL session for '$linuxUser' does not yet have the 'docker' group active.

Run once:
  wsl --shutdown

Then re-run this script or test manually:
  docker version
  docker ps
  docker compose version
"@
    }

    throw @"
Docker was installed, but the final test failed in '$Distro'.

Test output:
$($details.Output)

Inspect the daemon log inside WSL:
  tail -n 200 /tmp/dockerd.log
"@
}

# Invokes a cmd shim file and captures its output and exit code.
function Invoke-CmdShimFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string[]]$Arguments = @(),
        [switch]$IgnoreExitCode
    )

    $output = & $Path @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if (-not $IgnoreExitCode -and $exitCode -ne 0) {
        $text = ConvertFrom-WslText -Value $output
        throw "cmd shim failed (exit $exitCode): $Path $($Arguments -join ' ')`n$text"
    }

    [pscustomobject]@{
        ExitCode = $exitCode
        Output   = ConvertFrom-WslText -Value $output
    }
}

# Runs a final test against the Windows cmd shims after they are written.
function Test-CmdShimPostSetup {
    param([Parameter(Mandatory)][string]$BinDir)

    $dockerCmdPath = Join-Path $BinDir 'docker.cmd'
    $dockerComposeCmdPath = Join-Path $BinDir 'docker-compose.cmd'

    Write-Info "Running cmd shim test from '$BinDir'..."

    $dockerVersion = Invoke-CmdShimFile -Path $dockerCmdPath -Arguments @('version') -IgnoreExitCode
    $dockerPs = Invoke-CmdShimFile -Path $dockerCmdPath -Arguments @('ps') -IgnoreExitCode
    $dockerComposeVersion = Invoke-CmdShimFile -Path $dockerComposeCmdPath -Arguments @('version') -IgnoreExitCode

    if ($dockerVersion.ExitCode -eq 0 -and $dockerPs.ExitCode -eq 0 -and $dockerComposeVersion.ExitCode -eq 0) {
        Write-Ok 'cmd shim smoke test succeeded.'
        return
    }

    $details = @(
        'docker.cmd version:'
        $dockerVersion.Output
        ''
        'docker.cmd ps:'
        $dockerPs.Output
        ''
        'docker-compose.cmd version:'
        $dockerComposeVersion.Output
    ) -join "`n"

    throw @"
The Windows cmd shim smoke test failed.

Smoke test output:
$details

Inspect the daemon log inside WSL:
  tail -n 200 /tmp/dockerd.log
"@
}

# Writes a PowerShell wrapper block to the user's profile that defines functions and aliases for using Docker inside WSL, ensuring the daemon is running when needed:
function Write-ProfileWrapper {
    $profilePath = $PROFILE.CurrentUserAllHosts
    $profileDir = Split-Path -Parent $profilePath
    if (-not (Test-Path $profileDir)) {
        New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
    }
    if (-not (Test-Path $profilePath)) {
        New-Item -ItemType File -Path $profilePath -Force | Out-Null
    }

    $markerStart = '# >>> wsl-docker-wrapper >>>'
    $markerEnd   = '# <<< wsl-docker-wrapper <<<'

    $block = @"
$markerStart
`$script:WslDockerDistro = '$Distro'

function Start-WslDockerDaemon {
    & wsl.exe -d `$script:WslDockerDistro -u root -- sh -lc "pgrep -x dockerd >/dev/null 2>&1 || nohup dockerd >/tmp/dockerd.log 2>&1 &"
    for (`$i = 0; `$i -lt 20; `$i++) {
        & wsl.exe -d `$script:WslDockerDistro -u root -- sh -lc "docker info >/dev/null 2>&1"
        if (`$LASTEXITCODE -eq 0) { return }
        Start-Sleep -Milliseconds 500
    }
}

function Stop-WslDockerDaemon {
    & wsl.exe -d `$script:WslDockerDistro -u root -- sh -lc "pkill dockerd >/dev/null 2>&1 || true"
}

function Get-WslDockerLog {
    & wsl.exe -d `$script:WslDockerDistro -- sh -lc "tail -n 200 /tmp/dockerd.log"
}

function Ensure-WslDockerDaemon {
    & wsl.exe -d `$script:WslDockerDistro -u root -- sh -lc "docker info >/dev/null 2>&1"
    if (`$LASTEXITCODE -ne 0) {
        Start-WslDockerDaemon
    }
}

function docker {
    Ensure-WslDockerDaemon
    & wsl.exe -d `$script:WslDockerDistro -- docker @args
}

function docker-compose {
    docker compose @args
}

Set-Alias docker-start Start-WslDockerDaemon
Set-Alias docker-stop Stop-WslDockerDaemon
Set-Alias docker-log Get-WslDockerLog
$markerEnd
"@

    $existing = Get-Content -Path $profilePath -Raw
    $pattern = [regex]::Escape($markerStart) + '.*?' + [regex]::Escape($markerEnd)
    if ($existing -match $pattern) {
        $newContent = [regex]::Replace($existing, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $block }, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    }
    else {
        $sep = if ([string]::IsNullOrWhiteSpace($existing)) { '' } else { "`r`n`r`n" }
        $newContent = $existing + $sep + $block
    }

    Set-Content -Path $profilePath -Value $newContent -Encoding UTF8
    Write-Ok "PowerShell wrapper written to $profilePath"
}

# Ensures that a 'bin' directory exists in the user's home and is on the user PATH, returning the path to the 'bin' directory:
function Ensure-UserBinOnPath {
    $userBin = Join-Path $HOME 'bin'
    if (-not (Test-Path $userBin)) {
        New-Item -ItemType Directory -Path $userBin -Force | Out-Null
    }

    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if ($userPath) {
        $parts = $userPath -split ';' | Where-Object { $_ }
    }

    if ($parts -notcontains $userBin) {
        $newUserPath = if ($userPath) { "$userPath;$userBin" } else { $userBin }
        [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
        $env:Path = "$env:Path;$userBin"
        Write-Ok "Added $userBin to the user PATH."
    }
    else {
        Write-Ok "$userBin is already on the user PATH."
    }

    return $userBin
}

# Writes a PowerShell helper script that cmd shims can call without fighting cmd.exe escaping rules.
function Write-CmdShimHelper {
    param([Parameter(Mandatory)][string]$BinDir)

    $helperPath = Join-Path $BinDir 'wsl-docker-proxy.ps1'
    $helperContent = @"
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]`$Distro,
    [Parameter(Mandatory)][ValidateSet('docker', 'compose')][string]`$Mode,
    [string[]]`$RemainingArgs = @()
)

Set-StrictMode -Version Latest
`$ErrorActionPreference = 'Stop'

function Invoke-WslProxy {
    param(
        [Parameter(Mandatory)][string]`$ShellCommand,
        [switch]`$AsRoot,
        [switch]`$IgnoreExitCode
    )

    `$invokeArgs = @('-d', `$Distro)
    if (`$AsRoot) { `$invokeArgs += @('-u', 'root') }
    `$invokeArgs += @('--', 'sh', '-lc', `$ShellCommand)

    `$output = & wsl.exe @invokeArgs 2>&1
    `$exitCode = `$LASTEXITCODE
    `$text = (`$output | Out-String).Replace([string][char]0, '').Trim()

    if (-not `$IgnoreExitCode -and `$exitCode -ne 0) {
        throw "WSL command failed (exit `$exitCode): `$ShellCommand`n`$text"
    }

    [pscustomobject]@{
        ExitCode = `$exitCode
        Output   = `$text
    }
}

Invoke-WslProxy -AsRoot -ShellCommand 'pgrep -x dockerd >/dev/null 2>&1 || nohup dockerd >/tmp/dockerd.log 2>&1 &' | Out-Null

for (`$i = 0; `$i -lt 20; `$i++) {
    `$ready = Invoke-WslProxy -AsRoot -ShellCommand 'docker info >/dev/null 2>&1' -IgnoreExitCode
    if (`$ready.ExitCode -eq 0) { break }
    Start-Sleep -Milliseconds 500
}

if (`$ready.ExitCode -ne 0) {
    Write-Error 'Docker daemon in WSL did not become ready in time.'
    exit 1
}

`$dockerArgs = @('-d', `$Distro, '--', 'docker')
if (`$Mode -eq 'compose') {
    `$dockerArgs += 'compose'
}
`$dockerArgs += `$RemainingArgs

& wsl.exe @dockerArgs
exit `$LASTEXITCODE
"@

    Set-Content -Path $helperPath -Value $helperContent -Encoding UTF8
    return $helperPath
}

# Writes cmd.exe shim batch files for 'docker' and 'docker-compose' that invoke the corresponding PowerShell functions, ensuring the WSL Docker daemon is running when used from cmd.exe:
function Write-CmdShim {
    param(
        [Parameter(Mandatory)][string]$BinDir,
        [Parameter(Mandatory)][string]$HelperPath
    )

    $dockerCmd = @"
@echo off
setlocal
set "WSL_DOCKER_HELPER=%~dp0wsl-docker-proxy.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WSL_DOCKER_HELPER%" -Distro "$Distro" -Mode docker -RemainingArgs %*
exit /b %ERRORLEVEL%
"@

    $dockerComposeCmd = @"
@echo off
setlocal
set "WSL_DOCKER_HELPER=%~dp0wsl-docker-proxy.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%WSL_DOCKER_HELPER%" -Distro "$Distro" -Mode compose -RemainingArgs %*
exit /b %ERRORLEVEL%
"@

    Set-Content -Path (Join-Path $BinDir 'docker.cmd') -Value $dockerCmd -Encoding ASCII
    Set-Content -Path (Join-Path $BinDir 'docker-compose.cmd') -Value $dockerComposeCmd -Encoding ASCII
    Write-Ok "cmd helper script written to $HelperPath"
    Write-Ok "cmd.exe shims written to $BinDir"
}


# Main script logic:

Write-Info 'Checking WSL...'
Ensure-WslPresent

$Distro = Resolve-TargetDistroName

Write-Info "Checking distro '$Distro'..."
Ensure-DistroPresent

$binDir = $null

if ($ForceDockerInstall -or -not (Test-DockerInstalled)) {
    Install-DockerInWsl
    Ensure-DockerPermissions
}
else {
    Write-Ok 'Docker is already installed inside WSL.'
    Ensure-DockerPermissions
}

Write-Info 'Writing PowerShell wrapper...'
Write-ProfileWrapper

if ($CreateCmdShim) {
    Write-Info 'Writing cmd.exe shim...'
    $binDir = Ensure-UserBinOnPath
    $helperPath = Write-CmdShimHelper -BinDir $binDir
    Write-CmdShim -BinDir $binDir -HelperPath $helperPath
}

Test-DockerPostSetup
if ($CreateCmdShim) {
    Test-CmdShimPostSetup -BinDir $binDir
}

Write-Host ''
Write-Host 'Setup complete.' -ForegroundColor Green
Write-Host ''
Write-Host 'Open a new PowerShell window, then test:' -ForegroundColor Yellow
Write-Host '  docker version'
Write-Host '  docker ps'
Write-Host '  docker compose version'
Write-Host ''
Write-Host 'If group membership was just changed, run once:' -ForegroundColor Yellow
Write-Host '  wsl --shutdown'
