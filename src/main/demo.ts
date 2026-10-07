import { type Source } from "./composition";
import { type Provider, type Slot, type ManagedAccount, type Quota, type Activity, primary, accountSlot, window, quota, tokens, totalTokens, localDay, shiftDay, Unavailable } from "../domain/models";
import { telemetry } from "../domain/telemetry";
import { estimate } from "../domain/pricing";
const second = (provider: Provider): Slot => ({ provider, slotID: "demo-second", label: "Second account" });
function demoQuota(p: Provider, now: number): Quota {
  const w = (label: string, used: number, seconds?: number, mins?: number) => window(label, used, seconds === undefined ? undefined : now + seconds * 1000, mins);
  if (p === "claude") return quota(p, [w("5-hour", 34, 3.25 * 3600), w("7-day", 61, 2.25 * 86400)], now);
  if (p === "codex") {
    const q = quota(p, [w("5-hour", 82, 1.75 * 3600), w("Weekly", 72, 4.5 * 86400)], now);
    q.planType = "plus"; q.credits = { balance: 41.6, hasCredits: true, unlimited: false, unit: "credits", dollarBalance: 41.6 * 0.04 };
    q.groups = [{ id: "codex", title: "General usage limits", windows: q.windows }, { id: "codex_bengalfox", title: "GPT-5.3-Codex-Spark usage limits", windows: [w("Weekly", 0, 4.5 * 86400)] }];
    q.resetCreditCount = 2; q.resetCredits = [1, 2].map(i => ({ id: `demo-reset-${i}`, title: "Full reset", status: "available", expiresAt: now + (7 + i) * 86400000 })); return q;
  }
  if (p === "openRouter") return { ...quota(p, [w("Monthly", 25.5)], now), credits: { balance: 74.5, hasCredits: true, unlimited: false, unit: "dollars", usedDollars: 25.5, limitDollars: 100 } };
  if (p === "openCodeGo") return { ...quota(p, [w("Rolling", 87, 1.9 * 3600), w("Weekly", 77, 26 * 3600), w("Monthly", 44, 22.4 * 86400)], now), planType: "go" };
  if (p === "grok") return { ...quota(p, [w("Weekly", 31, 2.2 * 86400)], now), planType: "X Premium" };
  if (p === "antigravity") {
    const q = quota(p, [w("Gemini Weekly", 89, 22 * 3600 + 24 * 60, 10080), w("Gemini 5-hour", 9, 4 * 3600 + 26 * 60, 300), w("Claude/GPT Weekly", 1, 22 * 3600 + 19 * 60, 10080), w("Claude/GPT 5-hour", 0, 4 * 3600 + 59 * 60, 300)], now);
    q.groups = ["Gemini Models", "Claude and GPT models"].map((title, i) => ({ title, id: title.toLowerCase(), windows: q.windows.slice(i * 2, i * 2 + 2).map((w, index) => ({ ...w, label: index ? "5-hour limit" : "Weekly limit" })) })); return q;
  }
  throw new Unavailable("noData");
}
function demoActivity(p: "codex" | "claude", now: number): Activity {
  const daily = Array.from({ length: 30 }, (_, i) => ({ day: shiftDay(localDay(now), i - 29), tokens: tokens({ input: 5000 + i * 1000, output: 2000 + i * 100, cacheRead: 50000 + i * 10000 }), estimatedCostUSD: 0.12 + i * 0.04, sessionCount: i % 4 + 1 }));
  const sessions = p === "codex" ? [] : ["web-app", "api-server", "notes-cli"].map((projectName, i) => { const t = tokens({ input: 18000 + i * 4000, output: 9000, cacheRead: 350000, cacheWrite: 48000 }); return { id: `demo-${i}`, projectName, model: "claude-sonnet-4-6", tokens: t, estimatedCostUSD: estimate("claude-sonnet-4-6", t).costUSD, startedAt: now - (i + 1) * 900000, lastActivityAt: now - i * 300000, messageCount: 12 + i }; });
  return { provider: p, sessions, daily, scannedAt: now, telemetry: telemetry(sessions.map(s => ({ startedAt: s.startedAt, tokens: totalTokens(s.tokens), messageCount: s.messageCount })), daily, now) };
}
export function demoSources(now: () => number, accounts: ManagedAccount[] = []): Source[] {
  const slots = [primary("claude"), second("claude"), primary("codex"), second("codex"), ...(["openRouter", "openCodeGo", "grok", "antigravity"] as const).map(primary), ...accounts.filter(a => a.enabled).map(accountSlot)];
  return slots.map(slot => {
    const consumed = new Set<string>();
    const source: Source = { slot, quota: async () => { const q = demoQuota(slot.provider, now()); if (slot.provider === "codex") { q.resetCredits = q.resetCredits.filter(c => !consumed.has(c.id)); q.resetCreditCount = q.resetCredits.length; if (consumed.size) { q.windows = q.windows.map(w => ({ ...w, usedPercent: 0 })); q.groups[0].windows = q.windows; } } return q; } };
    if (slot.provider === "claude" || slot.provider === "codex") { const p = slot.provider; source.activity = async () => demoActivity(p, now()); }
    if (slot.provider === "claude") source.plan = async () => slot.slotID ? "Max 20×" : "Max 5×";
    if (!slot.slotID && (slot.provider === "claude" || slot.provider === "codex")) source.status = async () => ({ provider: slot.provider, severity: "operational", description: "All systems operational", checkedAt: now() - 90000 });
    if (slot.provider === "codex") source.consumeReset = async id => { if (!["demo-reset-1", "demo-reset-2"].includes(id) || consumed.has(id)) return false; consumed.add(id); return true; };
    if (["openRouter", "openCodeGo", "grok", "antigravity"].includes(slot.provider)) source.usage = async () => ({ provider: slot.provider, sessionCount: slot.provider === "grok" ? 124 : 26, messageCount: slot.provider === "grok" ? 1840 : 492, todaySessionCount: 3, todayMessageCount: 71, ...(slot.provider === "grok" ? {} : { tokens: tokens({ input: 1420000, output: 386000, reasoning: 118000, cacheRead: 9840000 }), todayTokens: tokens({ input: 260000, output: 74000, reasoning: 18000, cacheRead: 1420000 }), weekTokens: tokens({ input: 980000, output: 240000, reasoning: 74000, cacheRead: 6100000 }), ...(slot.provider === "openCodeGo" || slot.provider === "openRouter" ? { estimatedCostUSD: 16.33, todayCostUSD: 2.1 } : {}) }), telemetry: demoActivity("claude", now()).telemetry, capturedAt: now() - 55000 });
    return source;
  });
}
