# WinToast

A lightweight notifier that checks for WinGet updates when you log in to Windows and shows a toast notification with a one-click **Update All**. No background service, no silent auto-updates — just a reminder, on your terms.

## What it does

- Checks your installed WinGet packages for updates at every logon.
- Shows a toast only when updates are actually available, listing the package names.
- **Update All** installs everything with one click: a single admin prompt, then it runs silently and closes itself when done (or stays open if something failed).

Example notification:

```text
3 packages have updates

PowerToys
Visual Studio Code
RipGrep MSVC

[Update All]
```

## Requirements

- Windows 10 or 11 with WinGet
- PowerShell 5.1+ (already on Windows) or PowerShell 7+

Everything else it needs (the BurntToast and Microsoft.WinGet.Client modules) is installed automatically.

## Skipping packages

To keep a package out of **Update All** (for example, one you'd rather update by hand), add its WinGet package ID on its own line in `$env:LOCALAPPDATA\WinToast\exclude.txt`:

```text
Microsoft.WSL
```

It'll still show up in the notification when an update is available -- only the automatic install is skipped.

## Install

```powershell
irm https://raw.githubusercontent.com/bytegeist404/WinToast/v1.1.0/install.ps1 | iex
```

That's it — WinToast will check for updates at your next logon. This pipes a script straight from this repo into PowerShell; if you'd rather look before running it, clone the repo and run `./install.ps1` instead, which does the same thing locally.

To check for updates right now instead of waiting for your next logon:

```powershell
& "$env:LOCALAPPDATA\WinToast\toast.ps1"
```

Re-running the install command is also how you pick up new versions later.

## Uninstall

Any of the following:

```powershell
winget uninstall WinToast
```

```powershell
& "$env:LOCALAPPDATA\WinToast\uninstall.ps1"
```

Or remove it from **Settings > Apps** like any other program.
