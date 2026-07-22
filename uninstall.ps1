#Requires -Version 5.1

# Removes everything install.ps1 set up: the scheduled task, the "Update All"
# protocol handler, and the installed copy of toast.ps1. Leaves BurntToast and
# Microsoft.WinGet.Client installed, since other scripts may depend on them.

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'WinToast'
$taskName = 'WinToast'
$protocolScheme = 'wintoast'

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -Path "HKCU:\Software\Classes\$protocolScheme" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host "Removed scheduled task '$taskName', the '$protocolScheme:' protocol handler, and $installDir."
