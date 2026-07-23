# WinToast

## Overview

This project is a lightweight PowerShell script that runs when the user logs into Windows and checks for software updates using **WinGet**. If one or more packages have updates available, it displays a Windows toast notification (via **BurntToast**) listing the packages, with an **Update All** button to install every available update.

The goal is to provide a simple, non-intrusive reminder that updates are available without automatically installing them.

---

## Features

- Checks installed WinGet packages for available updates via `Get-WinGetPackage`.
- Displays a toast notification only when updates are available.
- Shows the number of packages that can be updated and lists their names.
- **Update All** button on the notification runs `winget upgrade --all`; the window closes itself on success and stays open (with the error shown) if anything fails.
- Installs itself: `install.ps1` registers a Scheduled Task that runs the check at logon, so there's nothing to set up by hand in Task Scheduler.
- Installable via a local winget manifest, and shows up in Settings > Apps / `winget uninstall` for easy removal.

Example notification:

```text
3 packages have updates

PowerToys
Visual Studio Code
RipGrep MSVC

[Update All]
```

---

## Requirements

- Windows 10 or Windows 11
- WinGet
- PowerShell 5.1 or PowerShell 7+
- **BurntToast** and **Microsoft.WinGet.Client** PowerShell modules

`toast.ps1` declares both modules with `#Requires -Modules`, so PowerShell refuses to run it (with a clear error naming what's missing) if either isn't installed. `install.ps1` installs them for you, or you can do it manually:

```powershell
Install-Module BurntToast -Scope CurrentUser
Install-Module Microsoft.WinGet.Client -Scope CurrentUser
```

---

## Installation

```powershell
git clone <this-repo-url>
cd WinToast
./install.ps1
```

`install.ps1`:

1. Installs the BurntToast and Microsoft.WinGet.Client modules if they're missing.
2. Copies `toast.ps1`, `run-hidden.vbs`, and `uninstall.ps1` to `%LOCALAPPDATA%\WinToast\`.
3. Registers a Scheduled Task (`WinToast`) that runs `run-hidden.vbs` (which launches `toast.ps1` with no visible window) at your next logon.
4. Registers an Add/Remove Programs entry, so it also shows up in Settings > Apps and can be removed with `winget uninstall WinToast` (see below) as well as `uninstall.ps1`.

It's safe to re-run — it overwrites the copy and re-registers the task, so pulling repo updates and re-running `install.ps1` is how you pick up changes.

To check for updates immediately instead of waiting for your next login:

```powershell
& "$env:LOCALAPPDATA\WinToast\toast.ps1"
```

### Install via winget (local manifest)

winget can't install directly from a git repo, but a local manifest lets you install without adding any source or publishing anywhere public:

```powershell
git clone <this-repo-url>
cd WinToast
winget install --manifest .\winget\manifests\b\bytegeist404\WinToast\1.0.0\
```

`winget upgrade` won't discover new versions on its own, since a local manifest isn't tied to any source it can poll — apply a newer version yourself once it exists:

```powershell
winget upgrade --manifest .\winget\manifests\b\bytegeist404\WinToast\<new-version>\
```

#### Releasing a new winget version

1. Copy `winget\manifests\b\bytegeist404\WinToast\1.0.0\` to a new `<version>` folder and bump `PackageVersion`/`DisplayVersion` in all three files.
2. `winget\build.ps1 -Version <version>` — compiles `install.ps1` into an exe (stamping its `$wintoastVersion` with `<version>` so the Add/Remove Programs entry matches) and packages `dist\WinToast-<version>.zip`, printing its SHA256.
3. Upload that zip as a GitHub Release asset tagged `v<version>`.
4. Fill the release's asset URL and the printed SHA256 into the new folder's `bytegeist404.WinToast.installer.yaml`.
5. `winget validate --manifest .\winget\manifests\b\bytegeist404\WinToast\<version>\`, then `winget upgrade --manifest ...` to apply it.

### Uninstall

```powershell
./uninstall.ps1
```

or, if installed via winget:

```powershell
winget uninstall WinToast
```

Both remove the scheduled task, the `Update All` protocol handler, the Add/Remove Programs entry, and the installed copy of the script. They leave the BurntToast/Microsoft.WinGet.Client modules in place in case other scripts use them.

---

## How it works

1. The scheduled task runs `run-hidden.vbs`, a small VBScript wrapper that launches `toast.ps1` via `WScript.Shell.Run(..., 0, False)`. This hides the console window at process creation, which is more reliable than passing `powershell.exe -WindowStyle Hidden` directly -- that flag is ignored on Windows 11 when Windows Terminal is set as the default terminal app, leaving a visible window at logon.
2. `Get-WinGetPackage` (from `Microsoft.WinGet.Client`) lists installed packages; ones with `IsUpdateAvailable -eq $true` become the notification's package list.
3. If any are found, `New-BurntToastNotification` shows the count and names, plus an "Update All" button.
4. Clicking that button needs to work even though `toast.ps1` has already exited by the time you click it — so instead of BurntToast's `-ActivatedAction` (which only works while the triggering process is still alive), the script registers a `wintoast:` custom URI protocol handler under `HKCU\Software\Classes` (no admin rights needed). The button's `-ActivationType Protocol` triggers that handler, which launches a fresh PowerShell process running `winget upgrade --all --silent --accept-package-agreements --accept-source-agreements`.
5. That upgrade window closes itself automatically if the upgrade succeeds, and stays open with the error printed if it doesn't.

---

## Technologies

- **PowerShell**
- **WinGet**
- **BurntToast** PowerShell module
- **Microsoft.WinGet.Client** PowerShell module
- **Windows Task Scheduler** (registered automatically by `install.ps1`)
- **ps2exe** PowerShell module (build-time only, used by `winget/build.ps1` to compile `install.ps1` into an exe for the winget package)

---

## Testing

To test the notification logic without waiting for a real update:

1. Install an older version of a package from WinGet:

```powershell
winget show BurntSushi.ripgrep.MSVC --versions
winget install BurntSushi.ripgrep.MSVC --version 13.0.0
```

2. Verify that it appears as upgradeable:

```powershell
winget upgrade
```

3. Run the script directly and confirm the toast appears with the package listed:

```powershell
& "$env:LOCALAPPDATA\WinToast\toast.ps1"
```

---

## Future Improvements

- Display package icons in notifications where available.
- Ignore selected packages using a configurable exclusion list.
- Log update history to a text or JSON file.
- Include packages with unknown versions as an optional setting.

---

## Project Goal

Provide a simple, fast, and lightweight reminder that software updates are available without introducing unnecessary background services or automatic updates.
