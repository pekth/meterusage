import { type Activity, type Usage, type Slot, type Quota, type Loaded, type Session, type Daily, totalTokens, activeUntil, localDay, shiftDay, utcDay, weekStart, slotKey, slotName, headlineWindow, lastBurn, severityNames } from "./models";
import { burnActive, pace, formatETA } from "./pacing";
import type { Snapshot } from "../shared/state";

export function trayTooltip(s: Snapshot): string {
  const entries = s.traySlots.flatMap(slot => {
    const key = slotKey(slot), q = s.quotas[key], fresh = q?.status === "value", reading = fresh ? q.value : s.archived[key], w = reading && headlineWindow(slot.provider, reading.windows);
    const parts: string[] = [];
    if (w) {
      parts.push(`${Math.round(w.usedPercent)}% used`);
      if (w.resetsAt !== undefined && w.resetsAt > s.clock) parts.push(`resets in ${formatETA((w.resetsAt - s.clock) / 1000, true)}`);
      if (!fresh) parts.push(`last reading ${formatETA((s.clock - reading!.capturedAt) / 1000, true)} ago`);
    }
    const status = s.statuses[slot.provider];
    if (status?.status === "value" && status.value.severity !== "operational") parts.push(severityNames[status.value.severity]);
    return parts.length ? [`${slotName(slot)}: ${parts.join(" · ")}`] : [];
  });
  if (!entries.length) entries.push("No usage data yet");
  if (s.lastRefreshedAt !== undefined) entries.push(`Updated ${formatETA((s.clock - s.lastRefreshedAt) / 1000, true)} ago`);
  return entries.join("\n");
}

// Swift StripTotals uses overlapping session instants for local today, and
// UTC day buckets for the seven-day history. Those boundaries differ.
export function stripTotals(activities: Activity[], usages: Usage[], now: number) {
  const today = localDay(now), tomorrow = shiftDay(today, 1), week = utcDay(now) - 6 * 86400000;
  let todayTokens = 0, weekTokens = 0, todayCost = 0;
  for (const a of activities) {
    const sessions = a.sessions.filter(s => s.startedAt < tomorrow && activeUntil(s) >= today);
    todayTokens += sessions.reduce((n, s) => n + totalTokens(s.tokens), 0); todayCost += sessions.reduce((n, s) => n + s.estimatedCostUSD, 0);
    weekTokens += a.daily.length ? a.daily.filter(d => d.day >= week).reduce((n, d) => n + totalTokens(d.tokens), 0) : a.sessions.filter(s => s.startedAt >= weekStart(now)).reduce((n, s) => n + totalTokens(s.tokens), 0);
  }
  for (const u of usages) { if (u.todayTokens) todayTokens += totalTokens(u.todayTokens); if (u.weekTokens) weekTokens += totalTokens(u.weekTokens); todayCost += u.todayCostUSD ?? 0; }
  const measured = activities.some(a => a.sessions.some(s => totalTokens(s.tokens) > 0) || a.daily.some(d => totalTokens(d.tokens) > 0)) || usages.some(u => u.todayTokens !== undefined || u.weekTokens !== undefined);
  return { todayTokens: measured ? todayTokens : undefined, weekTokens: measured ? weekTokens : undefined, todayCost: measured ? todayCost : undefined };
}
export function attributionSessions(slots: Slot[], activities: Record<string, Loaded<Activity>>, usages: Record<string, Loaded<Usage>>, now: number): Session[] {
  return slots.flatMap(slot => {
    const key = slotKey(slot), a = activities[key], u = usages[key];
    const sessions = a?.status === "value" ? a.value.sessions : [];
    if (u?.status !== "value") return sessions;
    const splits = u.value.projectBreakdown?.length ? u.value.projectBreakdown : u.value.weekTokens && totalTokens(u.value.weekTokens) > 0 ? [{ project: slotName(slot), tokens: u.value.weekTokens }] : [];
    return [...sessions, ...splits.map((split, i) => ({ id: `aggregate-${key}-${i}`, projectName: split.project, model: "", tokens: split.tokens, estimatedCostUSD: 0, startedAt: now, messageCount: 0, isAggregate: true }))];
  }).sort((a, b) => b.startedAt - a.startedAt);
}
export function failoverNudge(slots: Slot[], quotas: Record<string, Loaded<Quota>>, activities: Record<string, Loaded<Activity>>, now: number) {
  const rows = slots.flatMap(slot => {
    const key = slotKey(slot), q = quotas[key], a = activities[key], w = q?.status === "value" ? headlineWindow(slot.provider, q.value.windows) : undefined;
    if (!w) return [];
    return [{ slot, w, burning: pace(w, now)?.status === "deficit" && burnActive(a?.status === "value" ? lastBurn(a.value.sessions) : undefined, now) }];
  });
  const hot = rows.filter(r => r.burning || r.w.usedPercent >= 80), alternatives = rows.filter(r => !hot.includes(r) && r.w.usedPercent < 50);
  const first = hot.find(r => r.burning) ?? hot[0]; if (!first || !alternatives.length) return;
  const label = first.w.label.toLowerCase(), limit = label.includes("limit") ? label : `${label} limit`;
  return `${slotName(first.slot)} ${first.burning ? "burning fast" : `near its ${limit}`}. Switch to ${alternatives.map(r => slotName(r.slot)).join(", ")} for headroom.`;
}
export type HeatmapMode = "daily" | "weekly" | "cumulative";
export function heatmapCells(daily: Daily[], now: number, mode: HeatmapMode) {
  const today = localDay(now), weekday = new Date(today).getDay(), start = shiftDay(today, -(25 * 7 + weekday));
  const totals = new Map<number, { tokens: number; sessionCount: number }>();
  for (const d of daily) { const day = localDay(d.day), old = totals.get(day) ?? { tokens: 0, sessionCount: 0 }; totals.set(day, { tokens: old.tokens + totalTokens(d.tokens), sessionCount: old.sessionCount + d.sessionCount }); }
  let runningTokens = 0, runningSessions = 0;
  return Array.from({ length: 26 }, (_, week) => {
    const days = Array.from({ length: 7 }, (_, i) => shiftDay(start, week * 7 + i));
    const sum = days.filter(d => d <= today).reduce((sum, day) => { const t = totals.get(day); return { tokens: sum.tokens + (t?.tokens ?? 0), sessionCount: sum.sessionCount + (t?.sessionCount ?? 0) }; }, { tokens: 0, sessionCount: 0 });
    return days.map(day => {
      if (day > today) return null;
      const t = totals.get(day) ?? { tokens: 0, sessionCount: 0 }; runningTokens += t.tokens; runningSessions += t.sessionCount;
      return { day, ...(mode === "weekly" ? sum : mode === "cumulative" ? { tokens: runningTokens, sessionCount: runningSessions } : t) };
    });
  }).flat();
}
