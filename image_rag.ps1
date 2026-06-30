# image_rag.ps1 - Windows wrapper for the visual/image RAG tool server inside WSL.

param(
    [ValidateSet("Health", "Index", "Search")]
    [string]$Action = "Health",
    [string]$Distro = "Debian",
    [string]$LinuxProjectDir = "~/sci-assistant",
    [string]$Query = "",
    [int]$Limit = 5,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Convert-ToBashScriptPath([string]$Value) {
    if ($Value.StartsWith('~/')) {
        return '$HOME' + $Value.Substring(1) + '/image_rag.sh'
    }
    return $Value.TrimEnd('/') + '/image_rag.sh'
}

$scriptPath = Convert-ToBashScriptPath $LinuxProjectDir
$argsList = @($Action.ToLowerInvariant())

if ($Action -eq "Search") {
    if ([string]::IsNullOrWhiteSpace($Query)) {
        throw "Search requires -Query"
    }
    $argsList += $Query
    $argsList += $Limit.ToString()
}

if ($Action -eq "Index" -and $Force) {
    $argsList += "--force"
}

$quotedArgs = ($argsList | ForEach-Object {
    "'" + ($_ -replace "'", "'\''") + "'"
}) -join " "

$linuxCommand = 'exec "' + $scriptPath + '" ' + $quotedArgs
wsl.exe -d "$Distro" -- bash -lc $linuxCommand
