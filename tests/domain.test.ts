import { describe, expect, it } from "vite-plus/test";
import { mkdtempSync, readFileSync, writeFileSync, mkdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { tokens, window, quota, primary, slotKey, headlineWindow, value, missing, Unavailable, type Session, type Daily } from "../src/domain/models";
import { pace, effectivePace, burnActive, etaSeconds, formatETA, paceText } from "../src/domain/pacing";
import { limitsReport, canonicalJSON } from "../src/domain/report";
import { estimate } from "../src/domain/pricing";
import { burnBreakdown, telemetry } from "../src/domain/telemetry";
import { notchFrame } from "../src/domain/notch";
import { HistoryStore, readArchive, saveArchive } from "../src/main/history";

const now = Date.UTC(2026, 9, 6, 12), day = 86400000;
const session = (changes: Partial<Session> = {}): Session => ({ id: "synthetic", projectName: "example", model: "gpt-6.1-sol", tokens: tokens({ input: 100 }), estimatedCostUSD: .0002, startedAt: now - 10000, messageCount: 2, ...changes });
// Cases are ported from the existing Swift suites named below. Expectations
// are fixed behavior contracts, independent of the TypeScript implementation.
describe("Swift telemetry/pacing and burn-recency parity", () => {
  it("keeps raw weekly deficit and demotes only the quiet machine claim", () => {
    const raw = pace(window("Weekly", 30, now + 6 * day, 10080), now)!;
    expect(raw.status).toBe("deficit"); expect(raw.burnRate).toBeCloseTo(2.1);
    expect(raw.elapsedPercent).toBeCloseTo(100 / 7);
    expect(effectivePace(raw, undefined, now)).toMatchObject({ status: "onPace", burnRate: 1, deficitPercent: 0 });
    expect(effectivePace(raw, now - 60000, now)).toEqual(raw);
    expect(burnActive(now + 1, now)).toBe(false); expect(burnActive(now - 1800000, now)).toBe(false);
  });
  it("preserves exhausted reset ETA and zero used percent", () => {
    const w = window("5-hour", 100, now + 6900000, 300), p = pace(w, now)!;
    expect(paceText(p)).toBe("exhausted early"); expect(etaSeconds(p, w.resetsAt, now)).toBe(6900);
    expect(formatETA(6900)).toBe("1h 55m left"); expect(formatETA(59)).toBe("< 1m left");
    expect(window("5-hour", 0).usedPercent).toBe(0);
    expect(pace(window("Weekly", 40, now - 1), now)).toBeUndefined();
  });
  it("does not switch the Codex headline to a weekly limit after a session reset", () => {
    const zero = window("5-hour", 0), weekly = window("Weekly", 95);
    expect(headlineWindow("codex", [weekly, zero])).toBe(zero);
    expect(headlineWindow("codex", [weekly])).toBe(weekly);
    expect(headlineWindow("claude", [window("Weekly · Fable", 90)])).toBeUndefined();
    expect(headlineWindow("openCodeGo", [weekly, window("Rolling", 1)])?.usedPercent).toBe(1);
  });
  it.each(["cursor", "copilot", "gemini"] as const)("uses the session-first supplemental %s headline", provider => {
    const session = window("Session", 10), weekly = window("Weekly", 90);
    expect(headlineWindow(provider, [weekly, session])).toBe(session);
    expect(headlineWindow(provider, [weekly, window("Monthly", 20)])).toBe(weekly);
  });
  it("matches the pricing table and flags unknown models", () => {
    const t = tokens({ input: 1e6, output: 1e6, reasoning: 1e6, cacheRead: 1e6, cacheWrite: 1e6 });
    expect(estimate("gpt-6.1-sol", t)).toEqual({ costUSD: 22.1, isFallback: false });
    expect(estimate("gpt-5.6-sol", t).costUSD).toBe(44.4);
    expect(estimate("claude-fable", t).costUSD).toBe(123.5);
    expect(estimate("codex", t).isFallback).toBe(true);
  });
  it("hides unmeasured burn and excludes automation without treating aggregates as long chats", () => {
    expect(burnBreakdown([session({ tokens: tokens() })], now)).toBeUndefined();
    expect(burnBreakdown([session({ startedAt: now - 10 * day })], now, { since: now - 6 * day, fallbackToRecent: false })).toBeUndefined();
    const b = burnBreakdown([session({ isAggregate: true, tokens: tokens({ input: 200000 }) }), session({ isAutomation: true, tokens: tokens({ input: 900000 }) })], now)!;
    expect(b.totalTokens).toBe(200000); expect(b.longChatCount).toBe(0); expect(b.contributors[0].isLongChat).toBe(false); expect(b.contributors[0].shareOfWindow).toBe(100);
  });
  it("counts current/longest streaks and leaves unmeasured tokens absent", () => {
    const days: Daily[] = [0, 1, 2].map(n => ({ day: now - n * day, tokens: tokens({ input: n ? 10 : 0 }), estimatedCostUSD: 0, sessionCount: 1 }));
    const measured = telemetry([], days, now);
    expect(measured.currentStreakDays).toBe(3); expect(measured.longestStreakDays).toBe(3); expect(measured.todayTokens).toBe(0); expect(measured.dailyHistory).toHaveLength(30);
    const absent = telemetry([{ startedAt: now, tokens: 0, messageCount: 0 }], [], now);
    expect(absent.lifetimeTokens).toBeUndefined(); expect(absent.totalMessages).toBeUndefined(); expect(absent.totalSessions).toBe(1);
  });
});
describe("Swift LimitsReport and account-identity parity", () => {
  it("emits only regular windows, optional account labels and schema-1 fields", () => {
    const q = quota("codex", [window("5-hour", 0)]); q.groups = [{ id: "model", title: "Model", windows: [window("Weekly", 99)] }];
    q.credits = { balance: 25.5, unit: "credits", dollarBalance: 1.02, hasCredits: true, unlimited: false };
    const a = { provider: "codex" as const, slotID: "synthetic-account", label: "Work" };
    const r = limitsReport([primary("codex"), a, primary("grok"), primary("claude")], { codex: value(q), [slotKey(a)]: value(q), grok: missing(new Unavailable("cliNotFound", "grok"), "grok") }, {}, now);
    expect(r.schema).toBe(1); expect(r.generated_at).toBe("2026-10-06T12:00:00Z");
    expect(r.providers[0]).toEqual({ provider: "codex", status: "ok", windows: [{ label: "5-hour", used_percent: 0, remaining_percent: 100 }], credits: { balance: 25.5, unit: "credits", dollar_balance: 1.02 } });
    expect(r.providers[1].account).toBe("Work"); expect(r.providers[2].reason).toBe("grok CLI not found"); expect(r.providers[3].reason).toBeUndefined();
    expect(slotKey({ ...a, label: "Renamed" })).toBe(slotKey(a));
    expect(canonicalJSON(r)).not.toContain("synthetic-account"); expect(canonicalJSON(r)).not.toContain("model");
  });
  it("keeps quiet deficit on pace in the machine report", () => {
    const q = quota("codex", [window("Weekly", 85, now + 6 * day)]);
    expect(limitsReport([primary("codex")], { codex: value(q) }, {}, now).providers[0].windows[0].pacing).toBe("on pace");
    expect(limitsReport([primary("codex")], { codex: value(q) }, { codex: now - 60000 }, now).providers[0].windows[0].pacing).toBe("burning fast");
  });
});
describe("Swift durable history/archive compatibility", () => {
  function withFile(fn: (path: string) => void) { const root = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); try { fn(join(root, "history.json")); } finally { rmSync(root, { recursive: true, force: true }); } }
  const daily = (input: number): Daily[] => [{ day: now, tokens: tokens({ input }), estimatedCostUSD: .01, sessionCount: 1 }];
  it("rejects invalid optional archive metadata and drops unknown fields", () => withFile(path => {
    const q = quota("codex", [window("5-hour", 0)], now);
    q.groups = [{ id: "model", title: "Model", windows: q.windows }];
    q.resetCredits = [{ id: "credit", title: "Full reset", status: "available" }];
    q.credits = { balance: 0, unit: "credits", hasCredits: false, unlimited: false };
    saveArchive(path, [{ slot: primary("codex"), quota: q }]);
    const entry = JSON.parse(readFileSync(path, "utf8"))[0];
    for (const change of [{ planType: {} }, { slotID: {} }, { label: [] }, { resetCreditCount: "1" }, { resetCreditCount: 1.5 }, { groups: [{ ...entry.groups[0], title: {} }] }, { groups: [{ ...entry.groups[0], id: [] }] }, { resetCredits: [{ id: {}, title: "Reset" }] }, { resetCredits: [{ id: "c", title: {} }] }, { resetCredits: [{ id: "c", title: "Reset", status: {} }] }, { windows: [{ label: "5-hour", usedPercent: 0, windowDurationMins: {} }] }, { windows: [{ label: "5-hour", usedPercent: 0, windowDurationMins: 1.5 }] }]) {
      writeFileSync(path, JSON.stringify([{ ...entry, ...change }])); expect(readArchive(path)).toEqual({});
    }
    writeFileSync(path, JSON.stringify([{ ...entry, planType: null, credits: { ...entry.credits, unknown: "do-not-forward" }, resetCredits: [{ ...entry.resetCredits[0], unknown: "do-not-forward" }] }]));
    const restored = readArchive(path).codex;
    expect(restored).toEqual(q); expect(JSON.stringify(restored)).not.toContain("do-not-forward");
  }));
  it("loads the Swift daily format, preserves larger purged records and isolates accounts", () => withFile(path => {
    writeFileSync(path, JSON.stringify({ codex: [{ dayISO: "2026-10-06", tokens: tokens({ input: 100 }), estimatedCostUSD: .01, sessionCount: 1 }] }));
    const s = new HistoryStore(path); s.record("codex", daily(50)); s.record("codex#synthetic", daily(20));
    const reloaded = new HistoryStore(path); expect(reloaded.records("codex")[0].tokens.input).toBe(100); expect(reloaded.records("codex#synthetic")[0].tokens.input).toBe(20); expect(reloaded.error).toBeUndefined();
  }));
  it("latches corrupted history and preserves exact bytes while live readings update", () => withFile(path => {
    writeFileSync(path, "unreadable synthetic history"); const s = new HistoryStore(path);
    s.record("codex", daily(10)); s.record("codex", daily(20));
    expect(s.error).toBe("loadFailed"); expect(s.records("codex")[0].tokens.input).toBe(20); expect(readFileSync(path, "utf8")).toBe("unreadable synthetic history");
  }));
  it("recovers a save failure without resetting a corrupt-load latch", () => withFile(path => {
    const s = new HistoryStore(path); mkdirSync(path); s.record("codex", daily(1)); expect(s.error).toBe("writeFailed");
    rmSync(path, { recursive: true }); s.record("codex", daily(2)); expect(s.error).toBeUndefined(); expect(new HistoryStore(path).records("codex")[0].tokens.input).toBe(2);
  }));
  it("reads and writes the archive's Swift 2001 epoch, omitting primary slot id", () => withFile(path => {
    const epoch = Date.UTC(2001, 0, 1);
    writeFileSync(path, JSON.stringify([{ provider: "codex", capturedAt: (now - epoch) / 1000, windows: [{ label: "5-hour", usedPercent: 0, resetsAt: (now + day - epoch) / 1000 }] }]));
    expect(readArchive(path).codex.windows[0].resetsAt).toBe(now + day);
    saveArchive(path, [{ slot: primary("codex"), quota: quota("codex", [window("5-hour", 0, now + day)], now) }]);
    const stored = JSON.parse(readFileSync(path, "utf8"))[0]; expect(stored).not.toHaveProperty("slotID"); expect(stored.capturedAt).toBe((now - epoch) / 1000);
    expect(readArchive(path).codex.capturedAt).toBe(now);
  }));
  it("rejects malformed credit enum cases and required fields like the Swift decoder", () => withFile(path => {
    const q = quota("codex", [], now); q.credits = { balance: 0, unit: "credits", hasCredits: false, unlimited: false };
    saveArchive(path, [{ slot: primary("codex"), quota: q }]);
    const entry = JSON.parse(readFileSync(path, "utf8"))[0];
    for (const credits of [{ ...entry.credits, unit: { credits: {}, dollars: {} } }, { ...entry.credits, unit: {} }, { ...entry.credits, unit: { unknown: {} } }, { ...entry.credits, hasCredits: undefined }, { ...entry.credits, unlimited: "false" }]) {
      writeFileSync(path, JSON.stringify([{ ...entry, credits }])); expect(readArchive(path)).toEqual({});
    }
  }));
});
describe("ADR 0004 notch geometry", () => {
  it.each([false, true])("keeps top and strip anchor across different card heights (right=%s)", right => {
    const screen = { x: 0, y: 0, width: 1600, height: 1000 }, anchor = { x: 800, y: 40 };
    const a = notchFrame(anchor, { width: 294, height: 213.5 }, right, screen), b = notchFrame(anchor, { width: 294, height: 453.2 }, right, screen);
    expect(a.y).toBe(b.y); expect(a.x).toBe(b.x); expect(a.height).toBe(214); expect(b.height).toBe(454);
    expect(right ? a.x + 44 : a.x + a.width).toBe(anchor.x);
  });
});
