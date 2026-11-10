#!/usr/bin/env bash
# Installer tests: install, update in place, switch tier, use an existing profile,
# refuse foreign folders, uninstall. Runs in a throwaway HOME; no browser is started.
#
# Usage: tests/test_install.sh ZEN_TARBALL

set -euo pipefail

tarball="$(realpath -- "${1:?usage: test_install.sh ZEN_TARBALL}")"
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/zen-lite-install-test.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT

export HOME="$work/home"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME"
prefix="$HOME/.local/opt/zen-lite"
apps="$XDG_DATA_HOME/applications"
passed=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok() { passed=$((passed + 1)); printf 'ok %d - %s\n' "$passed" "$*"; }
install_zen-lite() { bash "$repo/install.sh" --zen-tarball "$tarball" "$@" >"$work/out.log" 2>&1; }

# 1. Fresh install with menu entry.
install_zen-lite --tier lite || { cat "$work/out.log"; fail "fresh install failed"; }
[[ -x "$prefix/zen" ]] || fail "zen binary missing"
[[ -f "$prefix/defaults/pref/autoconfig.js" ]] || fail "autoconfig.js missing"
[[ -f "$prefix/zen-lite.cfg" ]] || fail "zen-lite.cfg missing"
cmp -s "$prefix/browser/defaults/preferences/zen-lite-prefs.js" "$repo/src/prefs/lite.js" || fail "lite prefs not installed"
grep -qx "tier=lite" "$prefix/.zen-lite-install" || fail "marker lacks tier"
[[ -x "$HOME/.local/bin/zen-lite" ]] || fail "launcher missing"
grep -q -- "--class zen-lite" "$HOME/.local/bin/zen-lite" || fail "launcher lacks window class"
grep -qx "Exec=$HOME/.local/bin/zen-lite %u" "$apps/zen-lite.desktop" || fail "desktop entry Exec wrong"
grep -qx "Icon=$prefix/browser/chrome/icons/default/default128.png" "$apps/zen-lite.desktop" || fail "desktop entry does not use Zen's icon"
[[ -f "$prefix/browser/chrome/icons/default/default128.png" ]] || fail "Zen icon missing in build"
ok "fresh install places Zen, Zen Browser Lite files, launcher, menu entry with Zen's icon"

# 2. Re-run switches tier in place and keeps nothing stale.
touch "$prefix/stale-file"
install_zen-lite --tier max || { cat "$work/out.log"; fail "update failed"; }
cmp -s "$prefix/browser/defaults/preferences/zen-lite-prefs.js" "$repo/src/prefs/max.js" || fail "max prefs not installed"
[[ ! -e "$prefix/stale-file" ]] || fail "old install folder was not replaced"
compgen -G "$prefix.old.*" >/dev/null && fail "temporary old folder left behind"
grep -q "site isolation" "$work/out.log" || fail "max tier did not warn about site isolation"
ok "re-running updates in place, switches tier and warns for max"

# 3. Existing profile is passed to the launcher; a non-profile folder is refused.
mkdir -p "$work/my profile"
touch "$work/my profile/prefs.js"
install_zen-lite --profile "$work/my profile" --no-desktop || { cat "$work/out.log"; fail "--profile install failed"; }
grep -qF -- "-profile $(printf '%q' "$work/my profile")" "$HOME/.local/bin/zen-lite" || fail "launcher lacks quoted -profile"
mkdir -p "$work/empty"
if install_zen-lite --profile "$work/empty"; then fail "accepted a folder that is not a profile"; fi
grep -q "does not look like a browser profile" "$work/out.log" || fail "wrong error for bad profile"
ok "--profile is quoted into the launcher; non-profile folders are refused"

# 4. A folder Zen Browser Lite did not create is never overwritten or removed.
mkdir -p "$work/foreign"
touch "$work/foreign/important"
if install_zen-lite --prefix "$work/foreign"; then fail "installed over a foreign folder"; fi
if bash "$repo/install.sh" --uninstall --prefix "$work/foreign" >"$work/out.log" 2>&1; then
  fail "uninstalled a foreign folder"
fi
[[ -f "$work/foreign/important" ]] || fail "foreign folder was modified"
ok "foreign folders are refused for install and uninstall"

# 5. Bad arguments.
if bash "$repo/install.sh" --tier turbo >"$work/out.log" 2>&1; then fail "accepted --tier turbo"; fi
if bash "$repo/install.sh" --bogus >"$work/out.log" 2>&1; then fail "accepted unknown option"; fi
ok "invalid options are rejected"

# 6. Uninstall removes Zen Browser Lite and keeps profiles.
mkdir -p "$HOME/.zen/keep.profile"
bash "$repo/install.sh" --uninstall >"$work/out.log" 2>&1 || { cat "$work/out.log"; fail "uninstall failed"; }
[[ ! -e "$prefix" ]] || fail "install folder still there"
[[ ! -e "$HOME/.local/bin/zen-lite" ]] || fail "launcher still there"
[[ ! -e "$apps/zen-lite.desktop" ]] || fail "desktop entry still there"
[[ -d "$HOME/.zen/keep.profile" ]] || fail "uninstall touched profiles"
ok "uninstall removes Zen Browser Lite and keeps profiles"

echo "PASS: $passed installer checks"
