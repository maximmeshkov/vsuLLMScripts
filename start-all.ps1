# start-all.ps1 - Windows wrapper for the server-like WSL startup path.
# Chat LLM is native LM Studio on Windows; Docker services run inside WSL.
# Run: powershell -ExecutionPolicy Bypass -File .\start-all.ps1

param(
    [switch]$NoBuild,
    [switch]$SkipGpuTest,
    [switch]$SkipFunctional,
    [string]$EnvFile = ".env",
    [string]$Distro = "",
    [string]$LinuxProjectDir = "~/sci-assistant",
    [switch]$NoKeepAlive
)

$ErrorActionPreference = "Stop"

function Get-WslDistros {
    try {
        $raw = & wsl.exe -l -q 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($raw | ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    } catch {
        return @()
    }
}

function Select-WslDistro([string[]]$Distros, [string]$Requested) {
    $userDistros = @($Distros | Where-Object { $_ -and $_ -notin @('docker-desktop', 'docker-desktop-data') })
    if ($Requested) {
        if ($Distros -contains $Requested) { return $Requested }
        throw "Requested WSL distro '$Requested' was not found."
    }
    if ($userDistros.Count -eq 0) { throw "No user WSL distros detected." }
    if ($userDistros.Count -eq 1) { return $userDistros[0] }

    Write-Host "Choose WSL distro:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $userDistros.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $userDistros[$i])
    }
    while ($true) {
        $answer = Read-Host "Enter distro number, distro name, or empty to cancel"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        $trim = $answer.Trim()
        $num = 0
        if ([int]::TryParse($trim, [ref]$num) -and $num -ge 1 -and $num -le $userDistros.Count) {
            return $userDistros[$num - 1]
        }
        $match = @($userDistros | Where-Object { $_ -ieq $trim })
        if ($match.Count -gt 0) { return $match[0] }
        Write-Host "Invalid choice: $trim" -ForegroundColor Yellow
    }
}

function Quote-BashPath([string]$Value) {
    $dq = [string][char]34
    $bs = [string][char]92
    if ($Value -eq '~') { return $dq + '$HOME' + $dq }
    if ($Value.StartsWith('~/')) {
        $rest = $Value.Substring(1)
        $rest = $rest.Replace($bs, $bs + $bs).Replace($dq, $bs + $dq)
        return $dq + '$HOME' + $rest + $dq
    }
    return $dq + $Value.Replace($bs, $bs + $bs).Replace($dq, $bs + $dq) + $dq
}

function Test-WslKeepAlive([string]$DistroName) {
    $needle = "-d $DistroName --exec tail -f /dev/null"
    $matches = @(Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'wsl.exe' -and $_.CommandLine -like "*$needle*" })
    return $matches.Count -gt 0
}

function Start-WslKeepAlive([string]$DistroName) {
    if (Test-WslKeepAlive $DistroName) {
        Write-Host "WSL keepalive already running for $DistroName." -ForegroundColor Gray
        return
    }
    Start-Process -FilePath "$env:SystemRoot\System32\wsl.exe" `
        -ArgumentList @('-d', $DistroName, '--exec', 'tail', '-f', '/dev/null') `
        -WindowStyle Hidden
    Start-Sleep -Seconds 2
    Write-Host "WSL keepalive started for $DistroName." -ForegroundColor Green
}

function Invoke-WslBash([string]$DistroName, [string]$Command) {
    & wsl.exe -d $DistroName -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed in $DistroName" }
}

Write-Host "Scientific assistant WSL start helper" -ForegroundColor Cyan
Write-Host "Target Linux path: $LinuxProjectDir"
Write-Host "This uses native Docker Engine inside WSL/server, not Docker Desktop." -ForegroundColor Gray
Write-Host ""

$selectedDistro = Select-WslDistro -Distros (Get-WslDistros) -Requested $Distro
if (-not $selectedDistro) {
    Write-Host "No WSL distro selected. Nothing started." -ForegroundColor Yellow
    exit 0
}
Write-Host "Selected WSL distro: $selectedDistro" -ForegroundColor Green

if (-not $NoKeepAlive) {
    Start-WslKeepAlive $selectedDistro
} else {
    Write-Host "WSL keepalive skipped. If WSL exits, all native Docker containers will stop." -ForegroundColor Yellow
}

$dirQuoted = Quote-BashPath $LinuxProjectDir
$args = @()
if ($NoBuild) { $args += '--no-build' }
if ($SkipGpuTest) { $args += '--skip-gpu-test' }
if ($SkipFunctional) { $args += '--skip-functional' }
if ($EnvFile -ne '.env') { $args += @('--env-file', $EnvFile) }
$linuxArgs = ($args | ForEach-Object { "'" + ($_ -replace "'", "'\''") + "'" }) -join ' '

Invoke-WslBash $selectedDistro "cd $dirQuoted && ./start-all.sh $linuxArgs"

Write-Host ""
Write-Host "start-all.ps1 finished." -ForegroundColor Green
