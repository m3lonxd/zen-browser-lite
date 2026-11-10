#!/usr/bin/env python3
"""Measure Zen Browser memory with and without NexLite.

For every variant ("stock" Zen, NexLite "lite", NexLite "max") and every round, this
script unpacks the same official Zen archive into a throwaway folder, starts it under
Xvfb with a fresh profile and the same set of real websites, and samples memory twice:

  loaded  - 90 s after start: every tab has loaded, one is in front.
  idle    - 240 s after start: the user has not touched the background tabs since.

Memory is the sum of PSS + SwapPss over every process started from that install
folder. PSS splits shared pages fairly between processes, so the sum does not count
shared libraries twice, and SwapPss keeps swapped-out memory in the total.

To keep a run at four minutes the NexLite unloader timer is set to 120 s here instead
of the shipped 600 s (lite) or 300 s (max); the "idle" number therefore shows what
happens once the timer has passed, not after exactly four minutes of real use.

Usage: bench/measure.py ZEN_TARBALL [--rounds N] [--variants stock,lite,max] [--out FILE]
Needs Linux, xvfb-run and network access. Run it on an otherwise quiet machine.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import signal
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

SITES = [
    "https://en.wikipedia.org/wiki/Web_browser",
    "https://en.wikipedia.org/wiki/Firefox",
    "https://github.com/zen-browser/desktop",
    "https://developer.mozilla.org/en-US/docs/Web/JavaScript",
    "https://www.bbc.com/news",
    "https://www.youtube.com/@Mozilla",
    "https://news.ycombinator.com/",
]
LOADED_AT = 90
IDLE_AT = 240
BENCH_UNLOAD_AFTER = 120

USER_JS = """\
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("zen.welcome-screen.seen", true);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("media.autoplay.default", 5);
"""
NEXLITE_USER_JS = f"""\
user_pref("nexlite.unloader.after-seconds", {BENCH_UNLOAD_AFTER});
user_pref("nexlite.unloader.check-seconds", 15);
"""


def install_variant(variant: str, tarball: Path, root: Path) -> Path:
    """Return the install folder for a variant inside root."""
    if variant == "stock":
        with tarfile.open(tarball) as tar:
            tar.extractall(root, filter="tar")
        return root / "zen"
    home = root / "home"
    home.mkdir()
    env = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / ".local/share"))
    subprocess.run(
        ["bash", str(REPO / "install.sh"), "--zen-tarball", str(tarball), "--tier", variant, "--no-desktop"],
        env=env, check=True, stdout=subprocess.DEVNULL,
    )
    return home / ".local/opt/nexlite"


def processes_under(prefix: Path) -> list[int]:
    pids = []
    want = str(prefix) + os.sep
    for entry in Path("/proc").iterdir():
        if not entry.name.isdigit():
            continue
        try:
            exe = os.readlink(entry / "exe")
        except OSError:
            continue
        if exe.startswith(want):
            pids.append(int(entry.name))
    return pids


def memory_mb(pids: list[int]) -> float:
    total_kb = 0
    for pid in pids:
        try:
            text = Path(f"/proc/{pid}/smaps_rollup").read_text()
        except OSError:
            continue  # process exited between listing and reading
        for line in text.splitlines():
            key, _, rest = line.partition(":")
            if key in ("Pss", "SwapPss"):
                total_kb += int(rest.split()[0])
    return round(total_kb / 1024, 1)


def run_once(variant: str, tarball: Path) -> dict:
    with tempfile.TemporaryDirectory(prefix=f"nexlite-bench-{variant}-") as tmp:
        root = Path(tmp)
        prefix = install_variant(variant, tarball, root)
        profile = root / "profile"
        profile.mkdir()
        (profile / "user.js").write_text(USER_JS + (NEXLITE_USER_JS if variant != "stock" else ""))
        cmd = [
            "xvfb-run", "-a", "-s", "-screen 0 1600x900x24",
            str(prefix / "zen"), "--no-remote", "-profile", str(profile), *SITES,
        ]
        env = dict(os.environ, MOZ_CRASHREPORTER_DISABLE="1")
        proc = subprocess.Popen(
            cmd, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True,
        )
        start = time.monotonic()
        result: dict = {}
        try:
            for label, at in (("loaded", LOADED_AT), ("idle", IDLE_AT)):
                time.sleep(max(0.0, start + at - time.monotonic()))
                if proc.poll() is not None:
                    raise RuntimeError(f"{variant}: browser exited early with code {proc.returncode}")
                pids = processes_under(prefix)
                result[f"{label}_mb"] = memory_mb(pids)
                result[f"{label}_processes"] = len(pids)
        finally:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            for pid in processes_under(prefix):  # anything that escaped the group
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        return result


def zen_version(tarball: Path) -> str:
    with tarfile.open(tarball) as tar:
        member = tar.extractfile("zen/application.ini")
        for line in member.read().decode().splitlines():
            if line.startswith("Version="):
                return line.split("=", 1)[1]
    return "unknown"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("tarball", type=Path)
    ap.add_argument("--rounds", type=int, default=3)
    ap.add_argument("--variants", default="stock,lite,max")
    ap.add_argument("--out", type=Path, default=REPO / "bench" / "results.json")
    args = ap.parse_args()

    if shutil.which("xvfb-run") is None:
        print("error: xvfb-run is required", file=sys.stderr)
        return 2
    variants = [v.strip() for v in args.variants.split(",") if v.strip()]
    for v in variants:
        if v not in ("stock", "lite", "max"):
            print(f"error: unknown variant {v}", file=sys.stderr)
            return 2

    runs: dict[str, list[dict]] = {v: [] for v in variants}
    # Interleave variants so a slow network minute does not hit one variant only.
    for r in range(1, args.rounds + 1):
        for v in variants:
            print(f"round {r}/{args.rounds}: {v} ...", flush=True)
            res = run_once(v, args.tarball.resolve())
            print(f"  loaded {res['loaded_mb']} MB ({res['loaded_processes']} processes), "
                  f"idle {res['idle_mb']} MB ({res['idle_processes']} processes)", flush=True)
            runs[v].append(res)

    summary = {}
    for v, rs in runs.items():
        summary[v] = {
            key: statistics.median(r[key] for r in rs)
            for key in ("loaded_mb", "idle_mb", "loaded_processes", "idle_processes")
        }
    out = {
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "zen_version": zen_version(args.tarball),
        "arch": platform.machine(),
        "method": {
            "sites": SITES,
            "loaded_at_s": LOADED_AT,
            "idle_at_s": IDLE_AT,
            "unloader_after_s_in_bench": BENCH_UNLOAD_AFTER,
            "metric": "sum of PSS + SwapPss over all browser processes, MB",
            "rounds": args.rounds,
            "aggregate": "median",
        },
        "summary": summary,
        "runs": runs,
    }
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(out, indent=2) + "\n")
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
