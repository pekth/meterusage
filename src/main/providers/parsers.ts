import { type Quota, type Provider, type QuotaWindow, type Credits, type Severity, quota, window, Unavailable, failed, type ServiceStatus } from "../../domain/models";
import { selectJSON } from "../select-json";

export const object = (v: unknown): Record<string, unknown> => v !== null && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : Object.create(null);
export const number = (v: unknown): number | undefined => typeof v === "number" && Number.isFinite(v) ? v : typeof v === "string" && v.trim() && Number.isFinite(Number(v)) ? Number(v) : undefined;
export const text = (v: unknown): string | undefined => typeof v === "string" && v.trim() ? v.trim() : undefined;
export function displayText(v: unknown): string | undefined {
  const s = text(v);
  return s && s.length <= 100 && !/[@\\\r\n]|(?:sk-|ghp_|gho_|Bearer\s)|eyJ[A-Za-z0-9_-]{12}/.test(s) && !s.startsWith("/") ? s : undefined;
}
export function date(v: unknown): number | undefined {
  const n = number(v);
  const d = n === undefined ? typeof v === "string" ? Date.parse(v) : NaN : n > 100000000000 ? n : n * 1000;
  return Number.isFinite(d) ? d : undefined;
}
export const json = (s: string): Record<string, unknown> => object(JSON.parse(s));
const array = (v: unknown): unknown[] => Array.isArray(v) ? v : [];

