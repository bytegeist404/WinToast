#Requires -Version 5.1
#Requires -Modules BurntToast, Microsoft.WinGet.Client

# Checks for WinGet package updates and shows a toast notification if any are found.
#
# The notification includes an "Update All" button that runs `winget upgrade --all`
# in a visible PowerShell window. Buttons need a registered custom URI protocol to
# work, because this script exits right after showing the toast and the button may
# be clicked long after that -- BurntToast's -ActivatedAction only works while the
# creating process is still alive, so it can't be used here.
#
# Dependencies (enforced by the #Requires statements above; PowerShell refuses
# to run this script if either is missing):
#   Install-Module BurntToast -Scope CurrentUser
#   Install-Module Microsoft.WinGet.Client -Scope CurrentUser

$ErrorActionPreference = 'Stop'

Import-Module BurntToast
Import-Module Microsoft.WinGet.Client

# Register (or refresh) the "Update All" protocol handler, per-user, no admin required.
# The window closes automatically on success; on failure it prints the error and
# waits for a keypress so it stays open for review. The script is passed via
# -EncodedCommand (base64) rather than -Command, so its quotes don't collide with
# the registry command-line's own quoting.
$protocolScheme = 'wintoast'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$upgradeScript = @'
winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "Upgrade finished with errors (exit code $LASTEXITCODE)." -ForegroundColor Red
    Read-Host "Press Enter to close this window"
}
'@
$encodedUpgradeScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($upgradeScript))
$handlerCommand = '"{0}" -NoProfile -EncodedCommand {1}' -f $powershellPath, $encodedUpgradeScript

$classKey = "HKCU:\Software\Classes\$protocolScheme"
New-Item -Path $classKey -Force -Value 'URL:WinGet Upgrade Notifier Protocol' | Out-Null
New-ItemProperty -Path $classKey -Name 'URL Protocol' -PropertyType String -Value '' -Force | Out-Null
New-Item -Path "$classKey\shell\open\command" -Force -Value $handlerCommand | Out-Null

$packages = @(
    Get-WinGetPackage |
        Where-Object { $_.IsUpdateAvailable } |
        Select-Object -ExpandProperty Name
) | Sort-Object -Unique

if ($packages.Count -gt 0) {
    $maxListed = 10
    $listText = ($packages | Select-Object -First $maxListed) -join "`n"
    if ($packages.Count -gt $maxListed) {
        $listText += "`n...and $($packages.Count - $maxListed) more"
    }

    $updateAllButton = New-BTButton -Content 'Update All' -Arguments "${protocolScheme}:upgrade" -ActivationType Protocol

    New-BurntToastNotification `
        -Text "$($packages.Count) package(s) have updates", $listText `
        -Button $updateAllButton
}
