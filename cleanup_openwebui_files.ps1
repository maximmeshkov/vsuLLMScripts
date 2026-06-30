# cleanup_openwebui_files.ps1 - Windows wrapper for Open WebUI file cleanup in WSL.

param(
    [string]$Distro = "Debian",
    [string]$LinuxProjectDir = "~/sci-assistant",
    [string]$Mode = "failed",
    [string]$KnowledgeId = "",
    [string]$KnowledgeName = "",
    [switch]$Apply,
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

function Quote-BashArg([string]$Value) {
    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Convert-ToBashPath([string]$Value) {
    if ($Value -eq "~") { return '$HOME' }
    if ($Value.StartsWith("~/")) { return '$HOME' + $Value.Substring(1) }
    return $Value.TrimEnd("/")
}

$linuxDir = Convert-ToBashPath $LinuxProjectDir
$argsList = @()

switch ($Mode) {
    "failed" { $argsList += "--failed" }
    "orphaned" { $argsList += "--orphaned" }
    "not-in-knowledge" {
        if (-not $KnowledgeId) { throw "-Mode not-in-knowledge requires -KnowledgeId" }
        $argsList += "--not-in-knowledge"
        $argsList += (Quote-BashArg $KnowledgeId)
    }
    "not-in-knowledge-name" {
        if (-not $KnowledgeName) { throw "-Mode not-in-knowledge-name requires -KnowledgeName" }
        $argsList += "--not-in-knowledge-name"
        $argsList += (Quote-BashArg $KnowledgeName)
    }
    default { throw "Unknown -Mode '$Mode'. Use failed, orphaned, not-in-knowledge, or not-in-knowledge-name." }
}

if ($Apply) { $argsList += "--apply" }
if ($Yes) { $argsList += "--yes" }

$command = "cd `"$linuxDir`" && ./cleanup_openwebui_files.sh " + ($argsList -join " ")

& wsl.exe -d $Distro -- bash -lc $command
if ($LASTEXITCODE -ne 0) { throw "cleanup_openwebui_files.sh failed in $Distro" }
