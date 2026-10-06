import { it, expect, afterEach, vi } from "vite-plus/test";
import { NotchFold } from "../src/main/notch-fold";
import { effectiveWindows, notchEntries, minimumShareSize, notchFrame } from "../src/domain/notch";
import { shareSnapshot } from "../src/main/ipc";
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
it("stops polling and reset actions when a configured account directory disappears", async () => {
  const root = temp(), directory = join(root, "mounted-account"); mkdirSync(directory);
  const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
  await prefs.set("managedAccounts", [{ id: "mounted", provider: "codex", label: "Mounted", path: directory, enabled: true }]);
  const slot = { ...primary("codex"), slotID: "mounted" }, q = quota("codex", [window("5-hour", 10)]);
  q.resetCredits = [{ id: "fixture-credit", title: "Fixture reset", status: "available" }];
  let reads = 0, consumes = 0;
  const source = { slot, quota: async () => { reads++; return q; }, consumeReset: async () => { consumes++; return true; } };
  const c = new Coordinator(launch, prefs, [source]);
  try {
    await c.refresh(); expect(c.visible(source)).toBe(true);
    const intent = c.prepareReset("codex#mounted", "fixture-credit"), before = reads;
    rmSync(directory, { recursive: true });
    expect(c.visible(source)).toBe(false); expect(c.slots).toEqual([]);
    await c.refresh(); expect(reads).toBe(before);
    expect(() => c.prepareReset("codex#mounted", "fixture-credit")).toThrow("unavailable");
    await expect(c.confirmReset(intent.token)).rejects.toThrow("unavailable"); expect(consumes).toBe(0);
  } finally { c.stop(); }
});
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
it("captures tall cards in full and rejects oversized images without cropping", () => {
  expect(minimumShareSize(250, 2500, 2)).toEqual({ width: 500, height: 5000 });
  expect(minimumShareSize(250, 4096, 2)).toEqual({ width: 500, height: 8192 });
  expect(() => minimumShareSize(250, 4097, 2)).toThrow("Card too tall to share");
  expect(() => minimumShareSize(250, 3000, 3)).toThrow("Card too tall to share");
});
it("bounds oversized notch content to the work area without changing normal anchors", () => {
  const screen = { x: 0, y: 60, width: 1200, height: 800 }, anchor = { x: 700, y: 100 };
  for (const right of [true, false]) {
    const frame = notchFrame(anchor, { width: 294, height: 1200 }, right, screen);
    expect(frame.height).toBe(800); expect(frame.y).toBe(60); expect(frame.y + frame.height).toBe(860);
    const short = notchFrame(anchor, { width: 294, height: 200 }, right, screen), taller = notchFrame(anchor, { width: 294, height: 350 }, right, screen);
    expect(short.y).toBe(100); expect(taller.y).toBe(100); expect(short.x).toBe(taller.x);
  }
});
it("freezes the displayed fallback card for sharing and rejects a removed card", async () => {
  const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
  await prefs.set("showProviderClaude", true);
  const c = new Coordinator(launch, prefs, [{ slot: primary("claude"), quota: async () => quota("claude", [window("5-hour", 42)]) }]);
  try {
    await c.refresh();
    const state = { snapshot: c.snapshot(), settings: { values: {}, accounts: [] }, systemDark: true, notch: { expanded: true, cardOnRight: false, selected: "codex", dragging: false } };
    const frozen = shareSnapshot(state, "claude"); expect(frozen.notch.selected).toBe("claude");
    state.snapshot.quotas.claude = { status: "missing", code: "offline", reason: "Offline" }; state.notch.selected = "codex";
    expect(frozen.snapshot.quotas.claude.status).toBe("value"); expect(frozen.notch.selected).toBe("claude");
    expect(() => shareSnapshot(state, "codex")).toThrow("unavailable");
  } finally { c.stop(); }
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
