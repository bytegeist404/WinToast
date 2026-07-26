#Requires -Version 5.1
#Requires -Modules BurntToast, Microsoft.WinGet.Client

# Checks for WinGet package updates and shows a toast notification if any are found.
#
# The notification includes an "Update All" button that upgrades every updatable
# package elevated, in a visible PowerShell window, after a single UAC prompt -- see
# the comment above $elevateScript below for why it needs to be elevated at all.
# Buttons need a registered custom URI protocol to work, because this script exits
# right after showing the toast and the button may be clicked long after that --
# BurntToast's -ActivatedAction only works while the creating process is still
# alive, so it can't be used here.
#
# Package IDs listed in exclude.txt, next to this script, are left out of both the
# notification and "Update All" -- see the comment above $excludeFilePath below.
#
# Dependencies (enforced by the #Requires statements above; PowerShell refuses
# to run this script if either is missing):
#   Install-Module BurntToast -Scope CurrentUser
#   Install-Module Microsoft.WinGet.Client -Scope CurrentUser

$ErrorActionPreference = 'Stop'

Import-Module BurntToast
Import-Module Microsoft.WinGet.Client

$protocolScheme = 'wintoast'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# Package IDs listed here (one per line, '#' comments allowed) are simply left out
# of $packageIds below, so WinToast never mentions or touches them. This is a plain
# ID filter, not a WinGet pin -- nothing gets written to WinGet's own configuration,
# so there's nothing left behind for uninstall.ps1 to clean up.
$excludeFilePath = Join-Path $PSScriptRoot 'exclude.txt'
$excludedIds = @()
if (Test-Path $excludeFilePath) {
    $excludedIds = @(
        Get-Content -Path $excludeFilePath |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

$updatablePackages = @(
    Get-WinGetPackage | Where-Object { $_.IsUpdateAvailable -and $_.Id -and $excludedIds -notcontains $_.Id }
)
$packageNames = @($updatablePackages | Select-Object -ExpandProperty Name) | Sort-Object -Unique
$packageIds = @($updatablePackages | Select-Object -ExpandProperty Id) | Sort-Object -Unique

if ($packageIds.Count -gt 0) {
    # Packages are upgraded one ID at a time instead of via `winget upgrade --all`,
    # because that's the only way to leave specific packages out -- WinGet has no
    # --exclude flag, and pinning was ruled out since it writes state into WinGet's
    # own config that uninstalling WinToast would then need to remember to remove.
    # $packageIds is spliced in as a literal array below because the elevated process
    # this runs in has no $PSScriptRoot of its own (it's launched via -EncodedCommand,
    # not -File) and isn't set up to re-import Microsoft.WinGet.Client just to
    # recompute the same list a second time.
    $packageIdList = ($packageIds | ForEach-Object { "'$_'" }) -join ', '

    $upgradeScript = @"
`$packageIds = @($packageIdList)
"@ + @'

$exitCode = 0
foreach ($id in $packageIds) {
    winget upgrade --id $id --exact --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        $exitCode = $LASTEXITCODE
    }
}

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Host "Upgrade finished with errors (exit code $exitCode)." -ForegroundColor Red
    Read-Host "Press Enter to close this window"
}
'@
    $encodedUpgradeScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($upgradeScript))

    # Upgrades run elevated so that packages whose installers require admin rights
    # don't each pop their own separate UAC/installer prompt -- once the parent
    # process already holds an admin token, winget installs them under it silently
    # instead. Clicking a toast button only ever gets a non-elevated process (that's
    # all ShellExecute-ing a protocol handler can give you), so this wrapper's only
    # job is to immediately relaunch itself elevated via Start-Process -Verb RunAs,
    # trading N per-package prompts for exactly one UAC consent prompt.
    $elevateScript = @"
Start-Process -FilePath '$powershellPath' -Verb RunAs -ArgumentList '-NoProfile', '-EncodedCommand', '$encodedUpgradeScript'
"@
    $encodedElevateScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($elevateScript))
    $handlerCommand = '"{0}" -NoProfile -WindowStyle Hidden -EncodedCommand {1}' -f $powershellPath, $encodedElevateScript

    # Register (or refresh) the "Update All" protocol handler, per-user, no admin
    # required to register -- elevation happens per click instead, above. The upgrade
    # window closes automatically on success; on failure it prints the error and
    # waits for a keypress so it stays open for review. Scripts are passed via
    # -EncodedCommand (base64) rather than -Command, so their quotes don't collide
    # with the registry command-line's own quoting, or with the elevated relaunch's
    # -ArgumentList quoting.
    $classKey = "HKCU:\Software\Classes\$protocolScheme"
    New-Item -Path $classKey -Force -Value 'URL:WinGet Upgrade Notifier Protocol' | Out-Null
    New-ItemProperty -Path $classKey -Name 'URL Protocol' -PropertyType String -Value '' -Force | Out-Null
    New-Item -Path "$classKey\shell\open\command" -Force -Value $handlerCommand | Out-Null

    $maxListed = 10
    $listText = ($packageNames | Select-Object -First $maxListed) -join "`n"
    if ($packageNames.Count -gt $maxListed) {
        $listText += "`n...and $($packageNames.Count - $maxListed) more"
    }

    $updateAllButton = New-BTButton -Content 'Update All' -Arguments "${protocolScheme}:upgrade" -ActivationType Protocol

    New-BurntToastNotification `
        -Text "$($packageNames.Count) package(s) have updates", $listText `
        -Button $updateAllButton
}
