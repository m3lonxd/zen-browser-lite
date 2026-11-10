<#
.SYNOPSIS
  Zen Browser Lite installer for Windows (unofficial).

.DESCRIPTION
  Downloads the official Zen Browser installer from github.com/zen-browser/desktop,
  verifies its SHA-256 against the digest GitHub publishes for the release asset,
  unpacks the browser files from it without running it, installs them to their own
  folder and adds Zen Browser Lite's memory settings and tab unloader. Zen itself is
  not modified or rebuilt. No administrator rights are needed.

  irm https://raw.githubusercontent.com/m3lonxd/zen-browser-lite/main/install.ps1 | iex
  & ([scriptblock]::Create((irm https://raw.githubusercontent.com/m3lonxd/zen-browser-lite/main/install.ps1))) -Tier max
  .\install.ps1 -Uninstall

.PARAMETER Tier
  lite (default) keeps site isolation; max turns it off to save more memory.
.PARAMETER Prefix
  Install folder. Default: %LOCALAPPDATA%\Programs\Zen Browser Lite
.PARAMETER ZenVersion
  Zen release tag to install, e.g. 1.24.1b. Default: latest.
.PARAMETER ZenInstaller
  Use a local zen.installer.exe instead of downloading (not verified).
.PARAMETER ProfileDir
  Always start with this existing profile folder, e.g. a profile of your current Zen
  from %APPDATA%\zen\Profiles.
.PARAMETER NoShortcut
  Do not add a Start menu shortcut.
.PARAMETER RegisterBrowser
  Register Zen Browser Lite as a browser for your account and open Windows' Default
  apps page so you can pick it. Windows does not allow a program to set itself as
  the default silently.
.PARAMETER Uninstall
  Remove Zen Browser Lite. Profiles are kept.
#>
[CmdletBinding()]
param(
  [ValidateSet("lite", "max")] [string] $Tier = "lite",
  [string] $Prefix = (Join-Path $env:LOCALAPPDATA "Programs\Zen Browser Lite"),
  [string] $ZenVersion = "latest",
  [string] $ZenInstaller = "",
  [string] $ProfileDir = "",
  [switch] $NoShortcut,
  [switch] $RegisterBrowser,
  [switch] $Uninstall,
  # Test hook: force one way of unpacking the installer.
  [ValidateSet("auto", "7z", "tar", "7zr")] [string] $Extractor = "auto"
)

Set-StrictMode -Version 3
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # Invoke-WebRequest is very slow with the progress bar on
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$ZenLiteVersion = "0.2.0"
$Repo = "m3lonxd/zen-browser-lite"
$Ref = if ($env:ZENLITE_REF) { $env:ZENLITE_REF } else { "main" }
$MarkerName = ".zen-lite-install"
$AppName = "Zen Browser Lite"
$RegKey = "ZenBrowserLite"
$StartMenu = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs"
$ShortcutPath = Join-Path $StartMenu "$AppName.lnk"
# 7zr.exe 26.06 from the official 7-Zip GitHub releases, used only when neither 7-Zip nor
# tar.exe can unpack the installer. Pinned version and checksum.
$SevenZrUrl = "https://github.com/ip7z/7zip/releases/download/26.06/7zr.exe"
$SevenZrSha256 = "e80db2dad715a6c5adabe292d31ed54e11f4e9b99ca349827b50573b175891bc"

function Say([string] $m) { Write-Host ":: $m" -ForegroundColor Green }
function Warn([string] $m) { Write-Host "warning: $m" -ForegroundColor Yellow }
function Fail([string] $m) { throw "error: $m" }

$Prefix = [IO.Path]::GetFullPath($Prefix)
if ($Prefix.TrimEnd('\') -in @($env:USERPROFILE.TrimEnd('\'), $env:LOCALAPPDATA.TrimEnd('\'), [IO.Path]::GetPathRoot($Prefix).TrimEnd('\'))) {
  Fail "refusing to use $Prefix as the install folder."
}

function Test-Running {
  $exe = Join-Path $Prefix "zen.exe"
  foreach ($p in (Get-Process -Name zen -ErrorAction SilentlyContinue)) {
    try { if ($p.Path -and ($p.Path -ieq $exe)) { return $true } } catch { }
  }
  return $false
}

function Remove-Registration {
  foreach ($k in @("HKCU:\Software\Clients\StartMenuInternet\$RegKey", "HKCU:\Software\Classes\ZenLiteHTML", "HKCU:\Software\Classes\ZenLiteURL")) {
    if (Test-Path $k) { Remove-Item $k -Recurse -Force }
  }
  $reg = "HKCU:\Software\RegisteredApplications"
  if ((Test-Path $reg) -and (Get-ItemProperty $reg -Name $AppName -ErrorAction SilentlyContinue)) {
    Remove-ItemProperty $reg -Name $AppName
  }
}

if ($Uninstall) {
  if (Test-Running) { Fail "$AppName is running. Close it first." }
  if (Test-Path $Prefix) {
    if (-not (Test-Path (Join-Path $Prefix $MarkerName))) { Fail "$Prefix was not installed by $AppName; not removing it." }
    Remove-Item $Prefix -Recurse -Force
    Say "Removed $Prefix"
  }
  if (Test-Path $ShortcutPath) { Remove-Item $ShortcutPath -Force }
  Remove-Registration
  Say "$AppName removed. Browser profiles in $env:APPDATA\zen were not touched."
  return
}

if ($ProfileDir) {
  $ProfileDir = [IO.Path]::GetFullPath($ProfileDir)
  if (-not ((Test-Path (Join-Path $ProfileDir "prefs.js")) -or (Test-Path (Join-Path $ProfileDir "times.json")))) {
    Fail "$ProfileDir does not look like a browser profile folder."
  }
}
if (Test-Running) { Fail "$AppName is running. Close it, then run the installer again." }
if ((Test-Path $Prefix) -and -not (Test-Path (Join-Path $Prefix $MarkerName))) {
  Fail "$Prefix already exists and was not created by $AppName. Choose another -Prefix."
}

$work = Join-Path ([IO.Path]::GetTempPath()) ("zen-lite-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $work | Out-Null
try {
  # --- Zen Browser Lite files: from this checkout, or from GitHub when piped through iex. ---
  $src = Join-Path $work "src"
  New-Item -ItemType Directory -Path (Join-Path $src "prefs") -Force | Out-Null
  $here = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { "" }
  $files = @("zen-lite.cfg", "autoconfig.js", "prefs\$Tier.js")
  if ($here -and (Test-Path (Join-Path $here "src\zen-lite.cfg"))) {
    foreach ($f in $files) { Copy-Item (Join-Path $here "src\$f") (Join-Path $src $f) }
  } else {
    Say "Fetching $AppName files ($Ref)"
    foreach ($f in $files) {
      $url = "https://raw.githubusercontent.com/$Repo/$Ref/src/" + ($f -replace '\\', '/')
      Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile (Join-Path $src $f)
    }
  }
  if (-not (Select-String -Path (Join-Path $src "zen-lite.cfg") -Pattern "zenLiteUnloader" -Quiet)) { Fail "zen-lite.cfg looks wrong." }

  # --- Zen release ---
  $arm = ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") -or ($env:PROCESSOR_ARCHITEW6432 -eq "ARM64")
  $asset = if ($arm) { "zen.installer-arm64.exe" } else { "zen.installer.exe" }
  $releaseTag = "local"
  if ($ZenInstaller) {
    if (-not (Test-Path $ZenInstaller)) { Fail "no such file: $ZenInstaller" }
    $installer = (Resolve-Path $ZenInstaller).Path
    Say "Using local Zen installer $installer (not verified)"
  } else {
    $api = if ($ZenVersion -eq "latest") { "https://api.github.com/repos/zen-browser/desktop/releases/latest" }
           else { "https://api.github.com/repos/zen-browser/desktop/releases/tags/$ZenVersion" }
    Say "Looking up Zen release ($ZenVersion)"
    $release = Invoke-RestMethod -Uri $api -Headers @{ Accept = "application/vnd.github+json"; "User-Agent" = "zen-browser-lite-installer" }
    $releaseTag = $release.tag_name
    $a = $release.assets | Where-Object { $_.name -eq $asset } | Select-Object -First 1
    if (-not $a) { Fail "release $ZenVersion has no $asset." }
    if ($a.browser_download_url -notlike "https://github.com/zen-browser/desktop/releases/download/*") { Fail "unexpected download URL: $($a.browser_download_url)" }
    $digest = if ($a.PSObject.Properties.Name -contains "digest") { [string]$a.digest } else { "" }
    if ($digest -notlike "sha256:*") { Fail "GitHub did not publish a SHA-256 digest for $asset; refusing to install unverified." }
    Say "Downloading Zen $releaseTag ($asset)"
    $installer = Join-Path $work $asset
    Invoke-WebRequest -UseBasicParsing -Uri $a.browser_download_url -OutFile $installer
    $actual = (Get-FileHash -Algorithm SHA256 $installer).Hash.ToLowerInvariant()
    if ("sha256:$actual" -ne $digest.ToLowerInvariant()) { Fail "checksum mismatch for $asset (expected $digest, got sha256:$actual)." }
    Say "Checksum OK"
  }

  # --- Unpack the browser files (core\) from the installer without running it ---
  # The official installer is a 7-Zip self-extracting archive. Try 7-Zip, then the tar.exe
  # that ships with Windows 10/11, then 7zr.exe from 7-zip.org (checksum pinned above).
  Say "Unpacking"
  $unpack = Join-Path $work "unpack"
  New-Item -ItemType Directory -Path $unpack | Out-Null
  $methods = if ($Extractor -eq "auto") { @("7z", "tar", "7zr") } else { @($Extractor) }
  $done = $false
  foreach ($m in $methods) {
    Get-ChildItem $unpack -Force | Remove-Item -Recurse -Force   # clear any partial result
    try {
      if ($m -eq "7z") {
        $sz = Get-Command 7z.exe -ErrorAction SilentlyContinue
        $sevenZip = if ($sz) { $sz.Source } else { Join-Path $env:ProgramFiles "7-Zip\7z.exe" }
        if (Test-Path $sevenZip) { & $sevenZip x $installer "-o$unpack" "core\*" -y | Out-Null }
      } elseif ($m -eq "tar") {
        $tar = Join-Path $env:SystemRoot "System32\tar.exe"
        if (Test-Path $tar) { & $tar -xf $installer -C $unpack core 2>$null }
      } elseif ($m -eq "7zr") {
        $zr = Join-Path $work "7zr.exe"
        Invoke-WebRequest -UseBasicParsing -Uri $SevenZrUrl -OutFile $zr
        if ((Get-FileHash -Algorithm SHA256 $zr).Hash.ToLowerInvariant() -ne $SevenZrSha256) { Fail "7zr.exe checksum mismatch." }
        & $zr x $installer "-o$unpack" "core\*" -y | Out-Null
      }
    } catch {
      # Native tools that write warnings to stderr raise errors under "Stop"; judge by the result.
      if ($_.Exception.Message -like "error: *") { throw }
    }
    if (Test-Path (Join-Path $unpack "core\zen.exe")) { $done = $true; Say "Unpacked with $m"; break }
  }
  if (-not $done) { Fail "could not unpack the Zen installer. Install 7-Zip (7-zip.org) and run this again." }
  $staged = Join-Path $unpack "core"
  $zenVersionLine = Select-String -Path (Join-Path $staged "application.ini") -Pattern "^Version=" | Select-Object -First 1
  $zenAppVersion = if ($zenVersionLine) { $zenVersionLine.Line.Substring(8) } else { "?" }

  # --- Zen Browser Lite layer ---
  New-Item -ItemType Directory -Path (Join-Path $staged "defaults\pref") -Force | Out-Null
  New-Item -ItemType Directory -Path (Join-Path $staged "browser\defaults\preferences") -Force | Out-Null
  Copy-Item (Join-Path $src "autoconfig.js") (Join-Path $staged "defaults\pref\autoconfig.js") -Force
  Copy-Item (Join-Path $src "prefs\$Tier.js") (Join-Path $staged "browser\defaults\preferences\zen-lite-prefs.js") -Force
  Copy-Item (Join-Path $src "zen-lite.cfg") (Join-Path $staged "zen-lite.cfg") -Force
  @(
    "zen-lite=$ZenLiteVersion", "tier=$Tier", "zen=$zenAppVersion", "release=$releaseTag",
    "installed=" + (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  ) | Set-Content -Path (Join-Path $staged $MarkerName) -Encoding ASCII

  # Swap the new build in; keep the old one until the new one is in place.
  New-Item -ItemType Directory -Path (Split-Path -Parent $Prefix) -Force | Out-Null
  if (Test-Path $Prefix) {
    $old = "$Prefix.old." + [Guid]::NewGuid().ToString("N").Substring(0, 6)
    Move-Item $Prefix $old
    Move-Item $staged $Prefix
    Remove-Item $old -Recurse -Force
  } else {
    Move-Item $staged $Prefix
  }
  $exe = Join-Path $Prefix "zen.exe"
  $profileArgs = if ($ProfileDir) { "-profile `"$ProfileDir`" " } else { "" }

  if (-not $NoShortcut) {
    New-Item -ItemType Directory -Path $StartMenu -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($ShortcutPath)
    $lnk.TargetPath = $exe
    $lnk.Arguments = $profileArgs.Trim()
    $lnk.WorkingDirectory = $Prefix
    $lnk.IconLocation = "$exe,0"   # Zen's own icon from the official build
    $lnk.Description = "Unofficial low-memory setup of the official Zen Browser"
    $lnk.Save()
  }

  if ($RegisterBrowser) {
    $open = "`"$exe`" $profileArgs-osint -url `"%1`""
    $base = "HKCU:\Software\Clients\StartMenuInternet\$RegKey"
    New-Item -Path "$base\Capabilities\URLAssociations" -Force | Out-Null
    New-Item -Path "$base\Capabilities\FileAssociations" -Force | Out-Null
    New-Item -Path "$base\shell\open\command" -Force | Out-Null
    New-Item -Path "$base\DefaultIcon" -Force | Out-Null
    Set-ItemProperty $base -Name "(default)" -Value $AppName
    Set-ItemProperty "$base\DefaultIcon" -Name "(default)" -Value "$exe,0"
    Set-ItemProperty "$base\shell\open\command" -Name "(default)" -Value "`"$exe`" $($profileArgs.Trim())"
    Set-ItemProperty "$base\Capabilities" -Name "ApplicationName" -Value $AppName
    Set-ItemProperty "$base\Capabilities" -Name "ApplicationDescription" -Value "Unofficial low-memory setup of the official Zen Browser"
    Set-ItemProperty "$base\Capabilities" -Name "ApplicationIcon" -Value "$exe,0"
    foreach ($s in @("http", "https")) { Set-ItemProperty "$base\Capabilities\URLAssociations" -Name $s -Value "ZenLiteURL" }
    foreach ($e in @(".htm", ".html", ".xhtml", ".pdf")) { Set-ItemProperty "$base\Capabilities\FileAssociations" -Name $e -Value "ZenLiteHTML" }
    foreach ($id in @("ZenLiteURL", "ZenLiteHTML")) {
      $k = "HKCU:\Software\Classes\$id"
      New-Item -Path "$k\shell\open\command" -Force | Out-Null
      New-Item -Path "$k\DefaultIcon" -Force | Out-Null
      Set-ItemProperty $k -Name "(default)" -Value "$AppName document"
      if ($id -eq "ZenLiteURL") { Set-ItemProperty $k -Name "URL Protocol" -Value "" }
      Set-ItemProperty "$k\DefaultIcon" -Name "(default)" -Value "$exe,1"
      Set-ItemProperty "$k\shell\open\command" -Name "(default)" -Value $open
    }
    New-Item -Path "HKCU:\Software\RegisteredApplications" -Force | Out-Null
    Set-ItemProperty "HKCU:\Software\RegisteredApplications" -Name $AppName -Value "Software\Clients\StartMenuInternet\$RegKey\Capabilities"
    Say "Registered $AppName as a browser. Pick it in the Default apps page that opens now."
    if (-not $env:ZENLITE_NO_SETTINGS) {
      try { Start-Process "ms-settings:defaultapps?registeredAppUser=$([uri]::EscapeDataString($AppName))" }
      catch { Warn "could not open Settings; pick $AppName under Settings > Apps > Default apps." }
    }
  }

  Say "Installed $AppName $ZenLiteVersion ($Tier) on Zen $zenAppVersion in $Prefix"
  if (-not $NoShortcut) { Say "Start it from the Start menu: $AppName" }
  if ($Tier -eq "max") { Warn "the max tier turns off site isolation. See the README for what that means." }
} finally {
  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
}
