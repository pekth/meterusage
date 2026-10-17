import type { QuotaWindow, Quota } from "./models";
import { clamp } from "./models";

export interface Pace {
  usedPercent: number; remainingPercent: number; elapsedPercent: number; deficitPercent: number;
  burnRate: number; projectedExhaustion?: number; status: "deficit" | "surplus" | "onPace";
}
const observationInterval = 60000, observationFreshness = 5 * 60000;
const freshObservation = (at: number | undefined, now: number): at is number => at !== undefined && Number.isFinite(at) && Number.isFinite(now) && at <= now && now - at <= observationFreshness;
const validPercent = (used: number) => Number.isFinite(used) && used >= 0 && used <= 100;
const activeWindow = (w: QuotaWindow, now: number) => validPercent(w.usedPercent) && (w.resetsAt === undefined || Number.isFinite(w.resetsAt) && w.resetsAt > now);

export function measuredBurn(w: QuotaWindow, now: number): { percentPerHour: number; projectedExhaustion?: number } | undefined {
  const b = w.pacingBaseline;
  if (!b || !activeWindow(w, now) || !validPercent(b.usedPercent) || w.usedPercent < b.usedPercent || !freshObservation(b.capturedAt, now) || !freshObservation(b.observedAt, now) || b.observedAt - b.capturedAt < observationInterval) return;
  const percentPerHour = (w.usedPercent - b.usedPercent) * 3600000 / (b.observedAt - b.capturedAt);
  const exhaustion = percentPerHour > 0 && w.usedPercent < 100 ? b.observedAt + (100 - w.usedPercent) * 3600000 / percentPerHour : undefined;
  return { percentPerHour, ...(exhaustion !== undefined && Number.isFinite(exhaustion) && exhaustion > now && (w.resetsAt === undefined || exhaustion < w.resetsAt) ? { projectedExhaustion: exhaustion } : {}) };
}

