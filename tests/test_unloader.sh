#!/usr/bin/env bash
# End-to-end test: install Zen Browser Lite from a Zen archive into a throwaway HOME, start it
# under Xvfb with five local pages, and check that the timed unloader unloads idle
# background tabs while leaving the selected, pinned and "unsaved changes" tabs alone.
# It also checks that the tier's prefs are active in the running browser.
#
# Usage: tests/test_unloader.sh ZEN_TARBALL [lite|max]
# Needs: xvfb-run, python3.

set -euo pipefail

tarball="$(realpath -- "${1:?usage: test_unloader.sh ZEN_TARBALL [lite|max]}")"
tier="${2:-lite}"
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/zen-lite-test.XXXXXXXX")"
server_pid=""
cleanup() {
  if [[ -n "$server_pid" ]]; then kill "$server_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

export HOME="$work/home"
export XDG_DATA_HOME="$HOME/.local/share"
mkdir -p "$HOME"
bash "$repo/install.sh" --zen-tarball "$tarball" --tier "$tier" --no-desktop >/dev/null
prefix="$HOME/.local/opt/zen-lite"
[[ -f "$prefix/zen-lite.cfg" && -f "$prefix/browser/defaults/preferences/zen-lite-prefs.js" ]] || fail "install did not place Zen Browser Lite files"

# --- Local test pages ---------------------------------------------------------------
site="$work/site"
mkdir -p "$site"
for name in active idle-a pinned unsaved idle-b; do
  printf '<!doctype html><title>%s</title><h1>%s</h1>\n' "$name" "$name" >"$site/$name.html"
done
# A page with unsaved changes: it registers a beforeunload handler.
printf '<script>addEventListener("beforeunload", e => { e.preventDefault(); });</script>\n' >>"$site/unsaved.html"
port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -m http.server "$port" --bind 127.0.0.1 --directory "$site" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 50); do
  python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$port/active.html')" 2>/dev/null && break
  sleep 0.1
done
base="http://127.0.0.1:$port"

# --- Test fixture appended to the installed cfg (the repo copy is untouched) -------------
report="$work/report.json"
cat >>"$prefix/zen-lite.cfg" <<'EOF'

// ---- test fixture (added by tests/test_unloader.sh) ----
(function zenLiteTestFixture() {
  const reportPath = Services.env.get("ZENLITE_TEST_REPORT");
  const watched = ["dom.ipc.processCount.webIsolated", "dom.ipc.processPrelaunch.enabled",
    "fission.autostart", "zenlite.unloader.after-seconds", "browser.tabs.unloadOnLowMemory"];
  Services.obs.addObserver(function onWin(win) {
    Services.obs.removeObserver(onWin, "browser-delayed-startup-finished");
    win.setTimeout(() => {
      const g = win.gBrowser;
      for (const tab of g.tabs) {
        const url = tab.linkedBrowser.currentURI.spec;
        if (url.endsWith("/pinned.html")) g.pinTab(tab);
        if (url.endsWith("/active.html")) g.selectedTab = tab;
      }
    }, 3000);
    const write = () => {
      const prefs = {};
      for (const name of watched) {
        const t = Services.prefs.getPrefType(name);
        prefs[name] = t == Services.prefs.PREF_INT ? Services.prefs.getIntPref(name)
          : t == Services.prefs.PREF_BOOL ? Services.prefs.getBoolPref(name) : null;
      }
      const tabs = win.gBrowser.tabs.map(tab => ({
        url: tab.linkedBrowser.currentURI.spec,
        loaded: !!tab.linkedPanel,
        selected: tab.selected,
        pinned: tab.pinned,
      }));
      win.IOUtils.writeUTF8(reportPath, JSON.stringify({ prefs, tabs }));
    };
    win.setInterval(write, 2000);
  }, "browser-delayed-startup-finished");
})();
EOF

profile="$work/profile"
mkdir -p "$profile"
cat >"$profile/user.js" <<'EOF'
user_pref("zenlite.unloader.after-seconds", 10);
user_pref("zenlite.unloader.check-seconds", 5);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("zen.welcome-screen.seen", true);
// Firefox only honours "leave page?" handlers after the user interacted with the page;
// the test has no user, so lift that requirement to exercise the protection.
user_pref("dom.require_user_interaction_for_beforeunload", false);
EOF

export ZENLITE_TEST_REPORT="$report"
export MOZ_CRASHREPORTER_DISABLE=1
timeout 90 xvfb-run -a -s "-screen 0 1280x800x24" \
  "$prefix/zen" --no-remote -profile "$profile" \
  "$base/active.html" "$base/idle-a.html" "$base/pinned.html" "$base/unsaved.html" "$base/idle-b.html" \
  >"$work/browser.log" 2>&1 &
browser_pid=$!

# Wait for the idle tabs to pass after-seconds (10 s) plus one or two sweeps (5 s each).
deadline=$((SECONDS + 75))
verdict=""
while ((SECONDS < deadline)); do
  sleep 3
  [[ -s "$report" ]] || continue
  verdict="$(python3 -I - "$report" "$tier" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
tier = sys.argv[2]
tabs = {t["url"].rsplit("/", 1)[-1]: t for t in r["tabs"] if t["url"].startswith("http://127.0.0.1")}
want = {"active.html": True, "pinned.html": True, "unsaved.html": True, "idle-a.html": False, "idle-b.html": False}
problems = []
for page, loaded in want.items():
    t = tabs.get(page)
    if t is None:
        problems.append(f"{page}: tab missing")
    elif t["loaded"] != loaded:
        problems.append(f"{page}: loaded={t['loaded']}, expected {loaded}")
p = r["prefs"]
expect = {"dom.ipc.processCount.webIsolated": 1, "dom.ipc.processPrelaunch.enabled": False,
          "browser.tabs.unloadOnLowMemory": True, "zenlite.unloader.after-seconds": 10,
          "fission.autostart": tier == "lite"}
for k, v in expect.items():
    if p.get(k) != v:
        problems.append(f"pref {k}={p.get(k)!r}, expected {v!r}")
print("PASS" if not problems else "WAIT " + "; ".join(problems))
PY
)"
  [[ "$verdict" == PASS ]] && break
done

kill "$browser_pid" 2>/dev/null || true
wait "$browser_pid" 2>/dev/null || true
pkill -TERM -f -- "-profile $profile" 2>/dev/null || true

if [[ "$verdict" != PASS ]]; then
  echo "--- last report ---" >&2
  cat "$report" >&2 2>/dev/null || echo "(no report written)" >&2
  echo "--- browser log (tail) ---" >&2
  tail -n 30 "$work/browser.log" >&2 || true
  fail "unloader ($tier): ${verdict#WAIT }"
fi
echo "PASS: unloader ($tier) unloaded idle tabs and kept active, pinned and unsaved tabs"
