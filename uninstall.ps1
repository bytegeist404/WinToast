#Requires -Version 5.1

# Removes everything install.ps1 set up: the scheduled task, the "Update All"
# protocol handler, the Add/Remove Programs entry, and the installed copy of
# toast.ps1. Leaves BurntToast and Microsoft.WinGet.Client installed, since other
# scripts may depend on them.
#
# Runs step by step with progress output. Before removing anything, each step
# backs up what it's about to delete; if a later step fails, everything removed
# so far is restored from those backups and the script exits with a non-zero
# exit code, rather than silently reporting success on a partial removal.
#
# The installed files are removed last on purpose: when this script is invoked
# via the Add/Remove Programs entry (e.g. `winget uninstall`), it's running from
# the copy of uninstall.ps1 inside $installDir, so that step deletes this script's
# own file. That's a safe, well-established pattern on Windows -- PowerShell has
# already parsed the whole script before running it -- but doing it last keeps
# any step that could still fail from depending on the file existing afterward.

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'WinToast'
$taskName = 'WinToast'
$protocolScheme = 'wintoast'
$classKey = "HKCU:\Software\Classes\$protocolScheme"
$classKeyRegPath = "HKCU\Software\Classes\$protocolScheme"
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinToast'
$uninstallKeyRegPath = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\WinToast'
$regExePath = Join-Path $env:SystemRoot 'System32\reg.exe'

$protocolBackupFile = Join-Path $env:TEMP "WinToast-uninstall-$PID-protocol.reg"
$uninstallKeyBackupFile = Join-Path $env:TEMP "WinToast-uninstall-$PID-arp.reg"
$installDirBackup = Join-Path $env:TEMP "WinToast-uninstall-$PID-files"

$rollbackActions = [System.Collections.Generic.List[scriptblock]]::new()

function Invoke-Rollback {
    if ($rollbackActions.Count -eq 0) {
        return
    }
    Write-Host ''
    Write-Host 'Restoring what this run removed...' -ForegroundColor Yellow
    for ($i = $rollbackActions.Count - 1; $i -ge 0; $i--) {
        try {
            & $rollbackActions[$i]
        } catch {
            Write-Warning "Rollback step failed, continuing: $_"
        }
    }
}

try {
    Write-Host "[1/4] Scheduled task '$taskName'..."
    $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if ($task) {
        Write-Host '      Found, backing up definition and removing...'
        $taskXml = Export-ScheduledTask -TaskName $taskName -ErrorAction Stop
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
        $rollbackActions.Add({ Register-ScheduledTask -TaskName $taskName -Xml $taskXml -Force -ErrorAction Stop | Out-Null }) | Out-Null
        Write-Host '      Removed.'
    } else {
        Write-Host '      Not present, skipping.'
    }

    Write-Host "[2/4] '${protocolScheme}:' protocol handler..."
    if (Test-Path $classKey) {
        Write-Host '      Found, backing up and removing...'
        & $regExePath export $classKeyRegPath $protocolBackupFile /y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "reg.exe export failed with exit code $LASTEXITCODE"
        }
        Remove-Item -Path $classKey -Recurse -Force -ErrorAction Stop
        $rollbackActions.Add({
            & $regExePath import $protocolBackupFile | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "reg.exe import failed with exit code $LASTEXITCODE"
            }
        }) | Out-Null
        Write-Host '      Removed.'
    } else {
        Write-Host '      Not present, skipping.'
    }

    Write-Host '[3/4] Add/Remove Programs entry...'
    if (Test-Path $uninstallKey) {
        Write-Host '      Found, backing up and removing...'
        & $regExePath export $uninstallKeyRegPath $uninstallKeyBackupFile /y | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "reg.exe export failed with exit code $LASTEXITCODE"
        }
        Remove-Item -Path $uninstallKey -Recurse -Force -ErrorAction Stop
        $rollbackActions.Add({
            & $regExePath import $uninstallKeyBackupFile | Out-Null
            if ($LASTEXITCODE -ne 0) {
                throw "reg.exe import failed with exit code $LASTEXITCODE"
            }
        }) | Out-Null
        Write-Host '      Removed.'
    } else {
        Write-Host '      Not present, skipping.'
    }

    Write-Host "[4/4] Installed files in $installDir..."
    if (Test-Path $installDir) {
        Write-Host '      Found, backing up and removing...'
        Copy-Item -Path $installDir -Destination $installDirBackup -Recurse -Force -ErrorAction Stop
        Remove-Item -Path $installDir -Recurse -Force -ErrorAction Stop
        $rollbackActions.Add({
            Remove-Item -Path $installDir -Recurse -Force -ErrorAction SilentlyContinue
            Move-Item -Path $installDirBackup -Destination $installDir -Force -ErrorAction Stop
        }) | Out-Null
        Write-Host '      Removed.'
    } else {
        Write-Host '      Not present, skipping.'
    }

    Remove-Item -Path $protocolBackupFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $uninstallKeyBackupFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $installDirBackup -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Host "Removed scheduled task '$taskName', the '${protocolScheme}:' protocol handler, the Add/Remove Programs entry, and $installDir."
} catch {
    Write-Host ''
    Write-Host "Uninstall failed: $_" -ForegroundColor Red
    Invoke-Rollback
    Remove-Item -Path $protocolBackupFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $uninstallKeyBackupFile -Force -ErrorAction SilentlyContinue
    Remove-Item -Path $installDirBackup -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
