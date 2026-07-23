#Requires -Version 5.1

# Builds the winget-installable package: compiles install.ps1 into an .exe (via
# the ps2exe module) and zips it up with the files it needs at install time --
# toast.ps1, run-hidden.vbs, uninstall.ps1 -- into dist/WinToast-<version>.zip.
#
# install.ps1 locates those three files relative to its own running location
# (falling back off $PSScriptRoot, which ps2exe leaves empty, to the compiled
# exe's own path), so it works identically whether that's this repo's checkout
# or winget's extracted temp folder, as long as the four files sit side by side --
# which is exactly what this zip layout gives it.
#
# Also stamps install.ps1's $wintoastVersion with -Version before compiling, so
# the Add/Remove Programs entry it registers always matches the release being
# built rather than relying on install.ps1's checked-in default staying in sync.
#
# Run this, then paste the printed SHA256 and the URL you upload the zip to into
# winget/manifests/.../bytegeist404.WinToast.installer.yaml.

param(
    [Parameter(Mandatory)]
    [string]$Version
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$distDir = Join-Path $repoRoot 'dist'
$exePath = Join-Path $distDir 'WinToastInstall.exe'
$zipPath = Join-Path $distDir "WinToast-$Version.zip"

Write-Host '[1/3] Checking for the ps2exe module...'
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host '      Not found, installing...'
    Install-Module -Name ps2exe -Scope CurrentUser -Force -ErrorAction Stop
    Write-Host '      ps2exe installed.'
} else {
    Write-Host '      Already present.'
}

Write-Host "[2/3] Compiling install.ps1 -> $exePath..."
New-Item -Path $distDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
Remove-Item -Path $exePath -Force -ErrorAction SilentlyContinue

$versionPattern = '(?m)^\$wintoastVersion = ''[^'']*''$'
$rawInstallScript = Get-Content -Path (Join-Path $repoRoot 'install.ps1') -Raw
if ($rawInstallScript -notmatch $versionPattern) {
    throw "Could not find `$wintoastVersion assignment in install.ps1 to stamp with version $Version."
}
$stampedInstallScript = $rawInstallScript -replace $versionPattern, "`$wintoastVersion = '$Version'"
$stagedInstallScript = Join-Path $distDir 'install.ps1'
Set-Content -Path $stagedInstallScript -Value $stampedInstallScript -NoNewline -ErrorAction Stop

Invoke-ps2exe -InputFile $stagedInstallScript -OutputFile $exePath `
    -Title 'WinToast Installer' -Version $Version -Product 'WinToast' -Company 'bytegeist404' `
    -ErrorAction Stop

Write-Host "[3/3] Packaging $zipPath..."
Compress-Archive -Path $exePath, `
    (Join-Path $repoRoot 'toast.ps1'), `
    (Join-Path $repoRoot 'run-hidden.vbs'), `
    (Join-Path $repoRoot 'uninstall.ps1') `
    -DestinationPath $zipPath -Force -ErrorAction Stop

$hash = (Get-FileHash -Path $zipPath -Algorithm SHA256).Hash
Write-Host ''
Write-Host "Built $zipPath"
Write-Host "SHA256: $hash"
Write-Host ''
Write-Host 'Next: upload the zip as a GitHub Release asset, then put its download URL and the SHA256 above into:'
Write-Host "  winget\manifests\b\bytegeist404\WinToast\$Version\bytegeist404.WinToast.installer.yaml"
