#!/bin/bash
# Zen Browser Lite installer for macOS (unofficial).
#
# Downloads the official Zen Browser disk image from github.com/zen-browser/desktop,
# verifies its SHA-256 against the digest GitHub publishes for the release asset,
# copies Zen.app to "Zen Browser Lite.app" and adds Zen Browser Lite's memory settings
# and tab unloader inside the app bundle. Adding files breaks Zen's code signature, so
# the copy is re-signed locally (ad hoc). No administrator rights are needed.
#
#   curl -fsSL https://raw.githubusercontent.com/m3lonxd/zen-browser-lite/main/install-macos.sh | bash
#   bash install-macos.sh --tier max
#   bash install-macos.sh --uninstall
#
# Works with the bash 3.2 that ships with macOS. Run with --help for all options.

set -euo pipefail

ZENLITE_VERSION="0.2.0"
ZENLITE_REPO="m3lonxd/zen-browser-lite"
ZENLITE_REF="${ZENLITE_REF:-main}"
APP_NAME="Zen Browser Lite"
MARKER=".zen-lite-install"
LAUNCHER_TAG="# zen-lite-launcher"

tier="lite"
prefix="${HOME}/Applications"
bin_dir="${HOME}/.local/bin"
zen_dmg=""
zen_version="latest"
profile=""
action="install"

say() { printf '\033[1;32m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Zen Browser Lite ${ZENLITE_VERSION}: unofficial low-memory setup of the official Zen Browser.

Usage: install-macos.sh [options]

  --tier lite|max        Memory profile (default: lite). max turns off site isolation.
  --prefix DIR           Folder for "${APP_NAME}.app" (default: ~/Applications).
  --zen-version TAG      Zen release to install, e.g. 1.24.1b (default: latest).
  --zen-dmg FILE         Use a local zen.macos-universal.dmg instead of downloading.
  --profile DIR          Make the zen-lite command start with this existing profile,
                         e.g. one from ~/Library/Application Support/zen/Profiles.
  --uninstall            Remove Zen Browser Lite (your profiles are kept).
  -h, --help             Show this help.

Re-running the installer updates Zen and Zen Browser Lite in place.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tier) tier="${2:-}"; shift 2 ;;
    --prefix) prefix="${2:-}"; shift 2 ;;
    --zen-version) zen_version="${2:-}"; shift 2 ;;
    --zen-dmg) zen_dmg="${2:-}"; shift 2 ;;
    --profile) profile="${2:-}"; shift 2 ;;
    --uninstall) action="uninstall"; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this installer is for macOS. Use install.sh on Linux and install.ps1 on Windows."
[ "$tier" = "lite" ] || [ "$tier" = "max" ] || die "--tier must be lite or max."

abspath() { # absolute path of a possibly missing path, without realpath (macOS < 13)
  local dir base
  dir="$(dirname -- "$1")"; base="$(basename -- "$1")"
  mkdir -p -- "$dir" 2>/dev/null || true
  if [ -d "$dir" ]; then printf '%s/%s\n' "$(cd -- "$dir" && pwd -P)" "$base"; else printf '%s\n' "$1"; fi
}

prefix="$(abspath "$prefix")"
app="$prefix/${APP_NAME}.app"
resources="$app/Contents/Resources"

is_running() { pgrep -f "$app/Contents/MacOS/" >/dev/null 2>&1; }

if [ "$action" = "uninstall" ]; then
  is_running && die "${APP_NAME} is running. Quit it first."
  if [ -d "$app" ]; then
    [ -f "$resources/$MARKER" ] || die "$app was not installed by ${APP_NAME}; not removing it."
    rm -rf -- "$app"
    say "Removed $app"
  fi
  if [ -f "$bin_dir/zen-lite" ] && grep -qF "$LAUNCHER_TAG" "$bin_dir/zen-lite"; then
    rm -f -- "$bin_dir/zen-lite"
    say "Removed $bin_dir/zen-lite"
  fi
  say "${APP_NAME} removed. Profiles in ~/Library/Application Support/zen were not touched."
  exit 0
fi

for c in curl shasum hdiutil codesign ditto osascript; do
  command -v "$c" >/dev/null 2>&1 || die "'$c' is required but missing."
done
if [ -n "$profile" ]; then
  profile="$(abspath "$profile")"
  [ -f "$profile/prefs.js" ] || [ -f "$profile/times.json" ] || die "$profile does not look like a browser profile folder."
