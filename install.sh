#!/usr/bin/env bash
# NexLite installer for Linux.
#
# Downloads the official Zen Browser release from github.com/zen-browser/desktop,
# verifies its SHA-256 against the digest GitHub publishes for the release asset,
# installs it to its own folder and adds NexLite's memory settings and tab unloader.
# Zen itself is not modified or rebuilt; NexLite only adds three files next to it.
#
#   curl -fsSL https://raw.githubusercontent.com/m3lonxd/nexlite/main/install.sh | bash
#   bash install.sh --tier max
#   bash install.sh --uninstall
#
# Run with --help for all options.

set -euo pipefail

NEXLITE_VERSION="0.1.0"
NEXLITE_REPO="m3lonxd/nexlite"
NEXLITE_REF="${NEXLITE_REF:-main}"
MARKER_NAME=".nexlite-install"
LAUNCHER_TAG="# nexlite-launcher"

tier="lite"
prefix="${HOME}/.local/opt/nexlite"
bin_dir="${HOME}/.local/bin"
apps_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/applications"
icons_dir="${XDG_DATA_HOME:-${HOME}/.local/share}/icons/hicolor/scalable/apps"
zen_tarball=""
zen_version="latest"
profile=""
desktop=1
set_default=0
action="install"

say() { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
NexLite ${NEXLITE_VERSION}: Zen Browser with lower memory use.

Usage: install.sh [options]

  --tier lite|max        Memory profile (default: lite).
                         lite keeps site isolation; max turns it off to save more
                         memory (read the README before choosing max).
  --prefix DIR           Install folder (default: ~/.local/opt/nexlite).
  --zen-version TAG      Zen release to install, e.g. 1.24.1b (default: latest).
  --zen-tarball FILE     Use a local zen.linux-*.tar.xz instead of downloading.
  --profile DIR          Always start with this existing profile folder,
                         e.g. a profile from your current Zen in ~/.zen.
  --no-desktop           Do not add a menu entry and icon.
  --set-default          Make NexLite the default web browser.
  --uninstall            Remove NexLite (your profiles are kept).
  -h, --help             Show this help.

Re-running the installer updates Zen and NexLite in place and keeps your settings.
EOF
}

while (($#)); do
  case "$1" in
    --tier) tier="${2:-}"; shift 2 ;;
    --prefix) prefix="${2:-}"; shift 2 ;;
    --zen-version) zen_version="${2:-}"; shift 2 ;;
    --zen-tarball) zen_tarball="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --no-desktop) desktop=0; shift ;;
    --set-default) set_default=1; shift ;;
    --uninstall) action="uninstall"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || die "this installer is for Linux only."
[[ "$tier" == "lite" || "$tier" == "max" ]] || die "--tier must be lite or max."
[[ -n "$prefix" ]] || die "--prefix needs a folder."
prefix="$(realpath -m -- "$prefix")"
[[ "$prefix" != "/" && "$prefix" != "$HOME" ]] || die "refusing to use $prefix as the install folder."

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' is required but not installed."; }

is_running() {
  # True if a browser started from this install folder is still running.
  local pid exe
  for pid in /proc/[0-9]*; do
    exe="$(readlink "$pid/exe" 2>/dev/null)" || continue
    [[ "$exe" == "$prefix/"* ]] && return 0
  done
  return 1
}

uninstall() {
  if is_running; then
    die "NexLite is running. Close it first."
  fi
  if [[ -d "$prefix" ]]; then
    [[ -f "$prefix/$MARKER_NAME" ]] || die "$prefix was not installed by NexLite; not removing it."
    rm -rf -- "$prefix"
    say "Removed $prefix"
  fi
  if [[ -f "$bin_dir/nexlite" ]] && grep -qF "$LAUNCHER_TAG" "$bin_dir/nexlite"; then
    rm -f -- "$bin_dir/nexlite"
    say "Removed $bin_dir/nexlite"
  fi
  rm -f -- "$apps_dir/nexlite.desktop" "$icons_dir/nexlite.svg"
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  if command -v xdg-settings >/dev/null 2>&1 &&
    [[ "$(xdg-settings get default-web-browser 2>/dev/null || true)" == "nexlite.desktop" ]]; then
    warn "NexLite was your default browser. Pick a new one in your system settings."
  fi
  say "NexLite removed. Browser profiles in ~/.zen were not touched."
}

