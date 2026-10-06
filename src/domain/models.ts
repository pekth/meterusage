export const providers = ["codex", "antigravity", "grok", "openCodeGo", "openRouter", "claude", "cursor", "copilot", "gemini"] as const;
export type Provider = typeof providers[number];
export const providerNames: Record<Provider, string> = {
  codex: "Codex", antigravity: "Antigravity", grok: "Grok", openCodeGo: "OpenCode Go",
  openRouter: "OpenRouter", claude: "Claude", cursor: "Cursor", copilot: "Copilot CLI", gemini: "Gemini CLI",
};
export interface Slot { provider: Provider; slotID: string; label: string }
export interface ManagedAccount { id: string; provider: "codex" | "claude"; label: string; path: string; enabled: boolean }
export const primary = (provider: Provider): Slot => ({ provider, slotID: "", label: "" });
export const slotKey = (s: Slot) => s.slotID ? `${s.provider}#${s.slotID}` : s.provider;
export const slotName = (s: Slot) => providerNames[s.provider] + (s.slotID ? ` · ${s.label || "Account"}` : "");
export const accountSlot = (a: ManagedAccount): Slot => ({ provider: a.provider, slotID: a.id, label: a.label });
export interface QuotaWindow { label: string; usedPercent: number; resetsAt?: number; windowDurationMins?: number; pacingBaseline?: { usedPercent: number; capturedAt?: number; observedAt?: number } }
export interface QuotaGroup { id: string; title: string; windows: QuotaWindow[] }
export interface ResetCredit { id: string; title: string; status?: string; expiresAt?: number }
export const resetCreditAvailable = (credit: ResetCredit, now: number) => credit.status?.toLowerCase() === "available" && (credit.expiresAt === undefined || credit.expiresAt > now);
export interface Credits {
  balance: number; hasCredits: boolean; unlimited: boolean; unit: "credits" | "dollars";
  usedDollars?: number; limitDollars?: number; dollarBalance?: number;
}
export interface Quota {
  provider: Provider; windows: QuotaWindow[]; groups: QuotaGroup[]; credits?: Credits;
  resetCreditCount?: number; resetCredits: ResetCredit[]; planType?: string; resetPacingSince?: number; capturedAt: number;
}
export const clamp = (n: number, lo = 0, hi = 100) => Math.min(hi, Math.max(lo, n));
export function window(label: string, usedPercent: number, resetsAt?: number, windowDurationMins?: number): QuotaWindow {
  if (!Number.isFinite(usedPercent)) throw new Error("Invalid percentage");
  return { label, usedPercent: clamp(usedPercent), ...(resetsAt === undefined ? {} : { resetsAt }), ...(windowDurationMins === undefined ? {} : { windowDurationMins }) };
}
export const quota = (provider: Provider, windows: QuotaWindow[], capturedAt = Date.now()): Quota => ({ provider, windows, groups: [], resetCredits: [], capturedAt });
export const isSessionWindow = (w: QuotaWindow) => w.label.toLowerCase() === "5-hour" || w.label.toLowerCase().includes("session");
export function headlineWindow(provider: Provider, windows: QuotaWindow[]): QuotaWindow | undefined {
  if (provider === "codex") return windows.find(isSessionWindow) ?? (windows.length === 1 ? windows[0] : undefined);
  if (provider === "claude") return windows.find(isSessionWindow) ?? windows.find(w => w.label === "7-day");
  if (provider === "openCodeGo") return windows.find(w => w.label.toLowerCase() === "rolling");
  if (["cursor", "copilot", "gemini"].includes(provider)) { const session = windows.find(isSessionWindow); if (session) return session; }
  return windows.reduce<QuotaWindow | undefined>((max, w) => !max || w.usedPercent > max.usedPercent ? w : max, undefined);
}
export interface Tokens { input: number; output: number; reasoning: number; cacheRead: number; cacheWrite: number }
export const tokens = (t: Partial<Tokens> = {}): Tokens => ({ input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, ...t });
export const totalTokens = (t: Tokens) => t.input + t.output + t.reasoning + t.cacheRead + t.cacheWrite;
export const addTokens = (a: Tokens, b: Tokens): Tokens => ({ input: a.input + b.input, output: a.output + b.output, reasoning: a.reasoning + b.reasoning, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite });
export interface Session {
  id: string; projectName: string; model: string; tokens: Tokens; estimatedCostUSD: number;
  startedAt: number; lastActivityAt?: number; messageCount: number; isAggregate?: boolean; isAutomation?: boolean;
}
export const activeUntil = (s: Session) => Math.max(s.lastActivityAt ?? s.startedAt, s.startedAt);
export const lastBurn = (sessions: Session[]) => sessions.length ? Math.max(...sessions.map(activeUntil)) : undefined;
export interface Daily { day: number; tokens: Tokens; estimatedCostUSD: number; sessionCount: number }
export interface Activity { provider: Provider; sessions: Session[]; daily: Daily[]; scannedAt: number; telemetry?: Telemetry }
export interface UsageWindow { label: string; sessionCount: number; messageCount: number; tokens: Tokens; estimatedCostUSD: number }
export interface Usage {
  provider: Provider; sessionCount: number; messageCount: number; tokens?: Tokens; estimatedCostUSD?: number;
  todaySessionCount: number; todayMessageCount: number; todayTokens?: Tokens; weekTokens?: Tokens;
  projectBreakdown?: { project: string; tokens: Tokens }[]; todayCostUSD?: number; usageWindows?: UsageWindow[];
  telemetry?: Telemetry; capturedAt: number;
}
export interface Telemetry {
  lifetimeTokens?: number; peakDailyTokens?: number; longestChatSeconds?: number;
  currentStreakDays: number; longestStreakDays: number; todayTokens?: number; last30DaysTokens?: number;
  totalSessions?: number; totalMessages?: number; todaySessions?: number; todayMessages?: number;
  dailyHistory: { day: number; tokens: number; sessionCount: number }[];
}
export type Severity = "operational" | "unknown" | "degraded" | "partialOutage" | "majorOutage";
export const severityNames: Record<Severity, string> = { operational: "Operational", unknown: "Unknown", degraded: "Degraded", partialOutage: "Partial outage", majorOutage: "Major outage" };
export interface ServiceStatus { provider: Provider; severity: Severity; description: string; checkedAt: number }
export type MissingCode = "cliNotFound" | "notSignedIn" | "offline" | "failed" | "noData" | "dataNotFound";
export class Unavailable extends Error {
  constructor(public code: MissingCode, public subject?: string) {
    super(code === "cliNotFound" ? `${subject} CLI not found` : code === "notSignedIn" ? `Not signed in to ${subject}` : code === "offline" ? "Offline" : code === "failed" ? `Couldn't read ${subject} usage` : code === "dataNotFound" ? `${subject} not found` : "No usage yet");
  }
}
export const failed = (p: Provider) => new Unavailable("failed", providerNames[p]);
export type Loaded<T> = { status: "idle" } | { status: "value"; value: T } | { status: "missing"; code: MissingCode; reason: string };
export const value = <T>(v: T): Loaded<T> => ({ status: "value", value: v });
export const missing = <T>(e: unknown, p: Provider): Loaded<T> => {
  const u = e instanceof Unavailable ? e : failed(p);
  return { status: "missing", code: u.code, reason: u.message };
};
export const utcDay = (at: number) => Math.floor(at / 86400000) * 86400000;
export function localDay(at: number) { const d = new Date(at); d.setHours(0, 0, 0, 0); return d.getTime(); }
export function shiftDay(at: number, n: number) { const d = new Date(at); d.setDate(d.getDate() + n); return d.getTime(); }
export const weekStart = (now: number) => shiftDay(localDay(now), -6);
