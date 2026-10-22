import { it, expect } from "vite-plus/test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { IssueReports } from "../src/main/issue-reports";
import { Preferences } from "../src/main/preferences";
import type { Command } from "../src/main/providers/transport";

it("reads managed-account data in legacy and machine-readable forms without accepting failed or invalid reads", async () => {
  const accounts = [{ id: "fixture-account", provider: "claude", label: "Synthetic account", path: "~/fixture", enabled: true }];
  const launch = { home: "/synthetic", data: "/synthetic", demo: false, candidate: false, env: {} };
  let legacy = true, failRead = false, failWrite = false, type = "data", stored: unknown = accounts, nativeReads = 0;
  const writes: string[][] = [];
  const command: Command = async (binary, args, options) => {
    expect(options?.timeoutMs).toBe(5000);
    if (binary === "/usr/bin/osascript") {
      expect(args.slice(4)).toEqual(["dev.meterusage.accounts-fixture", "managedAccounts"]);
      nativeReads++;
      if (failRead) throw new Error("Fixture read failed");
      return Buffer.from(JSON.stringify(stored)).toString("base64");
    }
    expect(binary).toBe("/usr/bin/defaults");
    expect(args[1]).toBe("dev.meterusage.accounts-fixture");
    if (args[2] !== "managedAccounts") throw new Error("Absent fixture key");
    if (args[0] === "read-type") return `Type is ${type}`;
    if (args[0] === "read") return legacy ? `<${Buffer.from(JSON.stringify(stored)).toString("hex")}>` : "{length = 120, bytes = 0x5b7b2269 ... 657d5d}";
    expect(args.slice(0, 4)).toEqual(["write", "dev.meterusage.accounts-fixture", "managedAccounts", "-data"]);
    if (failWrite) throw new Error("Fixture save failed");
    writes.push(args); stored = JSON.parse(Buffer.from(args[4], "hex").toString()); return "";
  };
  expect((await Preferences.load(launch, command, "dev.meterusage.accounts-fixture")).accounts).toEqual(accounts);
  expect(nativeReads).toBe(0);
  legacy = false;
  const prefs = await Preferences.load(launch, command, "dev.meterusage.accounts-fixture");
  expect(prefs.accounts).toEqual(accounts);
  failWrite = true;
  await expect(prefs.set("managedAccounts", [])).rejects.toThrow("Fixture save failed");
  expect(prefs.accounts).toEqual(accounts);
  failWrite = false;
  await expect(prefs.set("managedAccounts", [...accounts, ...accounts])).rejects.toThrow("Invalid preference");
  expect(writes).toEqual([]);
  await prefs.set("managedAccounts", []);
  expect((await Preferences.load(launch, command, "dev.meterusage.accounts-fixture")).accounts).toEqual([]);
  for (const invalid of [{}, ["claude"], [...accounts, ...accounts]]) {
    stored = invalid;
    expect((await Preferences.load(launch, command, "dev.meterusage.accounts-fixture")).accounts).toEqual([]);
  }
  stored = accounts; failRead = true;
  expect((await Preferences.load(launch, command, "dev.meterusage.accounts-fixture")).accounts).toEqual([]);
  failRead = false; type = "string";
  const before = nativeReads;
  expect((await Preferences.load(launch, command, "dev.meterusage.accounts-fixture")).accounts).toEqual([]);
  expect(nativeReads).toBe(before);
});

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

it("validates tagged Claude web consent separately from legacy reconnect markers", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-claude-pref-fixture-"));
  try {
    const launch = { home: root, data: root, demo: true, candidate: true, env: {} };
    const prefs = await Preferences.load(launch);
    for (const marker of ["", "off", "a".repeat(64), "web-v1:" + "b".repeat(64)]) {
      await prefs.set("desktopClaudeIdentity", marker);
      expect((await Preferences.load(launch)).values.desktopClaudeIdentity).toBe(marker);
    }
    for (const marker of ["web-v2:" + "a".repeat(64), "web-v1:bad", "web-v1:" + "a".repeat(65)]) await expect(prefs.set("desktopClaudeIdentity", marker)).rejects.toThrow("Invalid preference");
  } finally { rmSync(root, { recursive: true, force: true }); }
});