if [[ "$action" == "uninstall" ]]; then
  uninstall
  exit 0
fi

need tar
need xz
need sha256sum
if [[ -n "$profile" ]]; then
  profile="$(realpath -m -- "$profile")"
  [[ -f "$profile/prefs.js" || -f "$profile/times.json" ]] ||
    die "$profile does not look like a browser profile folder."
fi

case "$(uname -m)" in
  x86_64 | amd64) arch="x86_64" ;;
  aarch64 | arm64) arch="aarch64" ;;
  *) die "unsupported CPU architecture: $(uname -m). Zen publishes x86_64 and aarch64." ;;
esac

if is_running; then
  die "NexLite is running. Close it, then run the installer again."
fi
if [[ -e "$prefix" && ! -f "$prefix/$MARKER_NAME" ]]; then
  die "$prefix already exists and was not created by NexLite. Choose another --prefix."
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/nexlite.XXXXXXXX")"
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT

# --- NexLite files: from this checkout, or from GitHub when piped through curl. ---------
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
src="$work/src"
mkdir -p "$src/prefs"
if [[ -n "$script_dir" && -f "$script_dir/src/nexlite.cfg" ]]; then
  cp "$script_dir/src/nexlite.cfg" "$script_dir/src/autoconfig.js" "$script_dir/src/nexlite.svg" "$src/"
  cp "$script_dir/src/prefs/$tier.js" "$src/prefs/"
else
  need curl
  base="https://raw.githubusercontent.com/${NEXLITE_REPO}/${NEXLITE_REF}/src"
  say "Fetching NexLite files ($NEXLITE_REF)"
  for f in nexlite.cfg autoconfig.js nexlite.svg "prefs/$tier.js"; do
    curl -fsSL --retry 3 -o "$src/$f" "$base/$f" || die "could not download $base/$f"
  done
fi
grep -q "nexliteUnloader" "$src/nexlite.cfg" || die "downloaded nexlite.cfg looks wrong."

# --- Zen release --------------------------------------------------------------------
asset="zen.linux-${arch}.tar.xz"
if [[ -n "$zen_tarball" ]]; then
  [[ -f "$zen_tarball" ]] || die "no such file: $zen_tarball"
  tarball="$zen_tarball"
  release_tag="local"
  say "Using local Zen archive $zen_tarball (not verified)"
