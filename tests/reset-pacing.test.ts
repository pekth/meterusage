import { describe, it, expect, afterEach } from "vite-plus/test";
import { mkdtempSync, rmSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { quota, window, primary, type Quota } from "../src/domain/models";
import { pace, resetPacing, resetSample } from "../src/domain/pacing";
import { readArchive, saveArchive } from "../src/main/history";
import { Coordinator } from "../src/main/coordinator";
import { Preferences } from "../src/main/preferences";
import { launchConfiguration } from "../src/main/launch";
const at = Date.parse("2026-10-06T12:00:00Z"), hour = 3600000;
const roots: string[] = []; const temp = () => { const p = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); roots.push(p); return p; };
afterEach(() => { roots.splice(0).forEach(p => rmSync(p, { force: true, recursive: true })); });
describe("ADR0008 observation parity with Swift ResetPacingTests", () => {
  it("rejects nonavailable credits before preparation and after a confirmation refresh", async () => {
    const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
    let status: string | undefined = "available", consumes = 0;
    const c = new Coordinator(launch, prefs, [{ slot: primary("codex"), quota: async () => ({ ...quota("codex", [], at), resetCredits: [{ id: "A", title: "Reset", status }] }), consumeReset: async () => { consumes++; return true; } }], () => at);
    try {
      for (const unavailable of ["consumed", "revoked", "expired", undefined]) {
        status = "available"; await c.refresh(); const intent = c.prepareReset("codex", "A");
        status = unavailable; await c.refresh();
        expect(() => c.prepareReset("codex", "A")).toThrow("unavailable");
        await expect(c.confirmReset(intent.token)).rejects.toThrow("unavailable");
      }
      expect(consumes).toBe(0);
    } finally { c.stop(); }
  });
  it("has no forecast for the first/unchanged reading and projects from measured growth", () => {
    const first = resetSample(window("Weekly", 5, at + 7 * 24 * hour, 10080), undefined, at);
    expect(pace(first, at)).toBeUndefined();
    const unchanged = resetSample(window("Weekly", 5, first.resetsAt, 10080), first, at + hour);
    expect(pace(unchanged, at + hour)).toBeUndefined();
    const later = resetSample(window("Weekly", 25, first.resetsAt, 10080), first, at + hour);
    expect(pace(later, at + hour)?.projectedExhaustion).toBe(at + hour + 75 / (20 / hour));
    expect(pace(later, at + hour)?.status).toBe("deficit");
    expect(pace(later, at + hour - 1)).toBeUndefined();
  });
  it("rolls over after a usage decrease, deadline or effective duration change", () => {
    const first = resetSample(window("Weekly", 5, at + 7 * 24 * hour, 10080), undefined, at);
    const grew = resetSample(window("Weekly", 25, first.resetsAt, 10080), first, at + hour);
    for (const w of [window("Weekly", 2, first.resetsAt, 10080), window("Weekly", 30, first.resetsAt! + hour, 10080), window("Weekly", 30, first.resetsAt, 300)]) {
      const renewed = resetSample(w, grew, at + 2 * hour);
      expect(pace(renewed, at + 2 * hour)).toBeUndefined(); expect(renewed.pacingBaseline?.usedPercent).toBe(w.usedPercent);
    }
  });
  it("keeps group baselines, dates, unit enums and reset metadata readable across archive round-trips", () => {
    const q = quota("codex", [window("Weekly", 5, at + 7 * 24 * hour, 10080)], at);
    q.groups = [{ id: "general", title: "General", windows: q.windows }, { id: "model", title: "Model", windows: [window("Weekly", 15, q.windows[0].resetsAt, 10080)] }];
    q.credits = { balance: 0, hasCredits: false, unlimited: false, unit: "credits", dollarBalance: 0 };
    q.resetCredits = [{ id: "fixture-credit", title: "Full reset", status: "available", expiresAt: at + hour }]; q.resetCreditCount = 1; q.planType = "plus";
    const first = resetPacing(q, undefined, at - 1, at);
    const later = resetPacing({ ...q, capturedAt: at + hour, windows: [window("Weekly", 25, q.windows[0].resetsAt, 10080)], groups: [q.groups[0], { ...q.groups[1], windows: [window("Weekly", 35, q.windows[0].resetsAt, 10080)] }] }, first, at - 1, at + hour);
    const path = join(temp(), "quota-archive.json"), slot = { ...primary("codex"), slotID: "fixture-account", label: "Work" };
    saveArchive(path, [{ slot, quota: later }]);
    expect(readArchive(path)["codex#fixture-account"]).toEqual(later);
    expect(JSON.parse(readFileSync(path, "utf8"))[0].credits.unit).toEqual({ credits: {} });
    const model = later.groups[1].windows[0]; expect(pace(model, at + hour)?.projectedExhaustion).toBe(at + hour + 65 / (20 / hour));
  });
  it("rejects in-flight pre-reset quota and failed reset preserves the estimate", async () => {
    let clock = at, held: ((q: Quota) => void) | undefined, hold = false, accepted = true;
    const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
    const make = () => { const q = quota("codex", [window("Weekly", 25, at + 6 * 24 * hour)], clock); q.resetCreditCount = 1; q.resetCredits = [{ id: "credit", title: "Full reset", status: "available" }]; return q; };
    const c = new Coordinator(launch, prefs, [{ slot: primary("codex"), quota: async () => hold ? new Promise<Quota>(resolve => { held = resolve; }) : make(), consumeReset: async () => accepted }], () => clock);
    try {
      await c.refresh(); const before = structuredClone(c.quotas.codex);
      accepted = false; await expect(c.confirmReset(c.prepareReset("codex", "credit").token)).rejects.toThrow(); expect(c.quotas.codex).toEqual(before);
      accepted = true; hold = true; const sweep = c.refresh(); await Promise.resolve();
      const stale = make(); clock += 1; const reset = c.confirmReset(c.prepareReset("codex", "credit").token); await Promise.resolve();
      hold = false; held!(stale); await Promise.all([sweep, reset]);
      expect(c.archived.codex.resetPacingSince).toBe(clock); expect(c.quotas.codex.status).toBe("missing"); expect(c.archived.codex.windows[0].pacingBaseline?.capturedAt).toBeUndefined();
      clock += 1; await c.refresh(); const fresh = c.quotas.codex; expect(fresh.status).toBe("value"); if (fresh.status === "value") expect(pace(fresh.value.windows[0], clock)).toBeUndefined();
    } finally { c.stop(); }
  });
  it("preserves metadata refreshed during reset acceptance in the same account", async () => {
    let clock = at, ids = ["A", "B"], offline = false, accept!: (value: boolean) => void;
    const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
    const c = new Coordinator(launch, prefs, [{ slot: primary("codex"), quota: async () => {
      if (offline) throw new Error("offline fixture");
      const q = quota("codex", [window("Weekly", 25)], clock); q.resetCredits = ids.map(id => ({ id, title: "Full reset", status: "available" })); q.resetCreditCount = ids.length; return q;
    }, consumeReset: async () => new Promise<boolean>(resolve => { accept = resolve; }) }], () => clock);
    try {
      await c.refresh(); const reset = c.confirmReset(c.prepareReset("codex", "A").token);
      ids = ["A", "B", "C"]; clock++; await c.refresh(); offline = true; clock++; accept(true); await reset;
      expect(c.archived.codex.resetCredits.map(c => c.id)).toEqual(["B", "C"]); expect(c.archived.codex.resetCreditCount).toBe(2);
      expect(readArchive(join(root, "quota-archive.json")).codex.resetCredits.map(c => c.id)).toEqual(["B", "C"]);
    } finally { c.stop(); }
  });
  it("persists retained account archives immediately on acceptance before refresh can finish", async () => {
    let clock = at, redeemed = false;
    const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
    const q = quota("codex", [], at); q.resetCredits = [{ id: "A", title: "Full reset", status: "available" }];
    const c = new Coordinator(launch, prefs, [{ slot: primary("codex"), quota: async () => redeemed ? new Promise<Quota>(() => {}) : q, consumeReset: async () => { redeemed = true; return true; } }], () => clock);
    try {
      await c.refresh(); c.archived["claude#retained-account"] = quota("claude", [window("5-hour", 25)], at); clock++;
      const pending = c.confirmReset(c.prepareReset("codex", "A").token); await Promise.resolve(); await Promise.resolve();
      expect(readArchive(join(root, "quota-archive.json"))["claude#retained-account"]?.windows[0].usedPercent).toBe(25);
      c.stop(); await pending;
    } finally { c.stop(); }
  });
  it("rejects a confirmation when its account source has been replaced", async () => {
    const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
    const q = quota("codex", [], at); q.resetCredits = [{ id: "A", title: "Full reset", status: "available" }];
    let callsA = 0, callsB = 0;
    const a = { slot: primary("codex"), quota: async () => q, consumeReset: async () => { callsA++; return true; } };
    const c = new Coordinator(launch, prefs, [a], () => at);
    try {
      await c.refresh(); const confirmation = c.prepareReset("codex", "A");
      c.sources = [{ ...a, consumeReset: async () => { callsB++; return true; } }];
      await expect(c.confirmReset(confirmation.token)).rejects.toThrow();
      expect(callsA).toBe(0); expect(callsB).toBe(0); expect(c.archived.codex.resetCredits[0].id).toBe("A");
    } finally { c.stop(); }
  });
  it("does not apply an old account's accepted reset to a replacement source", async () => {
    const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
    const old = quota("codex", [window("5-hour", 82)], at); old.resetCredits = [{ id: "old-credit", title: "Old reset", status: "available" }];
    const current = quota("codex", [window("5-hour", 7)], at + 1); current.resetCredits = [{ id: "current-credit", title: "Current reset", status: "available" }];
    let accept!: (result: boolean) => void;
    const c = new Coordinator(launch, prefs, [{ slot: primary("codex"), quota: async () => old, consumeReset: async () => new Promise<boolean>(resolve => { accept = resolve; }) }], () => at + 1);
    try {
      await c.refresh(); const reset = c.confirmReset(c.prepareReset("codex", "old-credit").token);
      c.sources = [{ slot: primary("codex"), quota: async () => current, consumeReset: async () => true }]; await c.refresh();
      accept(true); await expect(reset).rejects.toThrow();
      expect(c.quotas.codex).toEqual({ status: "value", value: current }); expect(c.archived.codex).toEqual(current);
    } finally { c.stop(); }
  });

});
