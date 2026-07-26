#Requires -Version 5.1
#Requires -Modules BurntToast, Microsoft.WinGet.Client

# Checks for WinGet package updates and shows a toast notification if any are found.
#
# The notification includes an "Update All" button that runs `winget upgrade --all`
# elevated, in a visible PowerShell window, after a single UAC prompt -- see the
# comment above $elevateScript below for why it needs to be elevated at all. Buttons
# need a registered custom URI protocol to work, because this script exits right
# after showing the toast and the button may be clicked long after that --
# BurntToast's -ActivatedAction only works while the creating process is still
# alive, so it can't be used here.
#
# Package IDs listed in exclude.txt, next to this script, are skipped by "Update
# All" -- see the comment above $excludeFilePath below for how.
#
# Dependencies (enforced by the #Requires statements above; PowerShell refuses
# to run this script if either is missing):
#   Install-Module BurntToast -Scope CurrentUser
#   Install-Module Microsoft.WinGet.Client -Scope CurrentUser

$ErrorActionPreference = 'Stop'

Import-Module BurntToast
Import-Module Microsoft.WinGet.Client

# Register (or refresh) the "Update All" protocol handler, per-user, no admin required
# to register -- elevation happens per click instead, below. The upgrade window
# closes automatically on success; on failure it prints the error and waits for a
# keypress so it stays open for review. Scripts are passed via -EncodedCommand
# (base64) rather than -Command, so their quotes don't collide with the registry
# command-line's own quoting, or with the elevated relaunch's -ArgumentList quoting.
$protocolScheme = 'wintoast'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Packages listed here (one WinGet package ID per line, '#' comments allowed) are
# pinned --blocking right before the upgrade runs and unpinned right after, so
# `winget upgrade --all` skips them for just this one run instead of permanently --
# they're still reported as having an update available next time this script checks.
# $excludeFilePath is spliced into $upgradeScript as a literal string below because
# the elevated process it runs in has no $PSScriptRoot of its own (it's launched via
# -EncodedCommand, not -File).
$excludeFilePath = Join-Path $PSScriptRoot 'exclude.txt'

$upgradeScript = @"
`$excludeFilePath = '$excludeFilePath'
"@ + @'

$excludedIds = @()
if (Test-Path $excludeFilePath) {
    $excludedIds = Get-Content -Path $excludeFilePath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') }
}

foreach ($id in $excludedIds) {
    winget pin add --id $id --exact --blocking
}

try {
    winget upgrade --all --silent --accept-package-agreements --accept-source-agreements
    $exitCode = $LASTEXITCODE
} finally {
    foreach ($id in $excludedIds) {
        winget pin remove --id $id --exact
    }
}

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "Upgrade finished with errors (exit code $exitCode)." -ForegroundColor Red
    Read-Host "Press Enter to close this window"
}
'@
$encodedUpgradeScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($upgradeScript))

# winget upgrade --all runs elevated so that packages whose installers require admin
# rights don't each pop their own separate UAC/installer prompt -- once the parent
# process already holds an admin token, winget installs them under it silently
# instead. Clicking a toast button only ever gets a non-elevated process (that's all
# ShellExecute-ing a protocol handler can give you), so this wrapper's only job is to
# immediately relaunch itself elevated via Start-Process -Verb RunAs, trading N
# per-package prompts for exactly one UAC consent prompt.
$elevateScript = @"
Start-Process -FilePath '$powershellPath' -Verb RunAs -ArgumentList '-NoProfile', '-EncodedCommand', '$encodedUpgradeScript'
"@
$encodedElevateScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevateScript))
$handlerCommand = '"{0}" -NoProfile -WindowStyle Hidden -EncodedCommand {1}' -f $powershellPath, $encodedElevateScript

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