// Callers supply only live observations from the same account/source, never archives.
export function observeQuota(current: Quota, previous: Quota | undefined, now: number): Quota {
  const sample = (w: QuotaWindow, prior?: QuotaWindow): QuotaWindow => {
    const clean = { ...w, pacingBaseline: undefined };
    if (!freshObservation(current.capturedAt, now) || !activeWindow(w, now) || previous && current.capturedAt <= previous.capturedAt) return clean;
    const b = prior?.pacingBaseline;
    const keep = prior && previous && previous.provider === current.provider && freshObservation(previous.capturedAt, now) && activeWindow(prior, now) && prior.resetsAt === w.resetsAt && prior.windowDurationMins === w.windowDurationMins && w.usedPercent >= prior.usedPercent && b && b.observedAt === previous.capturedAt && freshObservation(b.capturedAt, now) && b.capturedAt <= previous.capturedAt && validPercent(b.usedPercent) && b.usedPercent <= prior.usedPercent;
    return { ...clean, pacingBaseline: { usedPercent: keep ? b.usedPercent : w.usedPercent, capturedAt: keep ? b.capturedAt : current.capturedAt, observedAt: current.capturedAt } };
  };
  return { ...current, windows: current.windows.map(w => sample(w, previous?.windows.find(p => p.label === w.label))), groups: current.groups.map(g => ({ ...g, windows: g.windows.map(w => sample(w, previous?.groups.find(p => p.id === g.id)?.windows.find(p => p.label === w.label))) })) };
}
export function durationMins(w: QuotaWindow): number | undefined {
  if (w.windowDurationMins && w.windowDurationMins > 0) return w.windowDurationMins;
  const l = w.label.toLowerCase();
  if (/weekly|7-day|7 day/.test(l)) return 10080;
  if (/5-hour|5 hour|session/.test(l)) return 300;
  if (/monthly|30-day|30 day/.test(l)) return 43200;
  if (/rolling|daily|24h/.test(l)) return 1440;
}
export function pace(w: QuotaWindow, now: number): Pace | undefined {
  const mins = durationMins(w);
  if (w.resetsAt === undefined || w.resetsAt <= now || !mins) return;
  const baseline = w.pacingBaseline;
  if (baseline) {
    const start = baseline.capturedAt, observed = baseline.observedAt;
    if (start === undefined || observed === undefined || observed <= start || observed > now || w.usedPercent <= baseline.usedPercent || w.resetsAt <= observed || w.resetsAt <= start) return;
    const elapsed = observed - start, delta = w.usedPercent - baseline.usedPercent;
    const rate = delta / elapsed, budget = (100 - baseline.usedPercent) / (w.resetsAt - start);
    if (budget <= 0) return;
    const expected = budget * elapsed, deficit = delta - expected;
    const exhaustion = observed + (100 - w.usedPercent) / rate;
    return { usedPercent: w.usedPercent, remainingPercent: 100 - w.usedPercent, elapsedPercent: expected, deficitPercent: deficit, burnRate: rate / budget, projectedExhaustion: w.usedPercent < 100 && exhaustion < w.resetsAt ? exhaustion : undefined, status: Math.abs(deficit) <= 2 ? "onPace" : deficit > 2 ? "deficit" : "surplus" };
  }
  const duration = mins * 60000, start = w.resetsAt - duration, elapsed = now - start;
  if (elapsed < 0) return;
  const elapsedFraction = clamp(elapsed / duration, 0, 1);
  const elapsedPercent = elapsedFraction * 100, deficitPercent = w.usedPercent - elapsedPercent;
  const burnRate = elapsedFraction > 0.005 ? w.usedPercent / 100 / elapsedFraction : 1;
  const projected = start + 100 / w.usedPercent * elapsed;
  return {
    usedPercent: w.usedPercent, remainingPercent: Math.max(0, 100 - w.usedPercent), elapsedPercent, deficitPercent, burnRate,
    ...(burnRate > 1 && w.usedPercent < 100 && w.usedPercent > 0.5 && projected < w.resetsAt ? { projectedExhaustion: projected } : {}),
    status: Math.abs(deficitPercent) <= 2 ? "onPace" : deficitPercent > 2 ? "deficit" : "surplus",
  };
}
export function resetSample(current: QuotaWindow, previous: QuotaWindow | undefined, capturedAt?: number): QuotaWindow {
  const prior = previous?.pacingBaseline;
  const keep = capturedAt !== undefined && previous?.label === current.label && previous.resetsAt === current.resetsAt && durationMins(previous) === durationMins(current) && current.usedPercent >= previous.usedPercent && prior?.capturedAt !== undefined;
  return { ...current, pacingBaseline: capturedAt === undefined ? { usedPercent: current.usedPercent } : { usedPercent: keep ? prior!.usedPercent : current.usedPercent, capturedAt: keep ? prior!.capturedAt : capturedAt, observedAt: capturedAt } };
}
export function resetPacing(current: Quota, previous: Quota | undefined, since: number, capturedAt?: number, creditID?: string): Quota {
  const windows = (ws: QuotaWindow[], prior: QuotaWindow[] = []) => ws.map(w => resetSample(w, prior.find(p => p.label === w.label), capturedAt));
  return { ...current, resetPacingSince: since, windows: windows(current.windows, previous?.windows), groups: current.groups.map(g => ({ ...g, windows: windows(g.windows, previous?.groups.find(p => p.id === g.id)?.windows) })), resetCreditCount: current.resetCreditCount === undefined ? undefined : Math.max(0, current.resetCreditCount - (creditID === undefined ? 0 : 1)), resetCredits: current.resetCredits.filter(c => c.id !== creditID) };
}
export const burnActive = (lastBurn: number | undefined, now: number) => lastBurn !== undefined && now - lastBurn >= 0 && now - lastBurn < 1800000;
export function effectivePace(p: Pace, lastBurn: number | undefined, now: number): Pace {
  if (p.status !== "deficit" || burnActive(lastBurn, now)) return p;
  return { ...p, deficitPercent: 0, burnRate: 1, projectedExhaustion: undefined, status: "onPace" };
}
export const paceText = (p: Pace) => p.usedPercent >= 100 ? "exhausted early" : p.status === "deficit" ? "burning fast" : p.status === "surplus" ? "well paced" : "on pace";
export function etaSeconds(p: Pace, resetsAt: number | undefined, now: number): number | undefined {
  if (p.projectedExhaustion !== undefined && p.projectedExhaustion > now) return (p.projectedExhaustion - now) / 1000;
  if (resetsAt !== undefined && resetsAt > now && (p.burnRate <= 1 || p.status !== "deficit" || p.usedPercent >= 100)) return (resetsAt - now) / 1000;
}
export function formatETA(seconds: number, short = false): string {
  const n = Math.max(0, Math.trunc(seconds)), m = Math.floor(n / 60), h = Math.floor(m / 60), d = Math.floor(h / 24);
  const text = n < 60 ? "< 1m" : m < 60 ? `${m}m` : h < 24 ? `${h}h${m % 60 ? ` ${m % 60}m` : ""}` : `${d}d${h % 24 ? ` ${h % 24}h` : ""}`;
  return text + (short ? "" : " left");
}
