import { type Usage, type Tokens, type Daily, tokens, addTokens, totalTokens, localDay, utcDay, weekStart, Unavailable, failed } from "../../domain/models";
import { telemetry } from "../../domain/telemetry";
import { selectJSON } from "../select-json";
import { object, number, date, text } from "./parsers";
import { projectName, filesIn } from "./activity";
import { readFile } from "node:fs/promises";
export const openCodeQuery = `SELECT tokens_input AS input, tokens_output AS output, tokens_reasoning AS reasoning,
 tokens_cache_read AS cache_read, tokens_cache_write AS cache_write, cost,
 (SELECT COUNT(*) FROM message WHERE message.session_id = session.id) AS messages,
 time_created AS created, time_updated AS updated, directory
 FROM session WHERE json_extract(model, '$.providerID') = 'opencode-go'`;
export interface UsageRecord { tokens: Tokens; cost: number; messages: number; created: number; updated: number; project: string }
const count = (v: unknown) => Math.trunc(number(v) ?? 0);
export function parseOpenCodeRows(s: string): UsageRecord[] {
  const rows = selectJSON(s, { '*': { input: true, output: true, reasoning: true, cache_read: true, cache_write: true, cost: true, messages: true, created: true, updated: true, directory: true } });
  if (!Array.isArray(rows)) throw failed("openCodeGo");
  return rows.flatMap(raw => { const r = object(raw), created = date(r.created), updated = date(r.updated); return created === undefined || updated === undefined ? [] : [{ tokens: tokens({ input: count(r.input), output: count(r.output), reasoning: count(r.reasoning), cacheRead: count(r.cache_read), cacheWrite: count(r.cache_write) }), cost: number(r.cost) ?? 0, messages: count(r.messages), created, updated, project: text(r.directory) ? projectName(text(r.directory)!) : "" }]; });
}
export function openCodeUsage(records: UsageRecord[], now: number): Usage {
  if (!records.length) throw new Unavailable("dataNotFound", "OpenCode Go usage");
  const sum = (rs: UsageRecord[]) => rs.reduce((t, r) => addTokens(t, r.tokens), tokens());
  const cost = (rs: UsageRecord[]) => rs.reduce((n, r) => n + r.cost, 0);
  const messages = (rs: UsageRecord[]) => rs.reduce((n, r) => n + r.messages, 0);
  const todayCreated = records.filter(r => r.created >= localDay(now)), todayTouched = records.filter(r => r.updated >= localDay(now)), weekTouched = records.filter(r => r.updated >= weekStart(now));
  const todayTokens = sum(todayTouched), weekTokens = sum(weekTouched), projects = new Map<string, Tokens>();
  for (const r of weekTouched) projects.set(r.project, addTokens(projects.get(r.project) ?? tokens(), r.tokens));
  const projectBreakdown = [...projects].filter(([, t]) => totalTokens(t) > 0).map(([project, tokens]) => ({ project, tokens })).sort((a, b) => totalTokens(b.tokens) - totalTokens(a.tokens));
  return { provider: "openCodeGo", sessionCount: records.length, messageCount: messages(records), tokens: sum(records), estimatedCostUSD: cost(records), todaySessionCount: todayCreated.length, todayMessageCount: messages(todayCreated), ...(totalTokens(todayTokens) > 0 ? { todayTokens } : {}), ...(totalTokens(weekTokens) > 0 ? { weekTokens } : {}), ...(projectBreakdown.length ? { projectBreakdown } : {}), ...(cost(todayTouched) > 0 ? { todayCostUSD: cost(todayTouched) } : {}), usageWindows: ([ ["last 24h", 1], ["last 7d", 7], ["last 30d", 30] ] as const).map(([label, days]) => { const rs = records.filter(r => r.updated >= now - days * 86400000); return { label, sessionCount: rs.length, messageCount: messages(rs), tokens: sum(rs), estimatedCostUSD: cost(rs) }; }), telemetry: telemetry(records.map(r => ({ startedAt: r.created, endedAt: r.updated, tokens: totalTokens(r.tokens), messageCount: r.messages })), [], now), capturedAt: Math.max(...records.map(r => r.updated)) };
}
const grokSelection = { created_at: true, createdAt: true, last_active_at: true, updated_at: true, updatedAt: true, num_chat_messages: true, num_messages: true, message_count: true, messageCount: true } as const;
export function grokUsage(summaries: string[], now: number): Usage {
  const records = summaries.flatMap(s => {
    try { const r = object(selectJSON(s, grokSelection)), created = date(r.created_at) ?? date(r.createdAt), endedAt = date(r.last_active_at) ?? date(r.updated_at) ?? date(r.updatedAt), messages = number(r.num_chat_messages) ?? number(r.num_messages) ?? number(r.message_count) ?? number(r.messageCount); return created === undefined || messages === undefined || messages <= 0 ? [] : [{ startedAt: created, endedAt, tokens: 0, messageCount: Math.trunc(messages) }]; } catch { return []; }
  });
  if (!records.length) throw new Unavailable("noData");
  const today = records.filter(r => r.startedAt >= localDay(now));
  return { provider: "grok", sessionCount: records.length, messageCount: records.reduce((n, r) => n + r.messageCount, 0), todaySessionCount: today.length, todayMessageCount: today.reduce((n, r) => n + r.messageCount, 0), telemetry: telemetry(records, [], now), capturedAt: Math.max(...records.map(r => r.startedAt)) };
}
export async function scanGrok(root: string, now: number, signal?: AbortSignal): Promise<Usage> {
  const paths = (await filesIn(root, "summary.json", true, signal)).filter(p => p.endsWith("/summary.json"));
  if (!paths.length) throw new Unavailable("dataNotFound", "Grok session history");
  const summaries = await Promise.all(paths.map(p => readFile(p, { encoding: "utf8", signal }).catch(e => { signal?.throwIfAborted(); return ""; }))); return grokUsage(summaries, now);
}
export function antigravityHistory(s: string, now: number): Usage {
  const byID = new Map<string, { start?: number; messages: number }>();
  for (const line of s.split("\n")) {
    try { const r = object(selectJSON(line, { conversationId: true, timestamp: true })), id = text(r.conversationId); if (!id || r.timestamp === undefined) continue; const record = byID.get(id) ?? { messages: 0 }; record.messages++; const at = date(r.timestamp); if (at !== undefined) record.start = Math.min(record.start ?? Infinity, at); byID.set(id, record); } catch { /* Bad history rows are skipped. */ }
  }
  const records = [...byID.values()].filter(r => r.start !== undefined); if (!records.length) throw new Unavailable("noData");
  const today = records.filter(r => r.start! >= localDay(now));
  return { provider: "antigravity", sessionCount: records.length, messageCount: records.reduce((n, r) => n + r.messages, 0), todaySessionCount: today.length, todayMessageCount: today.reduce((n, r) => n + r.messages, 0), capturedAt: now };
}
export function openRouterUsage(s: string, now: number): Usage {
  const root = object(selectJSON(s, { data: { '*': { date: true, prompt_tokens: true, completion_tokens: true, reasoning_tokens: true, requests: true, usage: true } } }));
  if (!Array.isArray(root.data)) throw failed("openRouter");
  const map = new Map<number, Daily>();
  for (const raw of root.data) {
    const r = object(raw), day = typeof r.date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(r.date) ? Date.parse(r.date + "T00:00:00Z") : NaN;
    if (!Number.isFinite(day)) continue;
    const prior = map.get(day) ?? { day, tokens: tokens(), sessionCount: 0, estimatedCostUSD: 0 };
    const t = tokens({ input: Math.max(0, count(r.prompt_tokens)), output: Math.max(0, count(r.completion_tokens)), reasoning: Math.max(0, count(r.reasoning_tokens)) });
    map.set(day, { day, tokens: addTokens(prior.tokens, t), sessionCount: prior.sessionCount + Math.max(0, count(r.requests)), estimatedCostUSD: prior.estimatedCostUSD + Math.max(0, number(r.usage) ?? 0) });
  }
  const daily = [...map.values()].sort((a, b) => a.day - b.day), total = daily.reduce((a, d) => ({ tokens: addTokens(a.tokens, d.tokens), requests: a.requests + d.sessionCount, cost: a.cost + d.estimatedCostUSD }), { tokens: tokens(), requests: 0, cost: 0 });
  const today = map.get(utcDay(now)) ?? { tokens: tokens(), sessionCount: 0, estimatedCostUSD: 0 }, week = daily.filter(d => d.day >= utcDay(now) - 6 * 86400000).reduce((t, d) => addTokens(t, d.tokens), tokens());
  const calculated = telemetry([], daily, now, true);
  const measured = { ...calculated, lifetimeTokens: calculated.lifetimeTokens ?? 0, peakDailyTokens: calculated.peakDailyTokens ?? 0, todayTokens: calculated.todayTokens ?? 0, last30DaysTokens: calculated.last30DaysTokens ?? 0 };
  return { provider: "openRouter", sessionCount: total.requests, messageCount: total.requests, tokens: total.tokens, estimatedCostUSD: total.cost > 0 ? total.cost : undefined, todaySessionCount: today.sessionCount, todayMessageCount: today.sessionCount, todayTokens: totalTokens(today.tokens) > 0 ? today.tokens : undefined, weekTokens: totalTokens(week) > 0 ? week : undefined, todayCostUSD: today.estimatedCostUSD > 0 ? today.estimatedCostUSD : undefined, usageWindows: [{ label: "last 24h", sessionCount: today.sessionCount, messageCount: today.sessionCount, tokens: today.tokens, estimatedCostUSD: today.estimatedCostUSD }, { label: "last 30d", sessionCount: total.requests, messageCount: total.requests, tokens: total.tokens, estimatedCostUSD: total.cost }], telemetry: measured, capturedAt: now };
}
