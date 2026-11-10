#!/bin/bash
# Installer tests for macOS: install, signature, update in place, tier switch, --profile,
# refusing foreign folders, uninstall. Runs in a throwaway HOME; no browser is started.
#
# Usage: tests/test_install_macos.sh ZEN_DMG

set -euo pipefail

dmg="$(cd -- "$(dirname -- "${1:?usage: test_install_macos.sh ZEN_DMG}")" && pwd)/$(basename -- "$1")"
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/zen-lite-mac-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

export HOME="$work/home"
mkdir -p "$HOME"
app="$HOME/Applications/Zen Browser Lite.app"
res="$app/Contents/Resources"
passed=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$*"; }
run() { bash "$repo/install-macos.sh" --zen-dmg "$dmg" "$@" >"$work/out.log" 2>&1; }

run --tier lite || { cat "$work/out.log"; fail "fresh install failed"; }
[ -x "$app/Contents/MacOS/zen" ] || fail "app binary missing"
[ -f "$res/defaults/pref/autoconfig.js" ] || fail "autoconfig.js missing"
[ -f "$res/zen-lite.cfg" ] || fail "zen-lite.cfg missing"
cmp -s "$res/browser/defaults/preferences/zen-lite-prefs.js" "$repo/src/prefs/lite.js" || fail "lite prefs not installed"
codesign --verify --deep "$app" || fail "app signature does not verify"
[ -x "$HOME/.local/bin/zen-lite" ] || fail "launcher missing"
ok "fresh install copies Zen.app, adds the layer and re-signs it"

touch "$res/stale-file"
run --tier max || { cat "$work/out.log"; fail "update failed"; }
cmp -s "$res/browser/defaults/preferences/zen-lite-prefs.js" "$repo/src/prefs/max.js" || fail "max prefs not installed"
[ ! -e "$res/stale-file" ] || fail "old app was not replaced"
grep -q "site isolation" "$work/out.log" || fail "max tier did not warn"
ok "re-running updates in place and switches tier"

mkdir -p "$work/my profile" && touch "$work/my profile/prefs.js"
run --profile "$work/my profile" || { cat "$work/out.log"; fail "--profile install failed"; }
prof_real="$(cd -- "$work/my profile" && pwd -P)"   # /var is a symlink to /private/var on macOS
grep -qF -- "-profile $(printf '%q' "$prof_real")" "$HOME/.local/bin/zen-lite" || { cat "$HOME/.local/bin/zen-lite"; fail "launcher lacks -profile"; }
mkdir -p "$work/empty"
if run --profile "$work/empty"; then fail "accepted a non-profile folder"; fi
ok "--profile is quoted into the launcher; non-profile folders are refused"

mkdir -p "$work/foreign/Zen Browser Lite.app" && touch "$work/foreign/Zen Browser Lite.app/keep"
if run --prefix "$work/foreign"; then fail "installed over a foreign app"; fi
if bash "$repo/install-macos.sh" --uninstall --prefix "$work/foreign" >/dev/null 2>&1; then fail "uninstalled a foreign app"; fi
[ -f "$work/foreign/Zen Browser Lite.app/keep" ] || fail "foreign app modified"
ok "foreign apps are refused for install and uninstall"

bash "$repo/install-macos.sh" --uninstall >"$work/out.log" 2>&1 || { cat "$work/out.log"; fail "uninstall failed"; }
[ ! -e "$app" ] || fail "app still there"
[ ! -e "$HOME/.local/bin/zen-lite" ] || fail "launcher still there"
ok "uninstall removes the app and launcher"

echo "PASS: $passed installer checks"
