import { expect, it, vi } from "vite-plus/test";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { applicationData, accountConnectionAvailable, windowsFlyoutY } from "../src/main/platform";
import { Preferences } from "../src/main/preferences";
import { DesktopConnections } from "../src/main/connections";
import type { Launch } from "../src/main/launch";

it("keeps Windows app data separate from the existing macOS location", () => {
  expect(applicationData("C:\\Users\\Example", "win32", {})).toBe("C:\\Users\\Example\\AppData\\Roaming\\MeterUsage");
  expect(applicationData("C:\\Users\\Example", "win32", { AppData: "D:\\Profiles\\Roaming" })).toBe("D:\\Profiles\\Roaming\\MeterUsage");
  expect(() => applicationData("C:\\Users\\Example", "win32", { APPDATA: "relative" })).toThrow("APPDATA must be an absolute directory");
  expect(applicationData("/Users/example", "darwin")).toBe("/Users/example/Library/Application Support/MeterUsage");
});

it("offers only implemented Windows account connections", () => {
  expect(accountConnectionAvailable("codex", "win32")).toBe(true);
  for (const provider of ["claude", "antigravity", "grok"] as const) {
    expect(accountConnectionAvailable(provider, "win32")).toBe(false);
    expect(accountConnectionAvailable(provider, "darwin")).toBe(true);
  }
});

it("keeps the flyout beside a top or bottom taskbar as its content resizes", () => {
  const work = { x: -1200, y: -900, width: 1200, height: 860 };
  expect(windowsFlyoutY({ x: -30, y: -40, width: 30, height: 40 }, work, 300)).toBe(-340);
  expect(windowsFlyoutY({ x: -30, y: -40, width: 30, height: 40 }, work, 600)).toBe(-640);
  expect(windowsFlyoutY({ x: -30, y: -930, width: 30, height: 30 }, work, 300)).toBe(-900);
});

it("persists normal Windows settings and cooldowns without invoking macOS defaults", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-windows-preferences-"));
  const launch: Launch = { home: root, data: root, env: {}, demo: false, candidate: false, platform: "win32" };
  const command = vi.fn(async () => { throw new Error("No platform command should run"); });
  try {
    const prefs = await Preferences.load(launch, command);
    await Promise.all([prefs.set("panelSize", "small"), prefs.set("reportNextAllowedAt", 1900000000000)]);
    const reloaded = await Preferences.load(launch, command);
    expect(reloaded.values.panelSize).toBe("small");
    expect(reloaded.values.reportNextAllowedAt).toBe(1900000000000);
    expect(JSON.parse(readFileSync(join(root, "preferences.json"), "utf8"))).toMatchObject({ panelSize: "small", reportNextAllowedAt: 1900000000000 });
    expect(command).not.toHaveBeenCalled();
    const connections = new DesktopConnections(launch, reloaded, "must-not-run", () => {}, command);
    for (const provider of ["claude", "antigravity", "grok"] as const) {
      expect(connections.state.find(c => c.provider === provider)).toMatchObject({ status: "unsupported", localAvailable: true });
      await expect(connections.connect(provider, async () => {})).rejects.toThrow("Desktop connection is unavailable on Windows");
      expect(connections.enabled(provider)).toBe(false);
      await connections.useLocal(provider);
      expect(connections.state.find(c => c.provider === provider)).toMatchObject({ source: "cli", status: "unsupported" });
      expect(reloaded.enabled(provider)).toBe(true);
    }
    expect(command).not.toHaveBeenCalled();
    await connections.stop();
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("preserves a damaged normal Windows preference file instead of replacing it", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-windows-damaged-"));
  const file = join(root, "preferences.json");
  try {
    writeFileSync(file, "{damaged");
    await expect(Preferences.load({ home: root, data: root, env: {}, demo: false, candidate: false, platform: "win32" })).rejects.toThrow("Could not read preferences");
    expect(readFileSync(file, "utf8")).toBe("{damaged");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