export function parseCodex(s: string, now = Date.now()): Quota {
  const root = json(s), error = object(root.error);
  if (root.error) {
    const message = (text(error.message) ?? "").toLowerCase();
    if (/not logged in|not authenticated|sign in/.test(message)) throw new Unavailable("notSignedIn", "Codex");
    if (error.code === -32603 && /reach|backend|network|connect/.test(message)) throw new Unavailable("offline");
    throw failed("codex");
  }
  const result = object(root.result), limits = object(result.rateLimits);
  if (!result.rateLimits) throw failed("codex");
  function windows(payload: Record<string, unknown>) {
    return [payload.primary, payload.secondary].flatMap(v => {
      if (v === null || v === undefined) return [];
      const w = object(v), used = number(w.usedPercent), duration = number(w.windowDurationMins);
      if (used === undefined || duration === undefined) throw failed("codex");
      return [window(duration >= 1440 ? "Weekly" : "5-hour", used, date(w.resetsAt), duration)];
    });
  }
  const q = quota("codex", windows(limits), now), baseID = displayText(limits.limitId) ?? "codex";
  q.planType = displayText(limits.planType);
  if (q.windows.length) q.groups.push({ id: baseID, title: "General usage limits", windows: q.windows });
  for (const [key, payload] of Object.entries(object(result.rateLimitsByLimitId)).sort(([a], [b]) => a.localeCompare(b))) {
    const extra = object(payload), id = displayText(extra.limitId) ?? displayText(key);
    if (!id || id === baseID || key === baseID) continue;
    const ws = windows(extra); if (ws.length) q.groups.push({ id, title: displayText(extra.limitName) ?? id, windows: ws });
  }
  const c = object(limits.credits), balance = number(c.balance);
  if (balance !== undefined && typeof c.hasCredits === "boolean" && typeof c.unlimited === "boolean") q.credits = { balance, hasCredits: c.hasCredits, unlimited: c.unlimited, unit: "credits", dollarBalance: balance / 25 };
  const reset = object(result.rateLimitResetCredits), count = number(reset.availableCount);
  if (count !== undefined) {
    q.resetCreditCount = count;
    q.resetCredits = array(reset.credits).flatMap(v => {
      const c = object(v), id = text(c.id); return id ? [{ id, title: displayText(c.title) ?? "Full reset", status: displayText(c.status), expiresAt: date(c.expiresAt) }] : [];
    });
  }
  return q;
}
export function parseClaudeQuota(s: string, now = Date.now()): Quota {
  const r = json(s), ws: QuotaWindow[] = [];
  const rank: Record<string, number> = { session: 0, weekly_all: 1, weekly_scoped: 2 };
  for (const raw of array(r.limits).map(object).sort((a, b) => (rank[text(a.kind) ?? ""] ?? 3) - (rank[text(b.kind) ?? ""] ?? 3))) {
    const used = number(raw.percent); if (used === undefined) continue;
    const kind = text(raw.kind), name = displayText(object(object(raw.scope).model).display_name), group = displayText(raw.group);
    const label = kind === "session" ? "5-hour" : kind === "weekly_all" ? "Weekly · All models" : kind === "weekly_scoped" ? `Weekly${name ? ` · ${name}` : ""}` : name ? `${group ? group[0].toUpperCase() + group.slice(1) + " · " : ""}${name}` : undefined;
    if (label) ws.push(window(label, used, date(raw.resets_at)));
  }
  if (!ws.length) {
    const add = (v: unknown, label: string) => { const o = object(v), used = number(o.used_percentage); if (used !== undefined) ws.push(window(label, used, date(o.resets_at))); };
    add(r.five_hour, "5-hour");
    if (array(r.weekly).length) for (const e of array(r.weekly)) add(e, displayText(object(e).label) ?? "Weekly");
    else add(r.seven_day, "7-day");
    for (const key of Object.keys(r).filter(k => k.startsWith("seven_day_")).sort()) { const name = displayText(key.slice(10)); if (name) add(r[key], `7-day (${name[0].toUpperCase() + name.slice(1)})`); }
  }
  const q = quota("claude", ws, date(r.updated_at) ?? now), e = object(r.extra_usage), used = number(e.used_credits), limit = number(e.monthly_limit);
  if (e.is_enabled === true && used !== undefined && limit !== undefined) q.credits = { balance: limit <= 0 ? 0 : (limit - used) / 100, hasCredits: true, unlimited: limit <= 0, unit: "dollars", usedDollars: used / 100, ...(limit > 0 ? { limitDollars: limit / 100 } : {}) };
  return q;
}
export const claudeTierSelection = { oauthAccount: { organizationRateLimitTier: true, seatTier: true, userRateLimitTier: true } } as const;
export function parseClaudePlan(s: string): string {
  const r = object(selectJSON(s, claudeTierSelection)), a = object(r.oauthAccount);
  const tier = text(a.organizationRateLimitTier) ?? text(a.seatTier) ?? text(a.userRateLimitTier);
  if (!tier) throw new Unavailable("noData");
  const v = tier.toLowerCase();
  return /max_?20x/.test(v) ? "Max 20×" : /max_?5x/.test(v) ? "Max 5×" : v.includes("enterprise") ? "Enterprise" : v.includes("team") ? "Team" : v.includes("pro") ? "Pro" : v.includes("free") ? "Free" : displayText(tier) ?? "Unknown";
}
export function parseOpenRouter(s: string, creditsData?: string, now = Date.now()): Quota {
  const r = object(json(s).data), usedRaw = number(r.usage), used = usedRaw === undefined ? undefined : Math.max(0, usedRaw), limit = number(r.limit);
  const remainder = number(r.limit_remaining), remaining = remainder === undefined ? limit === undefined ? undefined : Math.max(0, limit - (used ?? 0)) : Math.max(0, remainder);
  if (used === undefined && limit === undefined && remaining === undefined) throw new Unavailable("noData");
  const reset = text(r.limit_reset)?.toLowerCase(), labels: Record<string, string> = { daily: "Daily", weekly: "Weekly", monthly: "Monthly" };
  const q = quota("openRouter", used !== undefined && limit !== undefined && limit > 0 ? [window(labels[reset ?? ""] ?? "Spending limit", used / limit * 100)] : [], now);
  q.credits = { balance: remaining ?? 0, hasCredits: remaining === undefined ? (used ?? 0) > 0 : remaining > 0, unlimited: limit === undefined, unit: "dollars", usedDollars: used, limitDollars: limit };
  if (creditsData) {
    try { const c = object(json(creditsData).data), total = number(c.total_credits), spend = number(c.total_usage); if (total !== undefined) { const balance = Math.max(0, Math.max(0, total) - Math.max(0, spend ?? 0)); q.credits = { balance, hasCredits: balance > 0, unlimited: false, unit: "dollars", usedDollars: spend === undefined ? undefined : Math.max(0, spend), limitDollars: Math.max(0, total) }; } } catch { /* Optional balance never hides valid key usage. */ }
  }
  return q;
}
export function parseOpenCode(s: string, now = Date.now()): Quota {
  const r = json(s), e = text(object(r.error).type)?.toLowerCase();
  if (e) throw e === "autherror" || e === "invalid_api_key" ? new Unavailable("notSignedIn", "OpenCode Go") : failed("openCodeGo");
  const u = object(r.usage), ws = ([ ["rolling", "Rolling", 1440], ["weekly", "Weekly", 10080], ["monthly", "Monthly", 43200] ] as const).map(([key, label, mins]) => {
    const w = object(u[key]), percent = number(w.percent);
    if (percent === undefined || !text(w.status)) throw failed("openCodeGo");
    const reset = date(w.resetsAt); if (w.resetsAt != null && reset === undefined) throw failed("openCodeGo");
    return window(label, percent, reset, mins);
  });
  return { ...quota("openCodeGo", ws, now), planType: "go" };
}
export function parseGrok(s: string, now = Date.now()): Quota {
  const r = json(s);
  if (r.error) { const e = (text(r.error) ?? text(object(r.error).type) ?? "").toLowerCase(); throw /invalid|expired|unauth|not signed|autherror/.test(e) ? new Unavailable("notSignedIn", "Grok") : failed("grok"); }
  const c = object(r.config), period = object(c.currentPeriod), reset = date(c.billingPeriodEnd) ?? date(period.end), used = number(c.creditUsagePercent);
  if (reset === undefined || used === undefined) throw new Unavailable("noData");
  const kind = text(period.type)?.toUpperCase(), label = kind === "USAGE_PERIOD_TYPE_WEEKLY" ? "Weekly" : kind === "USAGE_PERIOD_TYPE_MONTHLY" ? "Monthly" : "Usage";
  return { ...quota("grok", [window(label, used, reset)], now), planType: displayText(r.subscriptionTier ?? r.subscription_tier) };
}
export function parseLocalQuota(p: "cursor" | "copilot" | "gemini", s: string, now = Date.now()): Quota {
  const r = json(s), key = p === "cursor" ? "fast_requests" : p === "copilot" ? "premium_requests" : "requests", nested = object(r[key]);
  const n = number(nested.used_percent), root = number(r.used_percent), used = n ?? root;
  const label = n === undefined ? p === "gemini" ? "Daily" : "Monthly" : p === "cursor" ? "Fast requests" : p === "copilot" ? "Premium requests" : "Daily";
  const q = quota(p, used === undefined ? [] : [window(label, used, n === undefined ? undefined : date(nested.resets_at), p === "gemini" ? 1440 : 43200)], now);
  q.planType = displayText(r.plan) ?? (p === "cursor" ? "Pro" : p === "copilot" ? "Individual" : "Developer"); return q;
}
export function parseAntigravity(s: string, now = Date.now()): Quota {
  const rows = s.split(/\r?\n/).flatMap(line => { const parts = line.split("\t"); if (parts.length !== 4 || !parts[2].trim().endsWith("%")) return []; const remaining = number(parts[2].trim().slice(0, -1)), group = displayText(parts[0]), label = displayText(parts[1].replace(" Limit Remaining", "")); return remaining === undefined || !group || !label ? [] : [{ remaining, group, label, reset: date(parts[3]) }]; });
  if (!rows.length) throw new Unavailable("noData");
  const short = (s: string) => s === "Five Hour" ? "5-hour" : s;
  const duration = (s: string) => /week/i.test(s) ? 10080 : /five|5|hour/i.test(s) ? 300 : undefined;
  const q = quota("antigravity", rows.map(r => window(`${/claude|gpt/i.test(r.group) ? "Claude/GPT" : /gemini/i.test(r.group) ? "Gemini" : r.group} ${short(r.label)}`, 100 - r.remaining, r.reset, duration(r.label))), now);
  for (const group of new Set(rows.map(r => r.group))) q.groups.push({ id: group.toLowerCase(), title: group, windows: rows.filter(r => r.group === group).map(r => window(short(r.label) + (/limit/i.test(short(r.label)) ? "" : " limit"), 100 - r.remaining, r.reset, duration(r.label))) });
  return q;
}
export function parseStatus(p: Provider, s: string, now = Date.now()): ServiceStatus {
  const fragments = p === "codex" ? ["codex", "cli", "login"] : p === "claude" ? ["api", "claude", "code", "console"] : ["api"];
  const components = array(json(s).components).map(object).filter(c => c.group !== true), relevant = components.filter(c => fragments.some(f => (text(c.name) ?? "").toLowerCase().includes(f)));
  const pool = relevant.length ? relevant : components;
  const map: Record<string, Severity> = { operational: "operational", degraded_performance: "degraded", under_maintenance: "degraded", partial_outage: "partialOutage", major_outage: "majorOutage", full_outage: "majorOutage" };
  const rank: Severity[] = ["operational", "unknown", "degraded", "partialOutage", "majorOutage"];
  let severity: Severity = pool.length ? "operational" : "unknown", culprit: string | undefined;
  for (const c of pool) { const v = map[(text(c.status) ?? "").toLowerCase()] ?? "unknown"; if (rank.indexOf(v) > rank.indexOf(severity)) { severity = v; culprit = displayText(c.name); } }
  return { provider: p, severity, description: severity === "operational" ? "All systems operational" : culprit ? `${culprit}: ${severity === "partialOutage" ? "partial outage" : severity === "majorOutage" ? "major outage" : severity}` : "Status unavailable", checkedAt: now };
}
