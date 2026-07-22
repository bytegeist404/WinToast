#Requires -Version 5.1

# One-time setup: copies toast.ps1 to a stable per-user location and registers a
# Scheduled Task that runs it at logon, so you never have to touch Task Scheduler
# by hand. Safe to re-run -- it overwrites the copy and re-registers the task.

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'WinToast'
$sourceScript = Join-Path $PSScriptRoot 'toast.ps1'
$installedScript = Join-Path $installDir 'toast.ps1'
$taskName = 'WinToast'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Make sure the modules toast.ps1 depends on are present before we register anything.
if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing NuGet package provider...'
    Install-PackageProvider -Name NuGet -Scope CurrentUser -Force | Out-Null
}

foreach ($moduleName in 'BurntToast', 'Microsoft.WinGet.Client') {
    if (-not (Get-Module -ListAvailable -Name $moduleName)) {
        Write-Host "Installing module $moduleName..."
        Install-Module -Name $moduleName -Scope CurrentUser -Force
    }
}

New-Item -Path $installDir -ItemType Directory -Force | Out-Null
Copy-Item -Path $sourceScript -Destination $installedScript -Force

$action = New-ScheduledTaskAction -Execute $powershellPath `
    -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installedScript`""
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
    -Description 'Checks for WinGet package updates at logon and shows a toast notification.' `
    -Force | Out-Null

Write-Host "Installed to $installedScript"
Write-Host "Scheduled task '$taskName' registered to run at your next logon."
Write-Host "To run a check right now: & '$installedScript'"
