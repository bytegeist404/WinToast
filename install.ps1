#Requires -Version 5.1

# One-time setup: copies toast.ps1 to a stable per-user location and registers a
# Scheduled Task that runs it at logon, so you never have to touch Task Scheduler
# by hand. Safe to re-run -- it overwrites the copy and re-registers the task.
#
# Runs step by step with progress output, and if any step fails, rolls back
# whatever this run itself created (copied files, scheduled task, Add/Remove
# Programs entry) before exiting with a non-zero exit code. It never rolls back
# Install-Module/Install-PackageProvider, since those are shared, per-user
# resources other scripts may depend on -- same reasoning uninstall.ps1 uses for
# leaving them in place.

param(
    # Accepted so winget has a real switch to pass for a silent install; the script
    # already runs fully unattended either way, so this doesn't change behavior.
    [switch]$Silent
)

$ErrorActionPreference = 'Stop'

# Used as the Add/Remove Programs DisplayVersion. winget/build.ps1 stamps this with
# its -Version argument when compiling the winget package, so it always matches the
# release being built; this literal is only the default for a plain git-clone run.
$wintoastVersion = '1.0.0'

# $PSScriptRoot is empty when this script is running as a ps2exe-compiled .exe
# (used for the winget package), so it can't be relied on to find the sibling
# toast.ps1/run-hidden.vbs/uninstall.ps1 files. Falling back to the running
# process's own path covers that case; it still points at this file's folder for
# a plain `.\install.ps1` run from a git clone.
$scriptRoot = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

$installDir = Join-Path $env:LOCALAPPDATA 'WinToast'
$sourceScript = Join-Path $scriptRoot 'toast.ps1'
$installedScript = Join-Path $installDir 'toast.ps1'
$sourceLauncher = Join-Path $scriptRoot 'run-hidden.vbs'
$installedLauncher = Join-Path $installDir 'run-hidden.vbs'
$sourceUninstaller = Join-Path $scriptRoot 'uninstall.ps1'
$installedUninstaller = Join-Path $installDir 'uninstall.ps1'
$taskName = 'WinToast'
$wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
$powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinToast'

# Each entry is a scriptblock that undoes one completed step. Run in reverse order
# on failure. Cmdlets below all pass -ErrorAction Stop explicitly: some of them
# (Install-Module/Install-PackageProvider in particular) are known to write
# non-terminating errors internally that ignore the caller's $ErrorActionPreference,
# which is how a failed run could previously fall through to the "success" messages
# at the bottom of the script.
$rollbackActions = [System.Collections.Generic.List[scriptblock]]::new()

function Invoke-Rollback {
    if ($rollbackActions.Count -eq 0) {
        return
    }
    Write-Host ''
    Write-Host 'Rolling back changes made by this run...' -ForegroundColor Yellow
    for ($i = $rollbackActions.Count - 1; $i -ge 0; $i--) {
        try {
            & $rollbackActions[$i]
        } catch {
            Write-Warning "Rollback step failed, continuing: $_"
        }
    }
}

try {
    Write-Host '[1/5] Checking for NuGet package provider...'
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Write-Host '      Not found, installing...'
        Install-PackageProvider -Name NuGet -Scope CurrentUser -Force -ErrorAction Stop | Out-Null
        Write-Host '      NuGet package provider installed.'
    } else {
        Write-Host '      Already present.'
    }

    Write-Host '[2/5] Checking required PowerShell modules...'
    foreach ($moduleName in 'BurntToast', 'Microsoft.WinGet.Client') {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            Write-Host "      $moduleName not found, installing..."
            Install-Module -Name $moduleName -Scope CurrentUser -Force -ErrorAction Stop
            Write-Host "      $moduleName installed."
        } else {
            Write-Host "      $moduleName already present."
        }
    }

    Write-Host "[3/5] Copying script files to $installDir..."
    $installDirIsNew = -not (Test-Path $installDir)
    New-Item -Path $installDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
    if ($installDirIsNew) {
        Write-Host "      Created $installDir"
        $rollbackActions.Add({ Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue }) | Out-Null
    }
    Copy-Item -Path $sourceScript -Destination $installedScript -Force -ErrorAction Stop
    Copy-Item -Path $sourceLauncher -Destination $installedLauncher -Force -ErrorAction Stop
    Copy-Item -Path $sourceUninstaller -Destination $installedUninstaller -Force -ErrorAction Stop
    # Strips Mark-of-the-Web if the source files carried it (e.g. extracted from a
    # zip downloaded by winget, or the repo downloaded as a zip instead of git
    # cloned) -- otherwise a RemoteSigned execution policy blocks running them as
    # unsigned scripts, even though this copy is now a fully local, trusted file.
    Unblock-File -Path $installedScript, $installedLauncher, $installedUninstaller -ErrorAction Stop
    Write-Host '      Copied toast.ps1, run-hidden.vbs, and uninstall.ps1.'

    Write-Host "[4/5] Registering scheduled task '$taskName'..."
    # Launched via wscript.exe rather than powershell.exe directly: powershell's own
    # -WindowStyle Hidden flag is unreliable on Windows 11 when Windows Terminal is set
    # as the default terminal app, so the window shows up anyway. run-hidden.vbs hides
    # the window at process creation instead, which isn't affected by that setting.
    $action = New-ScheduledTaskAction -Execute $wscriptPath `
        -Argument "`"$installedLauncher`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

    $taskExisted = [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal `
        -Description 'Checks for WinGet package updates at logon and shows a toast notification.' `
        -Force -ErrorAction Stop | Out-Null
    if (-not $taskExisted) {
        $rollbackActions.Add({ Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }) | Out-Null
    }
    Write-Host '      Scheduled task registered.'

    Write-Host '[5/5] Registering Add/Remove Programs entry...'
    # Lets Windows (and winget) discover how to uninstall WinToast: `winget uninstall`
    # and Settings > Apps both work by reading UninstallString from an Add/Remove
    # Programs registry entry and running it, the same mechanism any non-MSI installer
    # uses. Points at the copy of uninstall.ps1 in $installDir rather than this
    # script's own location, since that copy is guaranteed to stick around.
    $uninstallCommand = "`"$powershellPath`" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$installedUninstaller`""
    $uninstallKeyExisted = Test-Path $uninstallKey
    New-Item -Path $uninstallKey -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'DisplayName' -PropertyType String -Value 'WinToast' -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'Publisher' -PropertyType String -Value 'bytegeist404' -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'DisplayVersion' -PropertyType String -Value $wintoastVersion -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -PropertyType String -Value $installDir -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'UninstallString' -PropertyType String -Value $uninstallCommand -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'QuietUninstallString' -PropertyType String -Value $uninstallCommand -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'NoModify' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -Path $uninstallKey -Name 'NoRepair' -PropertyType DWord -Value 1 -Force -ErrorAction Stop | Out-Null
    if (-not $uninstallKeyExisted) {
        $rollbackActions.Add({ Remove-Item -Path $uninstallKey -Recurse -Force -ErrorAction SilentlyContinue }) | Out-Null
    }
    Write-Host '      Add/Remove Programs entry registered.'

    Write-Host ''
    Write-Host "Installed to $installedScript"
    Write-Host "Scheduled task '$taskName' registered to run at your next logon."
    Write-Host "To run a check right now: & '$installedScript'"
} catch {
    Write-Host ''
    Write-Host "Install failed: $_" -ForegroundColor Red
    Invoke-Rollback
    exit 1
}
