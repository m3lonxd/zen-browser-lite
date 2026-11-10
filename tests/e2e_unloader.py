#!/usr/bin/env python3
"""Cross-platform end-to-end test of an installed Zen Browser Lite.

Starts the installed browser headless with five local pages and checks that the timed
unloader unloads idle background tabs while keeping the selected, pinned and
"unsaved changes" tabs, and that the tier's prefs are live in the running browser.

A test fixture is appended to the installed zen-lite.cfg for the run and removed
afterwards; the repository copy is never touched.

Usage: e2e_unloader.py --cfg PATH_TO_INSTALLED_zen-lite.cfg --exe PATH_TO_ZEN_BINARY --tier lite|max
Works on Linux, macOS and Windows with the Python standard library only.
"""

from __future__ import annotations

import argparse
import functools
import http.server
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

PAGES = ["active", "idle-a", "pinned", "unsaved", "idle-b"]

FIXTURE = r"""
// ---- test fixture (added by tests/e2e_unloader.py) ----
(function zenLiteTestFixture() {
  const reportPath = Services.env.get("ZENLITE_TEST_REPORT");
  if (!reportPath) return;
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
    win.setInterval(() => {
      const prefs = {};
      for (const name of watched) {
        const t = Services.prefs.getPrefType(name);
        prefs[name] = t == Services.prefs.PREF_INT ? Services.prefs.getIntPref(name)
          : t == Services.prefs.PREF_BOOL ? Services.prefs.getBoolPref(name) : null;
      }
      const tabs = win.gBrowser.tabs.map(tab => ({
        url: tab.linkedBrowser.currentURI.spec,
        loaded: !!tab.linkedPanel,
        pinned: tab.pinned,
      }));
      win.IOUtils.writeUTF8(reportPath, JSON.stringify({ prefs, tabs }));
    }, 2000);
  }, "browser-delayed-startup-finished");
})();
"""

USER_JS = """\
user_pref("zenlite.unloader.after-seconds", 10);
user_pref("zenlite.unloader.check-seconds", 5);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("zen.welcome-screen.seen", true);
user_pref("app.update.auto", false);
user_pref("app.update.enabled", false);
// Firefox only honours "leave page?" handlers after the user interacted with the page;
// the test has no user, so lift that requirement to exercise the protection.
user_pref("dom.require_user_interaction_for_beforeunload", false);
"""


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):  # keep test output readable
        pass


def evaluate(report: dict, tier: str) -> list[str]:
    tabs = {t["url"].rsplit("/", 1)[-1]: t for t in report["tabs"] if t["url"].startswith("http://127.0.0.1")}
    want = {"active.html": True, "pinned.html": True, "unsaved.html": True,
            "idle-a.html": False, "idle-b.html": False}
    problems = []
    for page, loaded in want.items():
        tab = tabs.get(page)
        if tab is None:
            problems.append(f"{page}: tab missing")
        elif tab["loaded"] != loaded:
            problems.append(f"{page}: loaded={tab['loaded']}, expected {loaded}")
    prefs = report["prefs"]
    expect = {"dom.ipc.processCount.webIsolated": 1, "dom.ipc.processPrelaunch.enabled": False,
              "browser.tabs.unloadOnLowMemory": True, "zenlite.unloader.after-seconds": 10,
              "fission.autostart": tier == "lite"}
    for key, value in expect.items():
        if prefs.get(key) != value:
            problems.append(f"pref {key}={prefs.get(key)!r}, expected {value!r}")
    return problems


def stop(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/T", "/F", "/PID", str(proc.pid)], capture_output=True)
    else:
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        if os.name != "nt":
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cfg", type=Path, required=True)
    ap.add_argument("--exe", type=Path, required=True)
    ap.add_argument("--tier", choices=("lite", "max"), default="lite")
    ap.add_argument("--timeout", type=int, default=120)
    args = ap.parse_args()

    cfg = args.cfg.resolve()
    if "zenLiteUnloader" not in cfg.read_text(encoding="utf-8"):
        print(f"FAIL: {cfg} is not the Zen Browser Lite cfg", file=sys.stderr)
        return 1

    with tempfile.TemporaryDirectory(prefix="zen-lite-e2e-") as tmp:
        work = Path(tmp)
        site = work / "site"
        site.mkdir()
        for name in PAGES:
            body = f"<!doctype html><title>{name}</title><h1>{name}</h1>\n"
            if name == "unsaved":
                body += '<script>addEventListener("beforeunload", e => { e.preventDefault(); });</script>\n'
            (site / f"{name}.html").write_text(body, encoding="utf-8")
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(QuietHandler, directory=str(site)))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        base = f"http://127.0.0.1:{server.server_address[1]}"

        profile = work / "profile"
        profile.mkdir()
        (profile / "user.js").write_text(USER_JS, encoding="utf-8")
        report = work / "report.json"

        backup = cfg.with_name(cfg.name + ".e2e-backup")
        shutil.copy2(cfg, backup)
        log = (work / "browser.log").open("w")
        proc = None
        verdict: list[str] = ["no report written"]
        try:
            with cfg.open("a", encoding="utf-8") as fh:
                fh.write(FIXTURE)
            env = dict(os.environ, ZENLITE_TEST_REPORT=str(report), MOZ_CRASHREPORTER_DISABLE="1")
            cmd = [str(args.exe), "--headless", "--no-remote", "-profile", str(profile),
                   *(f"{base}/{p}.html" for p in PAGES)]
            proc = subprocess.Popen(
                cmd, env=env, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=(os.name != "nt"),
                creationflags=getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0))
            deadline = time.monotonic() + args.timeout
            while time.monotonic() < deadline:
                time.sleep(3)
                if proc.poll() is not None:
                    verdict = [f"browser exited early with code {proc.returncode}"]
                    break
                try:
                    data = json.loads(report.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    continue
                verdict = evaluate(data, args.tier)
                if not verdict:
                    break
        finally:
            if proc is not None:
                stop(proc)
            shutil.move(str(backup), str(cfg))
            server.shutdown()
            log.close()

        if verdict:
            print(f"FAIL: unloader ({args.tier}): " + "; ".join(verdict), file=sys.stderr)
            if report.exists():
                print("--- last report ---\n" + report.read_text(encoding="utf-8"), file=sys.stderr)
            print("--- browser log (tail) ---", file=sys.stderr)
            print("\n".join((work / "browser.log").read_text(errors="replace").splitlines()[-30:]), file=sys.stderr)
            return 1
    print(f"PASS: unloader ({args.tier}) unloaded idle tabs and kept active, pinned and unsaved tabs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
