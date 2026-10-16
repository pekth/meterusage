import { it, expect } from "vite-plus/test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { IssueReports } from "../src/main/issue-reports";
import { Preferences } from "../src/main/preferences";
import type { Command } from "../src/main/providers/transport";

it("defaults to Medium and persists only the three panel sizes in an isolated profile", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-size-"));
  const launch = { home: root, data: root, demo: true, candidate: true, env: {} };
  try {
    const prefs = await Preferences.load(launch);
    expect(prefs.values.panelSize).toBe("medium");
    for (const size of ["small", "large", "medium"]) {
      await prefs.set("panelSize", size);
      expect((await Preferences.load(launch)).values.panelSize).toBe(size);
    }
    for (const invalid of ["", "Small", "extra-large", "__proto__", 1, true, ["large"], null]) {
      await expect(prefs.set("panelSize", invalid)).rejects.toThrow("Invalid preference");
      expect(prefs.values.panelSize).toBe("medium");
      writeFileSync(join(root, "preferences.json"), JSON.stringify({ panelSize: invalid }));
      expect((await Preferences.load(launch)).values.panelSize).toBe("medium");
    }
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("reads and writes panel size as a validated defaults string without changing state on write failure", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-size-defaults-"));
  let stored = "large", failWrite = false;
  const command: Command = async (_binary, args) => {
    if (args[2] !== "panelSize") throw new Error("Absent fixture key");
    if (args[0] === "read-type") return "Type is string";
    if (args[0] === "read") return stored;
    expect(args).toEqual(["write", "dev.meterusage.fixture", "panelSize", "-string", "small"]);
    if (failWrite) throw new Error("Fixture write failed");
    stored = args[4]; return "";
  };
  const launch = { home: root, data: root, demo: false, candidate: false, env: {} };
  try {
    const prefs = await Preferences.load(launch, command, "dev.meterusage.fixture");
    expect(prefs.values.panelSize).toBe("large");
    failWrite = true;
    await expect(prefs.set("panelSize", "small")).rejects.toThrow("Fixture write failed");
    expect(prefs.values.panelSize).toBe("large");
    failWrite = false; await prefs.set("panelSize", "small");
    expect((await Preferences.load(launch, command, "dev.meterusage.fixture")).values.panelSize).toBe("small");
    stored = "enormous";
    expect((await Preferences.load(launch, command, "dev.meterusage.fixture")).values.panelSize).toBe("medium");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("rejects the removed strip preference without changing stored fixture data", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-strip-"));
  const launch = { home: root, data: root, demo: true, candidate: true, env: {} };
  try {
    const file = join(root, "preferences.json"), stored = JSON.stringify({ sideNotchPanelPinned: true, sideNotchStripMode: "dots" });
    writeFileSync(file, stored);
    const prefs = await Preferences.load(launch);
    expect(prefs.values).not.toHaveProperty("sideNotchStripMode");
    expect(prefs.values.sideNotchPanelPinned).toBe(true);
    await expect(prefs.set("sideNotchStripMode", "usage")).rejects.toThrow("Invalid preference");
    expect(readFileSync(file, "utf8")).toBe(stored);
  } finally { rmSync(root, { recursive: true, force: true }); }
});


it("persists the report cooldown as a native date and blocks requests after relaunch", async () => {
  let stored: string | undefined;
  const writes: string[][] = [];
  const command: Command = async (_binary, args) => {
    if (args[2] !== "reportNextAllowedAt") throw new Error("Absent fixture key");
    if (args[0] === "read-type") { if (!stored) throw new Error("Absent fixture key"); return "Type is date"; }
    if (args[0] === "read") return stored!;
    expect(args.slice(0, 4)).toEqual(["write", "dev.meterusage.fixture", "reportNextAllowedAt", "-date"]);
    writes.push([...args]); stored = args[4]; return "";
  };
  const launch = { home: "/synthetic", data: "/synthetic", demo: false, candidate: false, env: {} };
  const now = Date.parse("2026-10-15T12:00:00Z"), send = async () => "MU-123";
  let calls = 0;
  const countedSend = async () => { calls++; return send(); };
  const prefs = await Preferences.load(launch, command, "dev.meterusage.fixture");
  await new IssueReports(() => "sanitized fixture", () => {}, prefs, countedSend, () => now).submit();
  const reloaded = await Preferences.load(launch, command, "dev.meterusage.fixture");
  const afterRestart = new IssueReports(() => "different fixture", () => {}, reloaded, countedSend, () => now + 1);
  await afterRestart.submit();
  expect(calls).toBe(1);
  expect(afterRestart.state.retryAt).toBe(now + 600000);
  expect(writes).toEqual([["write", "dev.meterusage.fixture", "reportNextAllowedAt", "-date", "2026-10-15T12:10:00.000Z"]]);
});

it("validates the Grok Cursor account fingerprint without accepting tokens or raw identity", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-grok-preferences-"));
  const launch = { home: root, data: root, demo: true, candidate: true, env: {} };
  try {
    const prefs = await Preferences.load(launch);
    for (const value of ["a".repeat(64), "off", ""]) { await prefs.set("desktopGrokIdentity", value); expect((await Preferences.load(launch)).values.desktopGrokIdentity).toBe(value); }
    for (const value of ["synthetic-account", "WorkosCursorSessionToken=synthetic", "A".repeat(64), 1]) await expect(prefs.set("desktopGrokIdentity", value)).rejects.toThrow("Invalid preference");
  } finally { rmSync(root, { recursive: true, force: true }); }
});

it("defaults saved Grok source to Cursor and accepts only fixed internal methods", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-grok-source-"));
  try {
    const launch = { home: root, data: root, env: {}, demo: true, candidate: true };
    const prefs = await Preferences.load(launch);
    expect(prefs.values.desktopGrokSource).toBe("cursor");
    for (const source of ["bot", "cursor"]) { await prefs.set("desktopGrokSource", source); expect((await Preferences.load(launch)).values.desktopGrokSource).toBe(source); }
    for (const source of ["", "unknown", "Bot", 1]) await expect(prefs.set("desktopGrokSource", source)).rejects.toThrow("Invalid preference");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
