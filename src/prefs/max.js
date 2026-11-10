// NexLite "max" profile: default prefs for Zen Browser.
//
// Everything in "lite", pushed further, plus one trade-off you should understand
// before choosing it:
//
//   SITE ISOLATION (FISSION) IS TURNED OFF.
//   Pages from different sites can share a content process again, as in Firefox
//   before version 95. This saves the most memory, but a successful exploit or a
//   Spectre-style attack in one tab is no longer walled off from other sites' data
//   in the same process. Do not use "max" on a machine where you handle sensitive
//   accounts and visit untrusted sites in the same browser.
//
// Installed as browser/defaults/preferences/nexlite-prefs.js in the Zen folder; values
// changed in about:config still win.

// --- Content processes --------------------------------------------------------------
pref("fission.autostart", false);
// Without site isolation, tabs share at most 4 web content processes (default 8).
pref("dom.ipc.processCount", 4);
pref("dom.ipc.processCount.webIsolated", 1);
pref("dom.ipc.processPrelaunch.enabled", false);

// --- Unloading idle tabs ------------------------------------------------------------
// Unload a background tab after 5 minutes unused.
pref("nexlite.unloader.enabled", true);
pref("nexlite.unloader.after-seconds", 300);
pref("nexlite.unloader.check-seconds", 30);
pref("nexlite.unloader.include-pinned", false);
pref("browser.tabs.unloadOnLowMemory", true);
pref("browser.low_commit_space_threshold_percent", 25);
pref("browser.tabs.min_inactive_duration_before_unload", 120000);

// --- Caches -------------------------------------------------------------------------
pref("browser.cache.memory.capacity", 8192);
pref("image.mem.surfacecache.max_size_kb", 262144);
// No pages kept alive for back/forward; going back reloads from the disk cache.
pref("browser.sessionhistory.max_total_viewers", 0);

// --- Work nobody asked for ----------------------------------------------------------
pref("browser.newtab.preload", false);
pref("network.prefetch-next", false);
pref("network.dns.disablePrefetch", true);
