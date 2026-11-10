# Installer tests for Windows: install, update in place, tier switch, -ProfileDir,
# browser registration, refusing foreign folders, uninstall. No browser is started.
#
# Usage: pwsh tests/test_install.ps1 -ZenInstaller path\to\zen.installer.exe [-Extractor auto|7z|tar|7zr]

param(
  [Parameter(Mandatory = $true)] [string] $ZenInstaller,
  [ValidateSet("auto", "7z", "tar", "7zr")] [string] $Extractor = "auto"
)
$ErrorActionPreference = "Stop"
Set-StrictMode -Version 3

$repo = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repo "install.ps1"
$work = Join-Path ([IO.Path]::GetTempPath()) ("zen-lite-test-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$prefix = Join-Path $work "app"
$script:passed = 0

function Fail([string] $m) { throw "FAIL: $m" }
function Ok([string] $m) { $script:passed++; Write-Host "ok $($script:passed) - $m" }
function Run-Installer([hashtable] $extra) {
  $args2 = @{ ZenInstaller = $ZenInstaller; Prefix = $prefix; NoShortcut = $true; Extractor = $Extractor } + $extra
  & $installer @args2 *>&1 | Out-String
}

New-Item -ItemType Directory -Path $work | Out-Null
try {
  # 1. Fresh install.
  $out = Run-Installer @{ Tier = "lite" }
  if (-not (Test-Path (Join-Path $prefix "zen.exe"))) { Fail "zen.exe missing`n$out" }
  foreach ($f in @("defaults\pref\autoconfig.js", "zen-lite.cfg", ".zen-lite-install")) {
    if (-not (Test-Path (Join-Path $prefix $f))) { Fail "$f missing" }
  }
  $prefs = Get-Content (Join-Path $prefix "browser\defaults\preferences\zen-lite-prefs.js") -Raw
  if ($prefs -ne (Get-Content (Join-Path $repo "src\prefs\lite.js") -Raw)) { Fail "lite prefs not installed" }
  if (-not (Select-String -Path (Join-Path $prefix ".zen-lite-install") -Pattern "^tier=lite$" -Quiet)) { Fail "marker lacks tier" }
  Ok "fresh install unpacks Zen and places the Zen Browser Lite files ($Extractor)"

  # 2. Re-run switches tier in place.
  New-Item -ItemType File -Path (Join-Path $prefix "stale-file") | Out-Null
  $out = Run-Installer @{ Tier = "max" }
  $prefs = Get-Content (Join-Path $prefix "browser\defaults\preferences\zen-lite-prefs.js") -Raw
  if ($prefs -ne (Get-Content (Join-Path $repo "src\prefs\max.js") -Raw)) { Fail "max prefs not installed" }
  if (Test-Path (Join-Path $prefix "stale-file")) { Fail "old install folder was not replaced" }
  if (Get-ChildItem $work -Filter "app.old.*" -ErrorAction SilentlyContinue) { Fail "old folder left behind" }
  if ($out -notmatch "site isolation") { Fail "max tier did not warn" }
  Ok "re-running updates in place, switches tier and warns for max"

  # 3. Shortcut, profile and registration.
  $profileDir = Join-Path $work "my profile"
  New-Item -ItemType Directory -Path $profileDir | Out-Null
  Set-Content -Path (Join-Path $profileDir "prefs.js") -Value ""
  $lnkDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
  $lnkPath = Join-Path $lnkDir "Zen Browser Lite.lnk"
  $args3 = @{ ZenInstaller = $ZenInstaller; Prefix = $prefix; ProfileDir = $profileDir; RegisterBrowser = $true; Extractor = $Extractor }
  & $installer @args3 *>&1 | Out-Null
  if (-not (Test-Path $lnkPath)) { Fail "Start menu shortcut missing" }
  $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut($lnkPath)
  if ($lnk.Arguments -ne "-profile `"$profileDir`"") { Fail "shortcut arguments: $($lnk.Arguments)" }
  $cmd = (Get-ItemProperty "HKCU:\Software\Classes\ZenLiteURL\shell\open\command")."(default)"
  if ($cmd -notlike "*zen.exe`" -profile `"$profileDir`" -osint -url `"%1`"") { Fail "URL handler command: $cmd" }
  if (-not (Get-ItemProperty "HKCU:\Software\RegisteredApplications" -Name "Zen Browser Lite" -ErrorAction SilentlyContinue)) { Fail "not registered" }
  Ok "shortcut carries -profile; browser registration writes the URL handler"

  # 4. Bad profile and foreign folders are refused.
  $empty = Join-Path $work "empty"
  New-Item -ItemType Directory -Path $empty | Out-Null
  $threw = $false
  try { & $installer -ZenInstaller $ZenInstaller -Prefix $prefix -ProfileDir $empty -NoShortcut *>&1 | Out-Null } catch { $threw = $_.Exception.Message -like "*does not look like a browser profile*" }
  if (-not $threw) { Fail "accepted a folder that is not a profile" }
  $foreign = Join-Path $work "foreign"
  New-Item -ItemType Directory -Path $foreign | Out-Null
  Set-Content -Path (Join-Path $foreign "important.txt") -Value "keep"
  $threw = $false
  try { & $installer -ZenInstaller $ZenInstaller -Prefix $foreign -NoShortcut *>&1 | Out-Null } catch { $threw = $true }
  if (-not $threw) { Fail "installed over a foreign folder" }
  $threw = $false
  try { & $installer -Uninstall -Prefix $foreign *>&1 | Out-Null } catch { $threw = $true }
  if (-not $threw -or -not (Test-Path (Join-Path $foreign "important.txt"))) { Fail "uninstall touched a foreign folder" }
  Ok "bad profiles and foreign folders are refused"

  # 5. Uninstall removes files, shortcut and registration.
  & $installer -Uninstall -Prefix $prefix *>&1 | Out-Null
  if (Test-Path $prefix) { Fail "install folder still there" }
  if (Test-Path $lnkPath) { Fail "shortcut still there" }
  if (Test-Path "HKCU:\Software\Clients\StartMenuInternet\ZenBrowserLite") { Fail "registration still there" }
  if (Test-Path $profileDir) { } else { Fail "uninstall removed the profile" }
  Ok "uninstall removes the app, shortcut and registration and keeps profiles"

  Write-Host "PASS: $($script:passed) installer checks"
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
