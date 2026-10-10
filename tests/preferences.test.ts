import { it, expect } from "vite-plus/test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
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
