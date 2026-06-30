# watch_logs.ps1 - open a visible Windows terminal with live WSL/Docker logs.

param(
    [string]$Distro = "Debian",
    [string]$LinuxProjectDir = "~/sci-assistant",
    [string[]]$Services = @()
)

$ErrorActionPreference = "Stop"

function Convert-ToBashScriptPath([string]$Value) {
    if ($Value.StartsWith('~/')) {
        return '$HOME' + $Value.Substring(1) + '/watch_logs.sh'
    }
    return $Value.TrimEnd('/') + '/watch_logs.sh'
}

$scriptPath = Convert-ToBashScriptPath $LinuxProjectDir

$serviceArgs = ""
foreach ($service in $Services) {
    if ($service -notmatch '^[A-Za-z0-9_.-]+$') {
        throw "Invalid service name '$service'. Use compose service names like open-webui, mineru, infinity, mcpo, image-rag."
    }
    $serviceArgs += " " + $service
}

$linuxCommand = 'exec "' + $scriptPath + '"' + $serviceArgs

Start-Process -FilePath "powershell.exe" -ArgumentList @(
    "-NoExit",
    "-Command",
    "& wsl.exe -d `"$Distro`" -- bash -lc '$linuxCommand'"
)

Write-Host "Opened visible log window for ${Distro}:$LinuxProjectDir" -ForegroundColor Green
