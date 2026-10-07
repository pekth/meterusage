import { type Session, type Daily, type Telemetry, type Tokens, type QuotaWindow, totalTokens, tokens, addTokens, localDay, shiftDay, utcDay } from "./models";
import { durationMins } from "./pacing";

export function telemetry(sessions: { startedAt: number; endedAt?: number; tokens: number; messageCount: number }[], daily: Daily[], now: number, utc = false): Telemetry {
  const startOfDay = utc ? utcDay : localDay;
  const nextDay = utc ? (at: number, n: number) => at + n * 86400000 : shiftDay;
  const today = startOfDay(now), stats = new Map<number, { tokens: number; sessions: number }>();
  for (const d of daily.length ? daily.map(d => ({ day: d.day, tokens: totalTokens(d.tokens), sessions: d.sessionCount })) : sessions.map(s => ({ day: s.startedAt, tokens: s.tokens, sessions: 1 }))) {
    const k = startOfDay(d.day), prior = stats.get(k) ?? { tokens: 0, sessions: 0 };
    stats.set(k, { tokens: prior.tokens + d.tokens, sessions: prior.sessions + d.sessions });
  }
  const measured = sessions.some(s => s.tokens > 0) || [...stats.values()].some(s => s.tokens > 0);
  const sum = sessions.some(s => s.tokens > 0) ? sessions.reduce((n, s) => n + s.tokens, 0) : [...stats.values()].reduce((n, s) => n + s.tokens, 0);
  const active = [...stats].filter(([, s]) => s.tokens > 0 || s.sessions > 0).map(([d]) => d).sort((a, b) => a - b);
  const daySet = new Set(active); let longest = 0, run = 0, previous: number | undefined;
  for (const d of active) { run = previous !== undefined && nextDay(previous, 1) === d ? run + 1 : 1; longest = Math.max(longest, run); previous = d; }
  let current = 0, d = daySet.has(today) ? today : nextDay(today, -1);
  while (daySet.has(d)) { current++; d = nextDay(d, -1); }
  const history = Array.from({ length: 30 }, (_, i) => { const day = nextDay(today, i - 29), s = stats.get(day); return { day, tokens: s?.tokens ?? 0, sessionCount: s?.sessions ?? 0 }; });
  const messageSum = sessions.reduce((n, s) => n + s.messageCount, 0), durations = sessions.filter(s => s.endedAt !== undefined).map(s => Math.max(0, (s.endedAt! - s.startedAt) / 1000));
  const peak = Math.max(0, ...[...stats.values()].map(s => s.tokens));
  return {
    currentStreakDays: current, longestStreakDays: Math.max(longest, current), dailyHistory: history,
    ...(measured ? { lifetimeTokens: sum, ...(peak > 0 ? { peakDailyTokens: peak } : {}), todayTokens: stats.get(today)?.tokens ?? 0, last30DaysTokens: history.reduce((n, s) => n + s.tokens, 0) } : {}),
    ...(durations.length ? { longestChatSeconds: Math.max(...durations) } : {}),
    ...(sessions.length ? { totalSessions: sessions.length, ...(stats.has(today) ? { todaySessions: stats.get(today)!.sessions } : {}) } : {}),
    ...(sessions.length && messageSum > 0 ? { totalMessages: messageSum, todayMessages: sessions.filter(s => startOfDay(s.startedAt) === today).reduce((n, s) => n + s.messageCount, 0) } : {}),
  };
}
export function burnBreakdown(sessions: Session[], now: number, options: { since?: number; window?: QuotaWindow; fallbackToRecent?: boolean } = {}) {
  const w = options.window, mins = w && durationMins(w);
  const since = options.since ?? (w?.resetsAt !== undefined && mins ? w.resetsAt - mins * 60000 : undefined);
  const filtered = since === undefined ? [] : sessions.filter(s => s.startedAt >= since && s.startedAt <= now);
  const relevant = (filtered.length ? filtered : options.fallbackToRecent === false ? [] : sessions.slice(-8)).filter(s => totalTokens(s.tokens) > 0 && !s.isAutomation);
  if (!relevant.length) return;
  const groups = new Map<string, { projectName: string; model: string; turns: number; tokens: Tokens; hasRealSession: boolean }>();
  let sum = tokens(), turns = 0, longChatCount = 0;
  for (const s of relevant) {
    const n = Math.max(1, s.messageCount), key = `${s.projectName}|${s.model}`;
    const g = groups.get(key) ?? { projectName: s.projectName, model: s.model, turns: 0, tokens: tokens(), hasRealSession: false };
    g.turns += n; g.tokens = addTokens(g.tokens, s.tokens); g.hasRealSession ||= !s.isAggregate; groups.set(key, g);
    sum = addTokens(sum, s.tokens); turns += n;
    if ((n >= 10 || totalTokens(s.tokens) >= 100000) && !s.isAggregate) longChatCount++;
  }
  const total = totalTokens(sum), denominator = sum.input + sum.cacheRead + sum.cacheWrite;
  return {
    windowLabel: w?.label ?? "Active window", totalTokens: total, longChatCount,
    cacheHitRate: denominator > 0 ? sum.cacheRead / denominator * 100 : undefined,
    avgTokensPerTurn: turns > 0 ? Math.trunc(total / turns) : undefined,
    contributors: [...groups.values()].map(g => ({ projectName: g.projectName, model: g.model, turns: g.turns, tokens: g.tokens, totalTokens: totalTokens(g.tokens), shareOfWindow: totalTokens(g.tokens) / Math.max(1, total) * 100, isLongChat: (g.turns >= 10 || totalTokens(g.tokens) >= 100000) && g.hasRealSession })).sort((a, b) => b.totalTokens - a.totalTokens).slice(0, 3),
  };
}
