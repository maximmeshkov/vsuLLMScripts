# stop_all.ps1 - Windows wrapper for stopping the server-like WSL Docker stack.

param(
    [string]$Distro = "",
    [string]$LinuxProjectDir = "~/sci-assistant"
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
        if ($userDistros -contains $trim) { return $trim }
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

function Invoke-WslBash([string]$DistroName, [string]$Command) {
    & wsl.exe -d $DistroName -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed in $DistroName" }
}

function Stop-WslKeepAlive([string]$DistroName) {
    $needle = "-d $DistroName --exec tail -f /dev/null"
    $matches = @(Get-CimInstance Win32_Process |
        Where-Object { $_.Name -eq 'wsl.exe' -and $_.CommandLine -like "*$needle*" })
    if ($matches.Count -eq 0) {
        Write-Host "No WSL keepalive process found for $DistroName." -ForegroundColor Gray
        return
    }
    foreach ($proc in $matches) {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Stopped WSL keepalive for $DistroName." -ForegroundColor Green
}

Write-Host "Scientific assistant stop helper" -ForegroundColor Cyan
Write-Host "Target Linux path: $LinuxProjectDir"
Write-Host "This targets native Docker Engine inside WSL/server, not Docker Desktop." -ForegroundColor Gray
Write-Host ""

$distros = Get-WslDistros
$selectedDistro = Select-WslDistro -Distros $distros -Requested $Distro
if (-not $selectedDistro) {
    Write-Host "No WSL distro selected. Nothing stopped." -ForegroundColor Yellow
    exit 0
}
Write-Host "Selected WSL distro: $selectedDistro" -ForegroundColor Green
Write-Host ""
Write-Host "Choose action:" -ForegroundColor Cyan
Write-Host "  1. stop containers only (non-destructive)"
Write-Host "  2. down: remove containers and network, keep data/volumes"
Write-Host "  3. down -v: remove containers, network, and compose volumes"
Write-Host "  4. status only"
Write-Host "  5. stop native Docker daemon only"
Write-Host "  6. wsl --shutdown (stops all WSL distros)"
Write-Host "  7. stop WSL keepalive for selected distro"

$choice = Read-Host "Enter action number, or empty to cancel"
if ([string]::IsNullOrWhiteSpace($choice)) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    exit 0
}

$dirQuoted = Quote-BashPath $LinuxProjectDir
switch ($choice.Trim()) {
    '1' { Invoke-WslBash $selectedDistro "cd $dirQuoted && ./stop-all.sh --stop" }
    '2' { Invoke-WslBash $selectedDistro "cd $dirQuoted && ./stop-all.sh --down" }
    '3' {
        $confirm = Read-Host "Type DELETE to remove compose volumes"
        if ($confirm -ne 'DELETE') { Write-Host "Cancelled destructive action." -ForegroundColor Yellow; exit 0 }
        Invoke-WslBash $selectedDistro "cd $dirQuoted && ./stop-all.sh --volumes"
    }
    '4' { Invoke-WslBash $selectedDistro "cd $dirQuoted && ./stop-all.sh --status" }
    '5' { Invoke-WslBash $selectedDistro "cd $dirQuoted && ./stop-all.sh --status --stop-docker" }
    '6' {
        $confirm = Read-Host "Type SHUTDOWN to stop all WSL distros"
        if ($confirm -ne 'SHUTDOWN') { Write-Host "Cancelled WSL shutdown." -ForegroundColor Yellow; exit 0 }
        & wsl.exe --shutdown
        if ($LASTEXITCODE -ne 0) { throw "wsl --shutdown failed" }
    }
    '7' { Stop-WslKeepAlive $selectedDistro }
    default { Write-Host "Unknown action: $choice" -ForegroundColor Yellow; exit 2 }
}

Write-Host "stop_all.ps1 finished." -ForegroundColor Green
