# setup_all.ps1 - interactive setup orchestrator for Windows + WSL.
# It asks before every mutating action.

param(
    [string]$Distro = "",
    [string]$LinuxProjectDir = "~/sci-assistant"
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $here

function Ask-YesNo([string]$Question, [bool]$Default = $false) {
    $suffix = if ($Default) { "[Y/n]" } else { "[y/N]" }
    while ($true) {
        $answer = Read-Host "$Question $suffix"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Host "Please answer y/n." -ForegroundColor Yellow }
        }
    }
}

function Test-CommandExists([string]$Command) {
    return [bool](Get-Command $Command -ErrorAction SilentlyContinue)
}

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
        Write-Host "Requested WSL distro '$Requested' was not found." -ForegroundColor Yellow
        if (Ask-YesNo "Install '$Requested' now with 'wsl --install -d $Requested'?" $false) {
            & wsl.exe --install -d $Requested
            Write-Host "Finish first-run distro setup if Windows opens it, then rerun setup_all.ps1." -ForegroundColor Yellow
            exit 0
        }
    }

    if ($userDistros.Count -eq 0) {
        Write-Host "No user WSL distros detected." -ForegroundColor Yellow
        if (Ask-YesNo "Install Debian now with 'wsl --install -d Debian'?" $false) {
            & wsl.exe --install -d Debian
            Write-Host "Finish first-run Debian setup, then rerun setup_all.ps1." -ForegroundColor Yellow
            exit 0
        }
        return $null
    }

    if ($userDistros.Count -eq 1) {
        $only = $userDistros[0]
        if (Ask-YesNo "Use WSL distro '$only'?" $true) { return $only }
        return $null
    }

    Write-Host ""
    Write-Host "Choose WSL distro:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $userDistros.Count; $i++) {
        Write-Host ("  {0}. {1}" -f ($i + 1), $userDistros[$i])
    }

    while ($true) {
        $answer = Read-Host "Enter distro number, distro name, or empty to cancel"
        if ([string]::IsNullOrWhiteSpace($answer)) { return $null }
        $trim = $answer.Trim()
        $number = 0
        if ([int]::TryParse($trim, [ref]$number)) {
            if ($number -ge 1 -and $number -le $userDistros.Count) { return $userDistros[$number - 1] }
        }
        $match = @($userDistros | Where-Object { $_ -ieq $trim })
        if ($match.Count -gt 0) { return $match[0] }
        Write-Host "Invalid choice." -ForegroundColor Yellow
    }
}

function Convert-ToWslPath([string]$WindowsPath) {
    $full = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        $drive = $matches[1].ToLowerInvariant()
        $rest = $matches[2] -replace '\\', '/'
        return "/mnt/$drive/$rest"
    }
    throw "Cannot convert path to WSL path: $WindowsPath"
}

function Quote-BashDouble([string]$Value) {
    $dq = [string][char]34
    $bs = [string][char]92
    $dollar = [string][char]36
    $bt = [string][char]96
    $escaped = $Value.Replace($bs, $bs + $bs).Replace($dq, $bs + $dq).Replace($dollar, $bs + $dollar).Replace($bt, $bs + $bt)
    return $dq + $escaped + $dq
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
    return Quote-BashDouble $Value
}

function Invoke-WslBash([string]$DistroName, [string]$Command) {
    & wsl.exe -d $DistroName -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) { throw "WSL command failed in $DistroName" }
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

Write-Host "Scientific assistant interactive setup" -ForegroundColor Cyan
Write-Host "Project: $here"
Write-Host "Target Linux path: $LinuxProjectDir"
Write-Host ""
Write-Host "This script asks before each mutating action." -ForegroundColor Gray

Write-Host ""
Write-Host "Server-like setup: Docker is configured and checked only inside WSL." -ForegroundColor Gray

$distros = Get-WslDistros
Write-Host ""
Write-Host "Installed WSL distros:" -ForegroundColor Cyan
if ($distros.Count -eq 0) {
    Write-Host "  none detected" -ForegroundColor Yellow
} else {
    $distros | ForEach-Object { Write-Host "  $_" }
}

$selectedDistro = Select-WslDistro -Distros $distros -Requested $Distro
if (-not $selectedDistro) {
    Write-Host "No WSL distro selected. Stopping setup." -ForegroundColor Yellow
    exit 0
}

Write-Host "Selected WSL distro: $selectedDistro" -ForegroundColor Green

if (Ask-YesNo "Keep WSL distro '$selectedDistro' alive while the assistant stack is running?" $true) {
    Start-WslKeepAlive $selectedDistro
} else {
    Write-Host "WSL keepalive skipped. If WSL exits, native Docker containers inside it will stop." -ForegroundColor Yellow
}

if (Ask-YesNo "Copy/sync this project into $selectedDistro at $LinuxProjectDir?" $true) {
    $src = Convert-ToWslPath $here
    $srcQuoted = Quote-BashDouble $src
    $destQuoted = Quote-BashPath $LinuxProjectDir
    $excludeArgs = "--exclude='./.env' --exclude='./data' --exclude='./mcp-data' --exclude='./papers' --exclude='./.git' --exclude='./.venv' --exclude='./venv' --exclude='./node_modules' --exclude='./__pycache__'"
    $copyCommand = "mkdir -p $destQuoted && cd $srcQuoted && tar $excludeArgs -cf - . | tar -xf - -C $destQuoted && chmod +x $destQuoted/start-all.sh $destQuoted/setup_all.sh $destQuoted/stop-all.sh $destQuoted/doctor.sh $destQuoted/watch_logs.sh $destQuoted/cleanup_openwebui_files.sh"
    Invoke-WslBash $selectedDistro $copyCommand
    Write-Host "Project copied to ${selectedDistro}:$LinuxProjectDir" -ForegroundColor Green
}

if (Ask-YesNo "Run Linux-side interactive setup inside $selectedDistro now?" $true) {
    $dirQuoted = Quote-BashPath $LinuxProjectDir
    Invoke-WslBash $selectedDistro "cd $dirQuoted && ./setup_all.sh"
} else {
    Write-Host "Later, run:" -ForegroundColor Gray
    Write-Host "  wsl -d $selectedDistro"
    Write-Host "  cd $LinuxProjectDir"
    Write-Host "  ./setup_all.sh"
}

Write-Host ""
Write-Host "setup_all.ps1 finished." -ForegroundColor Green
