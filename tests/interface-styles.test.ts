import { it, expect } from "vite-plus/test";
import { mkdtempSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { interfaceStyles, styleInfo, styleOf, validInterfaceStyle } from "../src/shared/styles";
import { parseRequest, projectSettings } from "../src/main/ipc";
import { Preferences, initialPreferences } from "../src/main/preferences";

it("registers every interface style with a meter, gauge, chart and palette", () => {
  expect(interfaceStyles).toEqual(["classic", "flightDeck", "orbit", "ledger", "terminal", "blueprint", "departures", "arcade"]);
  for (const id of interfaceStyles) {
    expect(styleInfo[id].name).toBeTruthy();
    expect(["follow", "theme", "fixed"]).toContain(styleInfo[id].palette);
  }
  expect(styleInfo.classic).toMatchObject({ meter: "bar", gauge: "conic", chart: "grid", palette: "follow" });
  expect(styleOf("orbit")).toBe("orbit");
  for (const bad of [undefined, "", "neon", "Classic", 3, null]) { expect(validInterfaceStyle(bad)).toBe(false); expect(styleOf(bad)).toBe("classic"); }
});

it("accepts only registered styles over IPC and projects the saved style to Settings", () => {
  for (const id of interfaceStyles) expect(parseRequest({ action: "setPreference", key: "interfaceStyle", value: id })).toEqual({ action: "setPreference", key: "interfaceStyle", value: id });
  for (const value of ["neon", "", 1, true]) expect(() => parseRequest({ action: "setPreference", key: "interfaceStyle", value })).toThrow("Invalid request");
  expect(projectSettings({ ...initialPreferences, interfaceStyle: "ledger" }, [], "/synthetic").values.interfaceStyle).toBe("ledger");
});

it("defaults to Classic, saves a chosen style and ignores an invalid stored style", async () => {
  expect(initialPreferences.interfaceStyle).toBe("classic");
  const dir = mkdtempSync(join(tmpdir(), "meterusage-styles-"));
  try {
    const launch = { home: dir, data: dir, demo: true, candidate: false, env: {}, platform: "darwin" as const };
    const path = join(dir, "preferences.json");
    writeFileSync(path, JSON.stringify({ interfaceStyle: "neon" }));
    expect((await Preferences.load(launch)).values.interfaceStyle).toBe("classic");
    writeFileSync(path, JSON.stringify({ interfaceStyle: "arcade" }));
    const prefs = await Preferences.load(launch);
    expect(prefs.values.interfaceStyle).toBe("arcade");
    await prefs.set("interfaceStyle", "terminal");
    expect(JSON.parse(readFileSync(path, "utf8")).interfaceStyle).toBe("terminal");
    await expect(prefs.set("interfaceStyle", "neon")).rejects.toThrow("Invalid preference");
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