else
  need curl
  need python3
  if [[ "$zen_version" == "latest" ]]; then
    api="https://api.github.com/repos/zen-browser/desktop/releases/latest"
  else
    api="https://api.github.com/repos/zen-browser/desktop/releases/tags/${zen_version}"
  fi
  say "Looking up Zen release ($zen_version)"
  curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" -o "$work/release.json" "$api" ||
    die "could not reach the GitHub API ($api)."
  read -r release_tag asset_url asset_digest < <(
    python3 -I - "$work/release.json" "$asset" <<'PY'
import json, sys
release = json.load(open(sys.argv[1]))
for a in release.get("assets", []):
    if a.get("name") == sys.argv[2]:
        print(release.get("tag_name", "?"), a["browser_download_url"], a.get("digest") or "-")
        break
else:
    print("? - -")
PY
  )
  [[ "$asset_url" != "-" ]] || die "release $zen_version has no $asset."
  [[ "$asset_url" == https://github.com/zen-browser/desktop/releases/download/* ]] ||
    die "unexpected download URL: $asset_url"
  [[ "$asset_digest" == sha256:* ]] ||
    die "GitHub did not publish a SHA-256 digest for $asset; refusing to install unverified."
  say "Downloading Zen $release_tag ($asset)"
  tarball="$work/$asset"
  curl -fL --retry 3 --progress-bar -o "$tarball" "$asset_url" || die "download failed."
  actual="sha256:$(sha256sum "$tarball" | cut -d' ' -f1)"
  [[ "$actual" == "$asset_digest" ]] || die "checksum mismatch for $asset (expected $asset_digest, got $actual)."
  say "Checksum OK"
fi

say "Unpacking"
mkdir -p "$work/unpack"
tar -xJf "$tarball" -C "$work/unpack"
staged="$work/unpack/zen"
[[ -x "$staged/zen" && -f "$staged/application.ini" ]] || die "the archive does not contain a Zen build."
zen_app_version="$(sed -n 's/^Version=//p' "$staged/application.ini" | head -n1)"

# --- NexLite layer ------------------------------------------------------------------
install -m 0644 "$src/autoconfig.js" "$staged/defaults/pref/autoconfig.js"
mkdir -p "$staged/browser/defaults/preferences"
install -m 0644 "$src/prefs/$tier.js" "$staged/browser/defaults/preferences/nexlite-prefs.js"
install -m 0644 "$src/nexlite.cfg" "$staged/nexlite.cfg"
cat >"$staged/$MARKER_NAME" <<EOF
nexlite=$NEXLITE_VERSION
tier=$tier
zen=$zen_app_version
release=$release_tag
installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

# Swap the new build in; keep the old one until the new one is in place.
mkdir -p "$(dirname -- "$prefix")"
if [[ -d "$prefix" ]]; then
  mv -- "$prefix" "$prefix.old.$$"
  mv -- "$staged" "$prefix"
  rm -rf -- "$prefix.old.$$"
else
  mv -- "$staged" "$prefix"
fi

# --- Launcher -----------------------------------------------------------------------
mkdir -p "$bin_dir"
profile_args=""
if [[ -n "$profile" ]]; then
  profile_args="-profile $(printf '%q' "$profile") "
fi
cat >"$bin_dir/nexlite" <<EOF
#!/usr/bin/env bash
$LAUNCHER_TAG (created by the NexLite installer; re-run it to change this file)
exec $(printf '%q' "$prefix/zen") --name nexlite --class nexlite ${profile_args}"\$@"
EOF
chmod 0755 "$bin_dir/nexlite"

if ((desktop)); then
  mkdir -p "$apps_dir" "$icons_dir"
  install -m 0644 "$src/nexlite.svg" "$icons_dir/nexlite.svg"
  cat >"$apps_dir/nexlite.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=NexLite
GenericName=Web Browser
Comment=Zen Browser with lower memory use
Exec=$bin_dir/nexlite %u
Icon=nexlite
Terminal=false
StartupWMClass=nexlite
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
Actions=new-window;new-private-window;

[Desktop Action new-window]
Name=New Window
Exec=$bin_dir/nexlite --new-window

[Desktop Action new-private-window]
Name=New Private Window
Exec=$bin_dir/nexlite --private-window
EOF
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
fi

if ((set_default)); then
  if ((desktop)) && command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser nexlite.desktop && say "NexLite is now the default browser"
  else
    warn "could not set the default browser (needs xdg-settings and the menu entry)."
  fi
fi

say "Installed NexLite $NEXLITE_VERSION ($tier) on Zen $zen_app_version in $prefix"
case ":$PATH:" in
  *":$bin_dir:"*) say "Start it with: nexlite" ;;
  *) say "Start it with: $bin_dir/nexlite  (add $bin_dir to PATH to type just 'nexlite')" ;;
esac
if [[ "$tier" == "max" ]]; then
  warn "the max tier turns off site isolation. See the README for what that means."
fi
