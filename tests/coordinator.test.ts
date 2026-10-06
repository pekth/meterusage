import { describe, it, expect, afterEach } from "vite-plus/test";
import { mkdtempSync, writeFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Coordinator, backoffDelay } from "../src/main/coordinator";
import { Preferences } from "../src/main/preferences";
import { launchConfiguration } from "../src/main/launch";
import { compose, type Source } from "../src/main/composition";
import { primary, slotKey, quota, window, value, missing, tokens, Unavailable } from "../src/domain/models";
import { AlertEvaluator } from "../src/domain/alerts";
const roots: string[] = [], controllers: Coordinator[] = []; const temp = () => { const root = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); roots.push(root); return root; };
afterEach(() => { for (const c of controllers.splice(0)) c.stop(); for (const root of roots.splice(0)) rmSync(root, { force: true, recursive: true }); });
const now = Date.parse("2026-10-06T12:00:00Z");
async function setup(sources?: Source[], time = () => now) { const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch); const c = new Coordinator(launch, prefs, sources ?? compose(launch, prefs, { now: time }), time); controllers.push(c); return { c, root, prefs }; }
describe("coordinator refresh journey", () => {
  it("classifies empty activity as no data, while retained durable days remain loaded", async () => {
    const { c } = await setup([{ slot: primary("claude"), activity: async () => ({ provider: "claude", scannedAt: now, sessions: [], daily: [] }) }]);
    await c.refresh(); expect(c.activities.claude).toMatchObject({ status: "missing", code: "noData" }); expect(c.diagnostics()).toContain("activity: unavailable (noData)");
    c.history.record("claude", [{ day: now, tokens: tokens({ input: 5 }), sessionCount: 1, estimatedCostUSD: 0 }]);
    await c.refresh(); const a = c.activities.claude; expect(a.status).toBe("value"); if (a.status === "value") expect(a.value.daily[0].tokens.input).toBe(5);
  });
  it("backs off transient failures, bypasses them for explicit refresh, and keeps archive visibly separate", async () => {
    let at = now, count = 0, fail = false;
    const { c } = await setup([{ slot: primary("codex"), quota: async () => { count++; if (fail) throw new Unavailable("offline"); return quota("codex", [window("5-hour", 42)], at); } }], () => at);
    await c.refresh(); fail = true; await c.refresh(true); expect(count).toBe(2);
    at += 1000; await c.refresh(true); expect(count).toBe(2);
    expect(c.snapshot().quotas.codex.status).toBe("missing"); expect(c.snapshot().archived.codex.windows[0].usedPercent).toBe(42); expect(JSON.parse(c.json()).providers[0].status).toBe("unavailable");
    await c.refresh(); expect(count).toBe(3); expect(backoffDelay(999)).toBe(1800000);
  });
  it("coalesces active sweeps and honors one queued explicit refresh after a scheduled sweep", async () => {
    let release!: () => void, count = 0; const paused = new Promise<void>(resolve => { release = resolve; });
    const { c } = await setup([{ slot: primary("codex"), quota: async () => { count++; if (count === 1) await paused; return quota("codex", [], now); } }]);
    const first = c.refresh(true); await Promise.resolve(); c.refresh(true); c.refresh(); c.refresh(); release(); await first;
    expect(count).toBe(2); expect(c.snapshot().refreshing).toBe(false);
  });
  it("does not back off permanent no-data conditions and polls health when usage is hidden", async () => {
    let reads = 0, statuses = 0; const { c, prefs } = await setup([{ slot: primary("codex"), quota: async () => { reads++; throw new Unavailable("noData"); }, status: async () => { statuses++; return { provider: "codex", severity: "operational", description: "All systems operational", checkedAt: now }; } }]);
    await c.refresh(true); await c.refresh(true); expect(reads).toBe(2); await prefs.set("showProviderCodex", false); await c.refresh(true); expect(reads).toBe(2); expect(statuses).toBe(3);
  });
  it("preserves corrupt durable history while still returning current activity and sanitized diagnostics", async () => {
    const { c, root } = await setup(); c.stop(); const path = join(root, "durable-daily-history.json"); writeFileSync(path, "CORRUPT_HISTORY");
    const launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch), next = new Coordinator(launch, prefs, compose(launch, prefs, { now: () => now }), () => now); controllers.push(next);
    await next.refresh(); expect(next.snapshot().historyError).toBe("loadFailed"); expect(next.snapshot().activities.claude.status).toBe("value"); expect(readFileSync(path, "utf8")).toBe("CORRUPT_HISTORY");
    expect(next.diagnostics()).not.toContain(root); expect(next.diagnostics()).not.toContain("demo-second"); expect(next.diagnostics()).toContain("history: loadFailed");
  });
  it("retains larger historic readings after a transcript disappears and keeps accounts separate", async () => {
    let amount = 100; const second = { provider: "claude" as const, slotID: "demo-second", label: "Second" };
    const source = (slot: typeof second | ReturnType<typeof primary>, n: () => number): Source => ({ slot, activity: async () => ({ provider: "claude", scannedAt: now, sessions: [], daily: [{ day: now - 43200000, tokens: tokens({ output: n() }), estimatedCostUSD: 0, sessionCount: 1 }] }) });
    const { c } = await setup([source(primary("claude"), () => amount), source(second, () => 7)]);
    await c.refresh(); amount = 10; await c.refresh(); expect(c.history.records("claude")[0].tokens.output).toBe(100); expect(c.history.records(slotKey(second))[0].tokens.output).toBe(7);
    const a = c.activities.claude; expect(a.status).toBe("value");
    if (a.status === "value") { expect(a.value.daily).toHaveLength(1); expect(a.value.daily[0].tokens.output).toBe(100); }
  });
  it("merges local-midnight readings with the same UTC archive date without double counting", async () => {
    const { c } = await setup([{ slot: primary("claude"), activity: async () => ({ provider: "claude", scannedAt: now, sessions: [], daily: [{ day: Date.parse("2026-10-06T05:00:00Z"), tokens: tokens({ input: 10 }), estimatedCostUSD: 0, sessionCount: 1 }] }) }]);
    c.history.record("claude", [{ day: Date.parse("2026-10-06T00:00:00Z"), tokens: tokens({ input: 100 }), estimatedCostUSD: 1, sessionCount: 2 }]);
    await c.refresh(); const a = c.activities.claude; expect(a.status).toBe("value");
    if (a.status === "value") { expect(a.value.daily).toHaveLength(1); expect(a.value.daily[0].tokens.input).toBe(100); }
  });
  it("clears only owned scan caches and preserves history, archive and foreign files", async () => {
    const { c, root } = await setup(); await c.refresh();
    writeFileSync(join(root, "claude-local-scan-cache.json"), "cached"); writeFileSync(join(root, "claude-local-scan-cache-account-id.json"), "cached"); writeFileSync(join(root, "foreign.json"), "foreign");
    await c.clearCache(); expect(existsSync(join(root, "claude-local-scan-cache.json"))).toBe(false); expect(existsSync(join(root, "claude-local-scan-cache-account-id.json"))).toBe(false); expect(readFileSync(join(root, "foreign.json"), "utf8")).toBe("foreign"); expect(existsSync(join(root, "quota-archive.json"))).toBe(true); expect(existsSync(join(root, "durable-daily-history.json"))).toBe(true);
  });
});
describe("explicit per-account reset journey", () => {
  it("discards every late reading from a replaced source, including failures and durable writes", async () => {
    let hold = false, release!: () => void;
    const paused = new Promise<void>(resolve => { release = resolve; }), slot = { provider: "codex" as const, slotID: "demo-second", label: "Account" }, key = slotKey(slot);
    const old: Source = { slot, quota: async () => { if (hold) await paused; const q = quota("codex", [window("5-hour", hold ? 99 : 82)], now); q.resetCredits = [{ id: "old-credit", title: "Old reset", status: "available" }]; return q; }, activity: async () => { if (hold) await paused; return { provider: "codex", scannedAt: now, sessions: [], daily: [{ day: now, tokens: tokens({ input: hold ? 100 : 5 }), sessionCount: 1, estimatedCostUSD: 0 }] }; }, usage: async () => { if (hold) await paused; throw new Unavailable("offline"); }, plan: async () => { if (hold) await paused; return "old-plan"; }, consumeReset: async () => true };
    const { c } = await setup([old]); await c.refresh(); hold = true;
    const pending = c.refresh(); await Promise.resolve();
    c.sources = [{ slot, quota: async () => { throw new Unavailable("offline"); }, consumeReset: async () => true }];
    const seen: number[] = []; c.subscribe(s => { const q = s.quotas[key]; if (q?.status === "value") seen.push(q.value.windows[0].usedPercent); });
    release(); await pending;
    expect(seen).toEqual([]); expect(c.quotas[key].status).toBe("missing");
    expect(c.activities[key]).toBeUndefined(); expect(c.usages[key]).toBeUndefined(); expect(c.plans[key]).toBeUndefined();
    expect(c.archived[key].windows[0].usedPercent).toBe(82); expect(c.history.records(key)[0].tokens.input).toBe(5);
    expect(() => c.prepareReset(key, "old-credit")).toThrow("unavailable");
  });
  it("requires current-source readings after account replacement, while preserving dated history", async () => {
    const slot = { provider: "codex" as const, slotID: "demo-second", label: "Account" }, key = slotKey(slot);
    const oldQuota = quota("codex", [window("5-hour", 82)], now); oldQuota.resetCredits = [{ id: "old-credit", title: "Old reset", status: "available" }];
    const nextQuota = quota("codex", [window("5-hour", 7)], now); nextQuota.resetCredits = [{ id: "new-credit", title: "New reset", status: "available" }];
    const stable = { slot: primary("claude"), quota: async () => quota("claude", [window("5-hour", 34)], now) };
    const old: Source = { slot, quota: async () => oldQuota, activity: async () => ({ provider: "codex", scannedAt: now, sessions: [], daily: [{ day: now, tokens: tokens({ input: 5 }), sessionCount: 1, estimatedCostUSD: 0 }] }), usage: async () => ({ provider: "codex", capturedAt: now, sessionCount: 1, messageCount: 2, todaySessionCount: 1, todayMessageCount: 2 }), plan: async () => "old-plan", consumeReset: async () => true };
    const { c } = await setup([old, stable]); await c.refresh();
    c.sources = [{ slot, quota: async () => nextQuota, consumeReset: async () => true }, stable];
    for (const readings of [c.quotas, c.activities, c.usages, c.plans]) expect(readings[key]).toBeUndefined();
    expect(c.quotas.claude.status).toBe("value"); expect(c.archived[key].windows[0].usedPercent).toBe(82); expect(c.history.records(key)[0].tokens.input).toBe(5);
    expect(() => c.prepareReset(key, "old-credit")).toThrow("unavailable");
    await c.refresh(); expect(c.quotas[key]).toMatchObject({ status: "value", value: { windows: [{ usedPercent: 7 }] } });
    expect(() => c.prepareReset(key, "old-credit")).toThrow("unavailable");
    const current = c.prepareReset(key, "new-credit"); c.cancelReset(current.token);
  });
  it("cancellation and duplicate confirmation cannot consume and one accepted fixture changes only its account", async () => {
    let at = now; const { c } = await setup(undefined, () => at); await c.refresh();
    const key = "codex#demo-second", cancelled = c.prepareReset(key, "demo-reset-1"); c.cancelReset(cancelled.token); await expect(c.confirmReset(cancelled.token)).rejects.toThrow("expired");
    const accepted = c.prepareReset(key, "demo-reset-1"); await c.confirmReset(accepted.token); await expect(c.confirmReset(accepted.token)).rejects.toThrow("expired");
    expect(c.quotas[key].status).toBe("missing"); expect(c.archived[key].resetCreditCount).toBe(1);
    at += 1; await c.refresh();
    const primary = c.quotas.codex, alternate = c.quotas[key]; expect(primary.status === "value" && primary.value.resetCreditCount).toBe(2); expect(alternate.status === "value" && alternate.value.resetCreditCount).toBe(1);
    expect(primary.status === "value" && primary.value.windows[0].usedPercent).toBe(82); expect(alternate.status === "value" && alternate.value.windows[0].usedPercent).toBe(0);
  });
  it("rejects stale credit and expired intent instead of routing it to another account", async () => {
    let at = now; const { c } = await setup(undefined, () => at); await c.refresh();
    expect(() => c.prepareReset("claude", "demo-reset-1")).toThrow("unavailable");
    const intent = c.prepareReset("codex", "demo-reset-1"); at += 60001; await expect(c.confirmReset(intent.token)).rejects.toThrow("expired");
  });
});
describe("alert edge and recency parity", () => {
  it("alerts only highest threshold, re-arms after reset and isolates accounts", () => {
    const a = primary("codex"), b = { provider: "codex" as const, slotID: "other", label: "Other" }, evaluator = new AlertEvaluator();
    const state = (used: number) => value(quota("codex", [window("5-hour", used)], now));
    expect(evaluator.events([a, b], { codex: state(96), "codex#other": state(82) }, {}, now).map(e => e.title)).toEqual(["Quota almost gone", "Quota getting low"]);
    expect(evaluator.events([a], { codex: state(96) }, {}, now)).toEqual([]); evaluator.events([a], { codex: state(0) }, {}, now); expect(evaluator.events([a], { codex: state(82) }, {}, now)).toHaveLength(1);
  });
  it("requires current burn for pace warnings and deduplicates expiring credits", () => {
    const a = primary("codex"), q = quota("codex", [window("5-hour", 65, now + 4 * 3600000, 300)], now); q.resetCredits = [{ id: "fixture", title: "Full reset", status: "available", expiresAt: now + 3600000 }];
    const evaluator = new AlertEvaluator(); expect(evaluator.events([a], { codex: value(q) }, {}, now).map(e => e.kind)).toEqual(["expiringCredit"]);
    expect(evaluator.events([a], { codex: value(q) }, { codex: now }, now).map(e => e.kind)).toContain("paceSoftWarning"); expect(evaluator.events([a], { codex: value(q) }, { codex: now }, now)).toEqual([]);
    expect(evaluator.events([a], { codex: missing(new Unavailable("offline"), "codex") }, {}, now)).toEqual([]);
  });
});
