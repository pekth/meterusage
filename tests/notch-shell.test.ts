import { it, expect, afterEach, vi } from "vite-plus/test";
import { NotchFold } from "../src/main/notch-fold";
import { effectiveWindows, notchEntries, minimumShareSize } from "../src/domain/notch";
import { quota, primary, window } from "../src/domain/models";
import { launchConfiguration } from "../src/main/launch";
import { Preferences } from "../src/main/preferences";
import { Coordinator } from "../src/main/coordinator";
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createRequire } from "node:module";
const roots: string[] = [];
const temp = () => { const p = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); roots.push(p); return p; };
afterEach(() => { vi.useRealTimers(); roots.splice(0).forEach(p => rmSync(p, { recursive: true, force: true })); });
it("rechecks pinning at fold time and resumes folding after an action", () => {
  vi.useFakeTimers(); let pinned = false, busy = false, folds = 0;
  const f = new NotchFold(() => pinned || busy, () => folds++);
  f.changed(); vi.advanceTimersByTime(200); pinned = true; vi.advanceTimersByTime(300); expect(folds).toBe(0);
  pinned = false; busy = true; f.changed(); vi.advanceTimersByTime(500); expect(folds).toBe(0);
  busy = false; f.changed(); vi.advanceTimersByTime(450); expect(folds).toBe(1);
  f.changed(); f.hovered = true; vi.advanceTimersByTime(500); expect(folds).toBe(1);
  f.hovered = false; f.changed(); f.cancel(); vi.advanceTimersByTime(500); expect(folds).toBe(1);
});
it("keeps balance-only OpenRouter visible without overriding a real key limit", async () => {
  const q = quota("openRouter", []); q.credits = { unit: "dollars", balance: 0, hasCredits: true, unlimited: false, usedDollars: 100, limitDollars: 100 };
  expect(effectiveWindows(q)).toEqual([window("Account balance", 100)]);
  q.windows = [window("Key limit", 10)]; expect(effectiveWindows(q)).toEqual(q.windows); q.windows = [];
  const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
  const c = new Coordinator(launch, prefs, [{ slot: primary("openRouter"), quota: async () => q }]);
  try { await c.refresh(); expect(notchEntries(c.snapshot())[0].window.label).toBe("Account balance"); } finally { c.stop(); }
});
it("keeps family account digits and labels distinct and marks archive readings stale", async () => {
  const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
  await prefs.set("managedAccounts", [{ id: "one", provider: "codex", label: "", path: "~", enabled: true }, { id: "two", provider: "codex", label: "Work", path: "~", enabled: true }]);
  const slots = [primary("codex"), { ...primary("codex"), slotID: "one" }, { ...primary("codex"), slotID: "two", label: "Work" }];
  const c = new Coordinator(launch, prefs, slots.map(slot => ({ slot, quota: async () => quota("codex", [window("5-hour", 0)]) })));
  try {
    await c.refresh(); c.quotas["codex#one"] = { status: "missing", code: "offline", reason: "Offline" };
    const entries = notchEntries(c.snapshot()); expect(entries.map(e => e.digit)).toEqual([undefined, 2, 3]); expect(entries.map(e => e.fresh)).toEqual([true, false, true]); expect(entries[2].slot.label).toBe("Work"); expect(entries[1].window.usedPercent).toBe(0);
  } finally { c.stop(); }
});
it("exports at least two pixels per point on 1x and preserves higher backing scale", () => {
  expect(minimumShareSize(250, 351, 1)).toEqual({ width: 500, height: 702 });
  expect(minimumShareSize(250, 351, 3)).toEqual({ width: 750, height: 1053 });
});
it("keeps the builder bundle name and renames only the executable before signing", async () => {
  const require = createRequire(import.meta.url), builderRequire = createRequire(require.resolve("electron-builder"));
  const { getConfig, validateConfiguration } = builderRequire("app-builder-lib/out/util/config/config");
  const { AppInfo } = builderRequire("app-builder-lib/out/appInfo");
  const config = await getConfig(process.cwd()); await validateConfiguration(config);
  const info = new AppInfo({ config, metadata: JSON.parse(readFileSync("package.json", "utf8")) }, "46", config.mac);
  expect(info.productFilename).toBe("MeterUsage"); expect(config.mac.identity).toBe("-"); expect(config.mac.hardenedRuntime).toBe(true); expect(config.mac.notarize).toBe(false);
  const bundle = join(temp(), "MeterUsage.app"), bin = join(bundle, "Contents/MacOS"); mkdirSync(bin, { recursive: true }); writeFileSync(join(bin, "MeterUsage"), "synthetic executable");
  let executable = "MeterUsage";
  const { renameExecutable } = require("../Scripts/electron/after-pack.cjs");
  renameExecutable(bundle, (_binary: string, args: string[]) => { expect(args).toEqual(["-c", "Set :CFBundleExecutable meterusage", join(bundle, "Contents/Info.plist")]); executable = "meterusage"; });
  expect(executable).toBe("meterusage"); expect(readFileSync(join(bin, "meterusage"), "utf8")).toBe("synthetic executable"); expect(existsSync(join(bin, "MeterUsage"))).toBe(false);
});