fi
is_running && die "${APP_NAME} is running. Quit it, then run the installer again."
if [ -e "$app" ] && [ ! -f "$resources/$MARKER" ]; then
  die "$app already exists and was not created by ${APP_NAME}."
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/zen-lite.XXXXXXXX")"
mnt=""
cleanup() {
  if [ -n "$mnt" ]; then hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

# --- Zen Browser Lite files: from this checkout, or from GitHub when piped through curl. --
src="$work/src"
mkdir -p "$src/prefs"
script_dir=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
fi
if [ -n "$script_dir" ] && [ -f "$script_dir/src/zen-lite.cfg" ]; then
  cp "$script_dir/src/zen-lite.cfg" "$script_dir/src/autoconfig.js" "$src/"
  cp "$script_dir/src/prefs/$tier.js" "$src/prefs/"
else
  base="https://raw.githubusercontent.com/${ZENLITE_REPO}/${ZENLITE_REF}/src"
  say "Fetching ${APP_NAME} files ($ZENLITE_REF)"
  for f in zen-lite.cfg autoconfig.js "prefs/$tier.js"; do
    curl -fsSL --retry 3 -o "$src/$f" "$base/$f" || die "could not download $base/$f"
  done
fi
grep -q "zenLiteUnloader" "$src/zen-lite.cfg" || die "zen-lite.cfg looks wrong."

# --- Zen release --------------------------------------------------------------------
asset="zen.macos-universal.dmg"
release_tag="local"
if [ -n "$zen_dmg" ]; then
  [ -f "$zen_dmg" ] || die "no such file: $zen_dmg"
  dmg="$zen_dmg"
  say "Using local Zen disk image $zen_dmg (not verified)"
else
  if [ "$zen_version" = "latest" ]; then
    api="https://api.github.com/repos/zen-browser/desktop/releases/latest"
  else
    api="https://api.github.com/repos/zen-browser/desktop/releases/tags/${zen_version}"
  fi
  say "Looking up Zen release ($zen_version)"
  curl -fsSL --retry 3 -H "Accept: application/vnd.github+json" -o "$work/release.json" "$api" ||
    die "could not reach the GitHub API ($api)."
  # JSON is read with JavaScript for Automation, which every Mac has (python3 may not).
  info="$(osascript -l JavaScript - "$work/release.json" "$asset" <<'JXA'
function run(argv) {
  ObjC.import("Foundation");
  const text = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null).js;
  const release = JSON.parse(text);
  const a = (release.assets || []).find(x => x.name === argv[1]);
  return a ? [release.tag_name, a.browser_download_url, a.digest || "-"].join(" ") : "? - -";
}
JXA
)"
  release_tag="${info%% *}"; rest="${info#* }"; asset_url="${rest%% *}"; asset_digest="${rest#* }"
  [ "$asset_url" != "-" ] || die "release $zen_version has no $asset."
  case "$asset_url" in https://github.com/zen-browser/desktop/releases/download/*) ;; *) die "unexpected download URL: $asset_url" ;; esac
  case "$asset_digest" in sha256:*) ;; *) die "GitHub did not publish a SHA-256 digest for $asset; refusing to install unverified." ;; esac
  say "Downloading Zen $release_tag ($asset)"
  dmg="$work/$asset"
  curl -fL --retry 3 --progress-bar -o "$dmg" "$asset_url" || die "download failed."
  actual="sha256:$(shasum -a 256 "$dmg" | cut -d' ' -f1)"
  [ "$actual" = "$asset_digest" ] || die "checksum mismatch for $asset (expected $asset_digest, got $actual)."
  say "Checksum OK"
fi

say "Copying Zen.app from the disk image"
mnt="$work/mnt"
mkdir -p "$mnt"
hdiutil attach "$dmg" -nobrowse -readonly -noautoopen -mountpoint "$mnt" -quiet || die "could not open the disk image."
zen_app="$(find "$mnt" -maxdepth 2 -name "Zen*.app" -type d | head -n 1)"
[ -n "$zen_app" ] && [ -x "$zen_app/Contents/MacOS/zen" ] || die "the disk image does not contain Zen.app."
staged="$work/${APP_NAME}.app"
ditto "$zen_app" "$staged"
hdiutil detach "$mnt" -quiet >/dev/null 2>&1 || true
mnt=""
zen_app_version="$(sed -n 's/^Version=//p' "$staged/Contents/Resources/application.ini" | head -n 1)"

# --- Zen Browser Lite layer ------------------------------------------------------------
r="$staged/Contents/Resources"
mkdir -p "$r/defaults/pref" "$r/browser/defaults/preferences"
install -m 0644 "$src/autoconfig.js" "$r/defaults/pref/autoconfig.js"
install -m 0644 "$src/prefs/$tier.js" "$r/browser/defaults/preferences/zen-lite-prefs.js"
install -m 0644 "$src/zen-lite.cfg" "$r/zen-lite.cfg"
cat >"$r/$MARKER" <<EOF
zen-lite=$ZENLITE_VERSION
tier=$tier
zen=$zen_app_version
release=$release_tag
installed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
# The added files invalidate Zen's signature; sign the copy ad hoc so macOS runs it.
xattr -cr "$staged" 2>/dev/null || true
codesign --force --deep --sign - "$staged" >/dev/null 2>&1 || die "could not re-sign the app (codesign)."
codesign --verify --deep "$staged" >/dev/null 2>&1 || die "the re-signed app does not verify."

mkdir -p "$prefix"
if [ -d "$app" ]; then
  mv -- "$app" "$app.old.$$"
  mv -- "$staged" "$app"
  rm -rf -- "$app.old.$$"
else
  mv -- "$staged" "$app"
fi

# --- Command-line launcher -------------------------------------------------------------
mkdir -p "$bin_dir"
profile_args=""
if [ -n "$profile" ]; then profile_args="-profile $(printf '%q' "$profile") "; fi
cat >"$bin_dir/zen-lite" <<EOF
#!/bin/bash
$LAUNCHER_TAG (created by the ${APP_NAME} installer; re-run it to change this file)
exec $(printf '%q' "$app/Contents/MacOS/zen") ${profile_args}"\$@"
EOF
chmod 0755 "$bin_dir/zen-lite"

say "Installed ${APP_NAME} $ZENLITE_VERSION ($tier) on Zen $zen_app_version in $app"
say "Open it from Launchpad or Finder, or run: $bin_dir/zen-lite"
say "To make it your default browser: System Settings > Desktop & Dock > Default web browser."
if [ "$tier" = "max" ]; then
  warn "the max tier turns off site isolation. See the README for what that means."
fi
