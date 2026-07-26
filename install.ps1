#Requires -Version 5.1

# One-time setup: installs toast.ps1 to a stable per-user location and registers a
# Scheduled Task that runs it at logon, so you never have to touch Task Scheduler
# by hand. Safe to re-run -- it overwrites the copy and re-registers the task.
#
# Meant to be run either from a local git checkout (./install.ps1, which copies
# the sibling toast.ps1/run-hidden.vbs/uninstall.ps1 files sitting next to it) or
# as a one-liner with no local checkout at all:
#   irm https://raw.githubusercontent.com/bytegeist404/WinToast/v1.0.0/install.ps1 | iex
# In the latter case $PSScriptRoot is empty (there's no backing script file), so
# the sibling files are downloaded from GitHub at the pinned ref below instead.
#
# Runs step by step with progress output, and if any step fails, rolls back
# whatever this run itself created (copied/downloaded files, scheduled task,
# Add/Remove Programs entry) before exiting. It never rolls back
# Install-Module/Install-PackageProvider, since those are shared, per-user
# resources other scripts may depend on -- same reasoning uninstall.ps1 uses for
# leaving them in place.
#
# The whole body below runs inside `& { ... }` so it gets its own scope: Invoke-
# Expression (used by the one-liner above) runs in the *caller's* scope rather
# than a fresh one, and without this wrapper every variable here -- including
# $ErrorActionPreference -- would leak into and permanently alter the user's
# interactive session.
& {
    $ErrorActionPreference = 'Stop'

    # Windows PowerShell 5.1 doesn't always default to TLS 1.2 depending on OS/.NET
    # configuration; GitHub requires it, so set it explicitly before any downloads.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    # DisplayVersion for the Add/Remove Programs entry, and the git tag sibling
    # files are downloaded from when running with no local checkout. Bump both
    # together and tag the release commit to match $ref.
    $wintoastVersion = '1.1.1'
    $ref = 'v1.1.1'
    $repoRawBase = "https://raw.githubusercontent.com/bytegeist404/WinToast/$ref"

    # True only when this script is actually running from a .ps1 file (a local
    # checkout or a double-clicked copy) -- empty when its text came from
    # Invoke-Expression instead, which has no bcking file.
    $isRunningAsFile = [bool]$PSScriptRoot

    $installDir = Join-Path $env:LOCALAPPDATA 'WinToast'
    $installedScript = Join-Path $installDir 'toast.ps1'
    $installedLauncher = Join-Path $installDir 'run-hidden.vbs'
    $installedUninstaller = Join-Path $installDir 'uninstall.ps1'
    $taskName = 'WinToast'
    $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $powershellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinToast'

    $useLocalFiles = $false
    if ($isRunningAsFile) {
        $sourceScript = Join-Path $PSScriptRoot 'toast.ps1'
        $sourceLauncher = Join-Path $PSScriptRoot 'run-hidden.vbs'
        $sourceUninstaller = Join-Path $PSScriptRoot 'uninstall.ps1'
        $useLocalFiles = (Test-Path $sourceScript) -and (Test-Path $sourceLauncher) -and (Test-Path $sourceUninstaller)
    }

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

        Write-Host "[3/5] Installing script files to $installDir..."
        $installDirIsNew = -not (Test-Path $installDir)
        New-Item -Path $installDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        if ($installDirIsNew) {
            Write-Host "      Created $installDir"
            $rollbackActions.Add({ Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue }) | Out-Null
        }
        if ($useLocalFiles) {
            Write-Host '      Running from a local checkout, copying files...'
            Copy-Item -Path $sourceScript -Destination $installedScript -Force -ErrorAction Stop
            Copy-Item -Path $sourceLauncher -Destination $installedLauncher -Force -ErrorAction Stop
            Copy-Item -Path $sourceUninstaller -Destination $installedUninstaller -Force -ErrorAction Stop
        } else {
            Write-Host "      Downloading files from $repoRawBase..."
            Invoke-WebRequest -Uri "$repoRawBase/toast.ps1" -OutFile $installedScript -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri "$repoRawBase/run-hidden.vbs" -OutFile $installedLauncher -UseBasicParsing -ErrorAction Stop
            Invoke-WebRequest -Uri "$repoRawBase/uninstall.ps1" -OutFile $installedUninstaller -UseBasicParsing -ErrorAction Stop
        }
        # Strips Mark-of-the-Web if the files carried it -- otherwise a RemoteSigned
        # execution policy blocks running them as unsigned scripts, even though this
        # copy is now a fully local, trusted file.
        Unblock-File -Path $installedScript, $installedLauncher, $installedUninstaller -ErrorAction Stop
        Write-Host '      Installed toast.ps1, run-hidden.vbs, and uninstall.ps1.'

        # User-editable, so it's only seeded once -- re-running install.ps1 (e.g. to
        # pick up a new version) must never overwrite whatever the user has since
        # written into it.
        $installedExcludeFile = Join-Path $installDir 'exclude.txt'
        if (-not (Test-Path $installedExcludeFile)) {
            Write-Host '      Creating exclude.txt...'
            @'
# WinGet package IDs listed here are skipped by "Update All", one per line.
# Lines starting with '#' are comments and blank lines are ignored. Find a
# package's ID with `winget upgrade`.
#
# Example:
# Microsoft.WSL
'@ | Set-Content -Path $installedExcludeFile -Encoding utf8 -ErrorAction Stop
            Write-Host '      Created exclude.txt.'
        }

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
        # Only exit the process when running as a real script file. Doing this via
        # `iex` in an interactive session means `exit` would close the user's whole
        # PowerShell window instead of just ending this scriptblock.
        if ($isRunningAsFile) {
            exit 1
        } else {
            return
        }
    }
}
