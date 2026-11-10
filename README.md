<p align="center">
  <img src="./docs/assets/banner.svg" alt="Zen Browser Lite: Zen Browser on a memory diet" width="100%">
</p>

<p align="center">
  <a href="https://github.com/m3lonxd/zen-browser-lite/actions/workflows/check.yml"><img src="https://img.shields.io/github/actions/workflow/status/m3lonxd/zen-browser-lite/check.yml?branch=main&style=flat-square&label=tests%20vs%20latest%20Zen" alt="Tests against the latest Zen release"></a>
  <img src="https://img.shields.io/badge/platform-Linux-3ddc84?style=flat-square" alt="Platform: Linux">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/license-MPL--2.0-2fd3c4?style=flat-square" alt="License: MPL-2.0"></a>
  <a href="https://github.com/zen-browser/desktop"><img src="https://img.shields.io/badge/runs-official%20Zen%20builds-2fd3c4?style=flat-square" alt="Runs official Zen builds"></a>
</p>

<p align="center"><b>English</b> · <a href="./README.tr.md">Türkçe</a></p>

Zen Browser Lite is an **unofficial** low-memory setup of the official [Zen Browser](https://zen-browser.app). It is the same Zen, with the same name, look, icon and updates, plus a small memory layer on top. Nothing is forked or rebuilt. The installer downloads Zen from Zen's own GitHub releases, checks the SHA-256 that GitHub publishes for the file, and adds three plain-text files next to it: tuned default settings and a tab unloader that Zen is currently missing.

The test opened the same 7 websites in both. Once the background tabs had been idle, the default **lite** tier used **60% less memory** than stock Zen: 496 MB instead of 1.20 GB. With every tab loaded, it used 13% less.

<p align="center">
  <img src="./docs/assets/memory-chart.svg" alt="Memory chart: Zen compared with Lite tier and max" width="100%">
</p>

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/m3lonxd/zen-browser-lite/main/install.sh | bash
```

Prefer to read it first? `curl -fsSLO https://raw.githubusercontent.com/m3lonxd/zen-browser-lite/main/install.sh`, look through it, then run `bash install.sh`.

Zen Browser Lite installs into `~/.local/opt/zen-lite`, adds a `zen-lite` command and a menu entry that uses Zen's own icon. It needs `curl`, `tar`, `xz`, `sha256sum` and `python3`, which almost every Linux desktop already has. No root rights.

| Option | What it does |
| --- | --- |
| `--tier lite` | Default. Saves memory without weakening security. |
| `--tier max` | Saves the most. Turns off site isolation, see [lite or max](#lite-or-max). |
| `--profile DIR` | Start with an existing profile, for example your current Zen profile in `~/.zen`. |
| `--set-default` | Make Zen Browser Lite the default browser, so links from other apps open in it. |
| `--zen-version TAG` | Install a specific Zen release instead of the latest. |
| `--uninstall` | Remove Zen Browser Lite. Profiles are kept. |

Run the installer again at any time to update Zen and Zen Browser Lite; settings and profiles stay. Zen's own updater also keeps working, and Zen Browser Lite's files survive its updates.

> [!NOTE]
> Using `--profile` with the profile your normal Zen uses? Close Zen first. Two browsers cannot have the same profile open at once.

## Where the memory goes

Zen inherits Firefox's defaults, which assume plenty of RAM. These are the settings Zen Browser Lite changes, with Zen's value read from the running build.

| Setting | Zen | lite | max | Why it matters |
| --- | --- | --- | --- | --- |
| Tab unloader | does nothing | 10 min | 5 min | Zen 1.24 still registers `zen.tab-unloader.timeout-minutes`. In our test it was set to 1 minute, and after 3 minutes no tab had been unloaded. Idle tabs stay in RAM until the system runs low. |
| `dom.ipc.processCount.webIsolated` | 4 | 1 | 1 | Up to four processes per site. Four YouTube tabs could mean four processes. |
| `dom.ipc.processPrelaunch.enabled` | true | false | false | A spare, empty content process kept running at all times. |
| `browser.tabs.unloadOnLowMemory` | false | true | true | Firefox's own emergency unloader is off on Linux. |
| `browser.low_commit_space_threshold_percent` | 5 | 15 | 25 | When the emergency unloader steps in. At 5% free the system is already swapping. |
| `fission.autostart` (site isolation) | true | true | **false** | One process per site. The biggest single cost, and a real security feature. |
| `dom.ipc.processCount` | 8 | 8 | 4 | Web processes shared by all tabs when site isolation is off. |
| `browser.sessionhistory.max_total_viewers` | auto, up to 8 | 2 | 0 | Whole pages kept alive for instant Back. |
| `image.mem.surfacecache.max_size_kb` | 2 GB | 512 MB | 256 MB | Decoded images kept in RAM. |
| `browser.cache.memory.capacity` | auto, up to 32 MB | 16 MB | 8 MB | In-memory HTTP cache. Pages still use the disk cache. |
| `browser.newtab.preload` | true | false | false | The new-tab page rendered in the background before you open it. |
| `network.prefetch-next`, `network.dns.disablePrefetch` | on | off | off | Pages a site merely hints you might visit next. |

These are installed as *default* values (`browser/defaults/preferences/zen-lite-prefs.js`). Anything you change in `about:config` or Settings still wins, and Reset in `about:config` returns to Zen Browser Lite's value. Every pref is checked against the newest Zen release each week by [`tools/check_prefs.py`](./tools/check_prefs.py), because Firefox silently ignores names it does not know.

## The tab unloader

[`src/zen-lite.cfg`](./src/zen-lite.cfg) runs once when Zen starts, using Firefox's standard [AutoConfig](https://support.mozilla.org/kb/customizing-firefox-using-autoconfig) mechanism. Every minute (every 30 seconds on max), it unloads background tabs that have not been looked at for the configured time. An unloaded tab keeps its place, title, icon and history; clicking it reloads the page.

It never unloads a tab that is:

- selected, or visible in a split view;
- playing sound, or sharing your camera, microphone or screen;
- in picture-in-picture, still loading, a Glance preview or Zen's empty new-tab placeholder;
- pinned or an Essential, so chat and mail tabs keep their notifications;
- holding unsaved changes. Firefox's own "leave page?" check decides, and Zen Browser Lite never forces it.

Tune it in `about:config`. Changes apply without a restart.

| Pref | lite | max |
| --- | --- | --- |
| `zenlite.unloader.enabled` | true | true |
| `zenlite.unloader.after-seconds` | 600 | 300 |
| `zenlite.unloader.check-seconds` | 60 | 30 |
| `zenlite.unloader.include-pinned` | false | false |

## lite or max

**lite** keeps every security boundary Zen has. Choose it unless you have a reason not to.

**max** turns off site isolation (Fission). Pages from different sites can share a process again, as in Firefox before version 95. In the benchmark this only paid off while every tab was loaded: 20% less than Zen, against 13% for lite. Once the unloader had done its work, max was no better than lite (−55% against −60%), because unloaded tabs no longer hold a process either way. It also means a successful exploit, or a Spectre-style attack, in one tab is no longer walled off from other sites' data in the same process. It can be a reasonable trade on an old laptop used for reading with many tabs open at once. It is a bad trade on a machine where you bank and browse unknown sites in the same browser.

## How it is measured

[`bench/measure.py`](./bench/measure.py) unpacks the same Zen archive for every variant and starts it with a fresh profile under Xvfb. It opens the same 7 real websites: two Wikipedia articles, GitHub, MDN, BBC News, a YouTube channel and Hacker News. It samples at two points:

- **all tabs loaded**: 90 seconds after start;
- **background tabs idle**: 240 seconds after start. To keep a run short, the unloader timer is 2 minutes here instead of 10 or 5.

Memory is the sum of PSS and SwapPss over every browser process. PSS splits shared pages fairly between processes, so shared libraries are not counted twice, and SwapPss keeps swapped-out memory in the total. Each variant ran 3 times, interleaved, and the chart shows the median. Raw numbers are in [`bench/results.json`](./bench/results.json). Run it yourself:

```bash
python3 bench/measure.py zen.linux-x86_64.tar.xz --rounds 3
python3 tools/render_assets.py      # redraws the banner and chart from the results
```

Your numbers will differ with your sites, extensions and hardware. The direction should not.

## Tests

| Test | What it proves |
| --- | --- |
| [`tests/test_unloader.sh`](./tests/test_unloader.sh) | Starts Zen Browser Lite with five local pages. Checks that idle tabs are unloaded and that the selected, pinned and unsaved tabs are kept. Checks that the tier's prefs are live in the running browser. |
| [`tests/test_install.sh`](./tests/test_install.sh) | Install, in-place update, tier switch, `--profile`, refusing folders Zen Browser Lite did not create, uninstall that keeps profiles. |
| [`tools/check_prefs.py`](./tools/check_prefs.py) | Every pref Zen Browser Lite sets exists in the Zen build. |

CI runs all three on every change and every Monday against the newest Zen release.

## Uninstall

```bash
bash install.sh --uninstall
```

This removes `~/.local/opt/zen-lite`, the `zen-lite` command, and the menu entry. Browser profiles in `~/.zen` are left alone.

## Legal

Zen Browser Lite is an **unofficial**, independent project. It is not affiliated with or endorsed by the Zen Browser team or Mozilla. "Zen Browser", its logo and "Firefox" belong to their respective owners. The name says what this project sets up; this repository does not contain Zen's logo. The menu entry shows the icon that ships inside the official Zen build you download. If the Zen team asks for a different name, the project will be renamed.

Zen Browser Lite does not redistribute Zen. The installer downloads the unmodified official release from [github.com/zen-browser/desktop](https://github.com/zen-browser/desktop/releases), verifies it and adds Zen Browser Lite's own files. Zen is licensed under the [MPL-2.0](https://github.com/zen-browser/desktop/blob/dev/LICENSE); Zen Browser Lite's files are MPL-2.0 too.

This repository used to hold **NexBrowser**, a full fork of Zen. That code is kept in the [`archive/nexbrowser-fork`](https://github.com/m3lonxd/zen-browser-lite/tree/archive/nexbrowser-fork) branch.
