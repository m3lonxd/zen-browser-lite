// Zen Browser Lite "lite" profile: default prefs for Zen Browser.
//
// Installed as browser/defaults/preferences/zen-lite-prefs.js in the Zen folder. These are
// *default* values: anything changed in about:config or Settings still wins, and
// "Reset" in about:config returns to the value below.
//
// Site isolation (Fission) stays on. Every value is checked against the current Zen
// build by tools/check_prefs.py, and the effect is measured by bench/measure.py.

// --- Content processes --------------------------------------------------------------
// Zen starts a spare, empty content process in advance so the next tab opens a few
// milliseconds faster. It costs 30-60 MB for as long as the browser runs.
pref("dom.ipc.processPrelaunch.enabled", false);
// With site isolation every site gets its own process; by default up to 4 per site
// (four YouTube tabs = four processes). One per site keeps isolation between sites
// and shares the process between tabs of the same site.
pref("dom.ipc.processCount.webIsolated", 1);

// --- Unloading idle tabs ------------------------------------------------------------
// Timed unloader from zen-lite.cfg: unload a background tab after 10 minutes unused.
pref("zenlite.unloader.enabled", true);
pref("zenlite.unloader.after-seconds", 600);
pref("zenlite.unloader.check-seconds", 60);
pref("zenlite.unloader.include-pinned", false);
// Firefox's own low-memory unloader is off on Linux by default. Turn it on and let it
// act when less than 15% of RAM is available (default 5%, which is already swapping).
pref("browser.tabs.unloadOnLowMemory", true);
pref("browser.low_commit_space_threshold_percent", 15);
pref("browser.tabs.min_inactive_duration_before_unload", 300000);

// --- Caches -------------------------------------------------------------------------
// In-memory HTTP cache: 16 MB instead of an automatic size of up to 32 MB.
pref("browser.cache.memory.capacity", 16384);
// Decoded images kept in RAM: at most 512 MB instead of up to 2 GB.
pref("image.mem.surfacecache.max_size_kb", 524288);
// Pages kept alive for instant back/forward: 2 instead of up to 8.
pref("browser.sessionhistory.max_total_viewers", 2);

// --- Work nobody asked for ----------------------------------------------------------
// Do not render the new-tab page in the background before it is opened.
pref("browser.newtab.preload", false);
// Do not download pages a site merely hints you might visit next.
pref("network.prefetch-next", false);
pref("network.dns.disablePrefetch", true);
