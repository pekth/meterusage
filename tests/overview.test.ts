import { describe, it, expect, afterEach } from "vite-plus/test";
import { stripTotals, attributionSessions, failoverNudge, heatmapCells } from "../src/domain/overview";
import { type Activity, type Session, type Usage, tokens, primary, quota, window, value, totalTokens } from "../src/domain/models";
const now = Date.parse("2026-10-06T12:00:00Z"), day = 86400000;
const session = (changes: Partial<Session> = {}): Session => ({ id: "fixture", projectName: "Example", model: "Known", tokens: tokens({ input: 10 }), estimatedCostUSD: .1, startedAt: now, messageCount: 3, ...changes });
const activity = (sessions: Session[] = []): Activity => ({ provider: "codex", sessions, daily: [], scannedAt: now });
const usage = (changes: Partial<Usage> = {}): Usage => ({ provider: "openCodeGo", sessionCount: 10, messageCount: 1000, todaySessionCount: 1, todayMessageCount: 10, capturedAt: now, ...changes });
const originalTZ = process.env.TZ; afterEach(() => { if (originalTZ === undefined) delete process.env.TZ; else process.env.TZ = originalTZ; });
describe("Swift overview parity", () => {
  it("counts overlapping sessions in local today and uses seven UTC buckets for week", () => {
    process.env.TZ = "America/New_York";
    const a = activity([session({ startedAt: Date.parse("2026-10-06T03:00:00Z"), lastActivityAt: Date.parse("2026-10-06T05:00:00Z") }), session({ startedAt: Date.parse("2026-10-06T01:00:00Z"), lastActivityAt: Date.parse("2026-10-06T02:00:00Z"), tokens: tokens({ input: 999 }) })]);
    a.daily = [0, 6, 7].map(n => ({ day: Date.parse("2026-10-06T00:00:00Z") - n * day, tokens: tokens({ input: n === 7 ? 999 : 20 }), sessionCount: 1, estimatedCostUSD: 0 }));
    expect(stripTotals([a], [usage({ todayTokens: tokens({ input: 5 }), weekTokens: tokens({ input: 7 }), todayCostUSD: .2 })], now)).toEqual({ todayTokens: 15, weekTokens: 47, todayCost: .1 + .2 });
    expect(stripTotals([], [usage({ todayTokens: tokens(), weekTokens: tokens() })], now).todayTokens).toBe(0);
    expect(stripTotals([activity([session({ tokens: tokens() })])], [usage()], now).todayTokens).toBeUndefined();
  });
  it("uses project-level week aggregates with zero turns and no invented model", () => {
    const rows = attributionSessions([primary("codex"), primary("openCodeGo"), primary("openRouter")], { codex: value(activity([session()])) }, { openCodeGo: value(usage({ weekTokens: tokens({ input: 100 }), projectBreakdown: [{ project: "Repo A", tokens: tokens({ input: 30 }) }, { project: "Repo B", tokens: tokens({ input: 70 }) }] })), openRouter: value({ ...usage({ weekTokens: tokens({ input: 50 }) }), provider: "openRouter" }) }, now);
    expect(rows.reduce((n, r) => n + totalTokens(r.tokens), 0)).toBe(160);
    expect(rows.filter(r => r.isAggregate).map(r => [r.projectName, r.model, r.messageCount])).toEqual([["Repo A", "", 0], ["Repo B", "", 0], ["OpenRouter", "", 0]]);
  });
  it("never suggests hot slots or calls an old burst current burn", () => {
    const slots = [primary("codex"), primary("claude")], q = { codex: value(quota("codex", [window("5-hour", 85, now + 4 * 3600000, 300)])), claude: value(quota("claude", [window("5-hour", 5)])) };
    expect(failoverNudge(slots, q, {}, now)).toBe("Codex near its 5-hour limit. Switch to Claude for headroom.");
    expect(failoverNudge(slots, q, { codex: value(activity([session()])) }, now)).toBe("Codex burning fast. Switch to Claude for headroom.");
    q.claude = value(quota("claude", [window("5-hour", 90)])); expect(failoverNudge(slots, q, {}, now)).toBeUndefined();
  });
  it("aligns 26 heatmap columns to local Sunday and leaves future rows empty", () => {
    process.env.TZ = "America/New_York";
    const daily = [0, 1].map(i => ({ day: Date.parse(`2026-10-0${5 + i}T12:00:00Z`), tokens: tokens({ input: 10 + i }), estimatedCostUSD: 0, sessionCount: 1 }));
    for (const mode of ["daily", "weekly", "cumulative"] as const) {
      const cells = heatmapCells(daily, now, mode); expect(cells).toHaveLength(182); expect(new Date(cells[0]!.day).getDay()).toBe(0); expect(cells.slice(-4)).toEqual([null, null, null, null]);
      expect(cells.at(-5)?.tokens).toBe(mode === "daily" ? 11 : 21);
    }
    const dst = heatmapCells([], Date.parse("2026-11-03T12:00:00Z"), "daily").filter(c => c !== null);
    expect(dst.every(c => new Date(c.day).getHours() === 0)).toBe(true);
  });
});
