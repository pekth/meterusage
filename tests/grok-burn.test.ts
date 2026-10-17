import { afterEach, describe, expect, it } from "vite-plus/test";
import { mkdtempSync, readFileSync, realpathSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { primary, quota, Unavailable, window, type Quota, type QuotaWindow } from "../src/domain/models";
import { measuredBurn, observeQuota, pace } from "../src/domain/pacing";
import { Coordinator } from "../src/main/coordinator";
import type { Source } from "../src/main/composition";
import { readArchive, saveArchive } from "../src/main/history";
import { launchConfiguration } from "../src/main/launch";
import { Preferences } from "../src/main/preferences";

const at = Date.parse("2026-10-16T12:00:00Z"), minute = 60000, hour = 3600000;
const roots: string[] = [], coordinators: Coordinator[] = [];
const temp = () => { const root = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-fixture-")); roots.push(root); return root; };
afterEach(() => { for (const c of coordinators.splice(0)) c.stop(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const reading = (used: number, capturedAt = at, resetsAt?: number) => quota("grok", [window("Allowance", used, resetsAt)], capturedAt);
const observe = (used: number, capturedAt: number, previous?: Quota, resetsAt?: number, now = capturedAt) => observeQuota(reading(used, capturedAt, resetsAt), previous, now);
const burn = (q: Quota, now = q.capturedAt) => measuredBurn(q.windows[0], now);

async function setup(source: Source, now: () => number, root = temp()) {
  const launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
  prefs.values.desktopGrokSource = "bot";
  const c = new Coordinator(launch, prefs, [source], now); coordinators.push(c);
  const live = () => { const state = c.quotas.grok; expect(state.status).toBe("value"); if (state.status !== "value") throw new Error("Expected quota"); return state.value; };
  return { c, prefs, live, root };
}

describe("measured percentage burn independent of cycle pace", () => {
  it("requires distinct observations spanning a minute, without inventing a cycle", () => {
    const first = observe(20, at);
    expect(burn(first)).toBeUndefined();
    expect(burn(observe(21, at + minute - 1, first))).toBeUndefined();
    expect(burn(observe(21, at, first))).toBeUndefined();
    const next = observe(22, at + minute, first);
    expect(burn(next)).toEqual({ percentPerHour: 120, projectedExhaustion: at + minute + 78 / 120 * hour });
    expect(pace(next.windows[0], next.capturedAt)).toBeUndefined();
    expect(next.windows[0].windowDurationMins).toBeUndefined();
  });

  it("retains the first sample across shorter polls and measures zero only after a minute", () => {
    const first = observe(20, at), short = observe(20, at + minute / 2, first);
    expect(burn(short)).toBeUndefined();
    const unchanged = observe(20, at + minute, short);
    expect(burn(unchanged)).toEqual({ percentPerHour: 0 });
    expect(burn(observe(21, at + 2 * minute, unchanged))?.percentPerHour).toBe(30);
  });

  it("uses a reported reset only to bound exhaustion, with no fabricated cadence", () => {
    for (const reset of [undefined, at + hour, at + 10 * minute]) {
      const next = observe(22, at + minute, observe(20, at, undefined, reset), reset);
      expect(burn(next)?.percentPerHour).toBe(120);
      expect(burn(next)?.projectedExhaustion !== undefined).toBe(reset === undefined || reset === at + hour);
    }
    const full = observe(100, at + minute, observe(99, at));
    expect(burn(full)).toEqual({ percentPerHour: 60 });
    const nearlyFull = observe(99, at + minute, observe(98, at));
    expect(burn(nearlyFull, at + 2 * minute)).toEqual({ percentPerHour: 60 });
  });

  it.each(["decrease", "reset", "reset-added", "reset-removed", "expired"])("clears measurement on %s", change => {
    const reset = at + hour, first = observe(20, at, undefined, reset), next = observe(22, at + minute, first, reset);
    const renewed = observe(change === "decrease" ? 5 : 23, at + 2 * minute, next,
      change === "reset" ? reset + hour : change === "reset-removed" ? undefined : change === "expired" ? at + 2 * minute : reset);
    if (change === "reset-added") {
      expect(burn(observe(23, at + 2 * minute, observe(22, at + minute, observe(20, at)), reset))).toBeUndefined();
    } else expect(burn(renewed)).toBeUndefined();
    expect(burn(next, reset)).toBeUndefined();
  });

  it.each(["stale", "future", "out-of-order", "duplicate", "nonfinite"])("rejects %s readings and cannot revive them as time passes", kind => {
    const first = observe(20, at), valid = observe(22, at + minute, first), now = at + 2 * minute;
    const timestamp = kind === "stale" ? now - 5 * minute - 1 : kind === "future" ? now + 1 : kind === "out-of-order" ? at + minute - 1 : kind === "duplicate" ? valid.capturedAt : NaN;
    const invalid = observe(23, timestamp, valid, undefined, now);
    expect(invalid.windows[0].pacingBaseline).toBeUndefined();
    expect(burn(invalid, now + minute)).toBeUndefined();
    const fresh = observe(24, now + minute, invalid);
    expect(burn(fresh)).toBeUndefined();
    expect(burn(observe(25, now + 2 * minute, fresh))?.percentPerHour).toBe(60);
  });

  it("expires old measurements and reanchors after a long gap", () => {
    const first = observe(20, at), next = observe(22, at + minute, first);
    expect(burn(next, at + 5 * minute)?.percentPerHour).toBe(120);
    expect(burn(next, at + 5 * minute + 1)).toBeUndefined();
    expect(burn(next, at + minute - 1)).toBeUndefined();
    const resumed = observe(23, at + 7 * minute, next);
    expect(burn(resumed)).toBeUndefined();
    expect(burn(observe(24, at + 8 * minute, resumed))?.percentPerHour).toBe(60);
  });

  it("rejects malformed baseline, percentage and reset fields", () => {
    const good = observe(22, at + minute, observe(20, at)).windows[0];
    const invalid: QuotaWindow[] = [
      { ...good, usedPercent: NaN }, { ...good, usedPercent: -1 }, { ...good, usedPercent: 101 }, { ...good, resetsAt: Infinity },
      ...[{ usedPercent: 30, capturedAt: at, observedAt: at + minute }, { usedPercent: NaN, capturedAt: at, observedAt: at + minute },
        { usedPercent: 20, capturedAt: at + minute, observedAt: at }, { usedPercent: 20, capturedAt: at, observedAt: Infinity },
        { usedPercent: 20, capturedAt: at }, { usedPercent: 20, observedAt: at + minute }].map(pacingBaseline => ({ ...good, pacingBaseline })),
    ];
    for (const w of invalid) expect(measuredBurn(w, at + minute)).toBeUndefined();
    expect(measuredBurn(good, NaN)).toBeUndefined();
  });

  it("keeps group/window identities separate and ignores incoming baselines", () => {
    const make = (time: number, used: number): Quota => ({ ...reading(used, time), groups: [
      { id: "a", title: "A", windows: [window("Allowance", used)] },
      { id: "b", title: "B", windows: [window("Allowance", used + 10)] },
    ] });
    const first = observeQuota(make(at, 20), undefined, at), next = make(at + minute, 22);
    next.groups[0].windows[0].usedPercent = 21; next.groups[1].windows[0].label = "New window";
    const result = observeQuota(next, first, next.capturedAt);
    expect(measuredBurn(result.groups[0].windows[0], next.capturedAt)?.percentPerHour).toBe(60);
    expect(measuredBurn(result.groups[1].windows[0], next.capturedAt)).toBeUndefined();
    expect(burn(observeQuota({ ...next, windows: [observe(22, at + minute, observe(20, at)).windows[0]] }, undefined, next.capturedAt))).toBeUndefined();
  });
});

describe("Grok Bot coordinator lifecycle and archive isolation", () => {
  it("publishes live measured data but strips measurements from in-memory and persisted archives", async () => {
    let clock = at, used = 20;
    const { c, live, root } = await setup({ slot: primary("grok"), accountBound: true, quota: async () => reading(used, clock) }, () => clock);
    await c.refresh(); expect(burn(live())).toBeUndefined();
    clock += minute; used = 22; await c.refresh();
    expect(burn(live())?.percentPerHour).toBe(120);
    const snapshot = c.snapshot();
    expect(snapshot.quotas.grok.status === "value" && burn(snapshot.quotas.grok.value)?.percentPerHour).toBe(120);
    expect(burn(snapshot.archived.grok, clock)).toBeUndefined();
    expect(readFileSync(join(root, "quota-archive.json"), "utf8")).not.toContain("pacingBaseline");
    expect(readArchive(join(root, "quota-archive.json")).grok.windows[0].usedPercent).toBe(22);
  });

  it("does not seed measurements from a legacy archive or a new coordinator session", async () => {
    let clock = at + minute;
    const root = temp(), saved = observe(22, clock, observe(20, at));
    launchConfiguration(["--demo", "--candidate-profile", root], {});
    saved.groups = [{ id: "a", title: "A", windows: saved.windows }];
    saveArchive(join(root, "quota-archive.json"), [{ slot: primary("grok"), quota: saved }]);
    const source: Source = { slot: primary("grok"), accountBound: true, quota: async () => reading(24, clock) };
    const { c, live } = await setup(source, () => clock, root);
    expect(burn(c.snapshot().archived.grok, clock)).toBeUndefined();
    expect(measuredBurn(c.snapshot().archived.grok.groups[0].windows[0], clock)).toBeUndefined();
    clock += minute; await c.refresh(); expect(burn(live())).toBeUndefined();
    clock += minute; await c.refresh(); expect(burn(live())).toEqual({ percentPerHour: 0 });
    c.stop();
    const next = new Coordinator(c.launch, c.preferences, [source], () => clock); coordinators.push(next);
    clock += minute; await next.refresh();
    const state = next.quotas.grok;
    expect(state.status === "value" && burn(state.value)).toBeUndefined();
  });

  it("clears measurements on reconnect, disconnect and quota forgetting", async () => {
    let clock = at, used = 20;
    const source: Source = { slot: primary("grok"), accountBound: true, quota: async () => reading(used, clock) };
    const { c, live } = await setup(source, () => clock);
    const collect = async () => { clock += minute; await c.refresh(); clock += minute; used++; await c.refresh(); expect(burn(live())?.percentPerHour).toBeGreaterThan(0); };
    await collect();
    c.sources = [{ ...source }]; clock += minute; await c.refresh(); expect(burn(live())).toBeUndefined();
    await collect();
    c.sources = []; expect(c.quotas.grok).toBeUndefined(); expect(burn(c.archived.grok, clock)).toBeUndefined();
    c.sources = [source]; clock += minute; await c.refresh(); expect(burn(live())).toBeUndefined();
    await collect(); c.forgetQuota("grok"); expect(c.archived.grok).toBeUndefined();
    clock += minute; await c.refresh(); expect(burn(live())).toBeUndefined();
  });

  it("rejects an old account's in-flight response after source replacement", async () => {
    let clock = at, hold = false, started!: () => void, release!: (q: Quota) => void;
    const ready = new Promise<void>(resolve => { started = resolve; });
    const old: Source = { slot: primary("grok"), accountBound: true, quota: async () => {
      if (!hold) return reading(80, clock);
      started(); return new Promise<Quota>(resolve => { release = resolve; });
    } };
    const { c, live } = await setup(old, () => clock);
    await c.refresh(); clock += minute; await c.refresh(); expect(burn(live())?.percentPerHour).toBe(0);
    hold = true; const pending = c.refresh(); await ready;
    c.forgetQuota("grok"); c.sources = [{ slot: primary("grok"), accountBound: true, quota: async () => reading(10, clock) }];
    clock += minute; release(reading(90, clock)); await pending;
    expect(live().windows[0].usedPercent).toBe(10); expect(burn(live())).toBeUndefined();
    clock += minute; await c.refresh(); expect(burn(live())).toEqual({ percentPerHour: 0 });
  });

  it.each(["offline", "notSignedIn", "noData"] as const)("does not revive measurements after %s", async failure => {
    let clock = at, fail = false;
    const { c, live } = await setup({ slot: primary("grok"), accountBound: true, quota: async () => {
      if (fail) throw new Unavailable(failure); return reading(20, clock);
    } }, () => clock);
    await c.refresh(); clock += minute; await c.refresh(); expect(burn(live())?.percentPerHour).toBe(0);
    fail = true; clock += minute; await c.refresh(); expect(c.quotas.grok.status).toBe("missing");
    if (failure === "offline") expect(burn(c.archived.grok, clock)).toBeUndefined();
    else expect(c.archived.grok).toBeUndefined();
    fail = false; clock += minute; await c.refresh(); expect(burn(live())).toBeUndefined();
  });

  it("leaves legacy Cursor and non-account Grok sources without observations", async () => {
    let clock = at;
    const source: Source = { slot: primary("grok"), accountBound: true, quota: async () => reading(20, clock) };
    const { c, prefs, live } = await setup(source, () => clock);
    prefs.values.desktopGrokSource = "cursor";
    await c.refresh(); clock += minute; await c.refresh(); expect(live().windows[0].pacingBaseline).toBeUndefined();
    prefs.values.desktopGrokSource = "bot"; c.sources = [{ ...source, accountBound: false }];
    await c.refresh(); clock += minute; await c.refresh(); expect(live().windows[0].pacingBaseline).toBeUndefined();
  });
});
