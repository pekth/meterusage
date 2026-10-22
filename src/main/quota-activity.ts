import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { type Quota, type QuotaWindow, localDay } from "../domain/models";
import { atomicJSON } from "./history";

// Builds each provider's heatmap from its own quota readings. Desktop and web
// clients leave no local transcripts, but quota readings are account-wide, so
// the rise in a provider's tracking window covers every device. Each slot keeps
// its own series; providers never share one. Only labels, percentages, and
// dates are stored. The first reading spreads the window's existing usage over
// its elapsed days as an estimate; later rises land on the day observed, and a
// rise seen after the Mac was offline lands on the day of the next reading.

export interface QuotaDay { day: number; percent: number; estimated?: boolean }
interface Series { label: string; lastPercent: number; lastResetsAt?: number; days: QuotaDay[]; seeded?: boolean }

const retentionDays = 200;
const weekMins = 10080;

function durationMins(w: QuotaWindow) {
  if (w.windowDurationMins && w.windowDurationMins > 0) return w.windowDurationMins;
  const l = w.label.toLowerCase();
  if (l.includes("weekly") || l.includes("7-day") || l.includes("7 day")) return weekMins;
  if (l.includes("month")) return 43200;
  if (l.includes("daily") || l.includes("24-hour")) return 1440;
  if (l.includes("5-hour") || l.includes("session")) return 300;
  return 0;
}

/** The weekly all-models window when present, else the longest reported window. */
export function trackingWindow(q: Quota): QuotaWindow | undefined {
  const windows = q.windows.length ? q.windows : q.groups.flatMap(g => g.windows);
  const weekly = windows.filter(w => durationMins(w) === weekMins);
  return weekly.find(w => w.label.toLowerCase().includes("all")) ?? weekly[0] ?? [...windows].sort((a, b) => durationMins(b) - durationMins(a))[0];
}

/** Spreads the usage already in the current window evenly over its elapsed
 *  local days, marked estimated: when it happened inside the window is unknown. */
function seed(series: Series, w: QuotaWindow, at: number) {
  series.seeded = true;
  if (!(w.usedPercent > 0)) return;
  const mins = durationMins(w), start = w.resetsAt !== undefined && mins ? Math.max(w.resetsAt - mins * 60_000, at - retentionDays * 86_400_000) : at;
  const days: number[] = [];
  for (let d = localDay(Math.min(start, at)); d <= localDay(at); d = localDay(d + 36 * 3_600_000)) days.push(d);
  const share = w.usedPercent / days.length;
  for (const day of days) {
    const found = series.days.find(d => d.day === day);
    if (found) { found.percent += share; found.estimated = true; } else series.days.push({ day, percent: share, estimated: true });
  }
  series.days.sort((a, b) => a.day - b.day);
}

function validSeries(v: unknown): v is Series {
  const s = v as Series;
  return !!s && (s.seeded === undefined || typeof s.seeded === "boolean") && typeof s.label === "string" && Number.isFinite(s.lastPercent) && (s.lastResetsAt === undefined || Number.isFinite(s.lastResetsAt)) && Array.isArray(s.days) && s.days.every(d => Number.isFinite(d?.day) && Number.isFinite(d?.percent));
}

export class QuotaActivityStore {
  private data: Record<string, Series> = Object.create(null);
  constructor(readonly path: string) {
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) for (const [key, s] of Object.entries(parsed)) if (validSeries(s)) this.data[key] = s;
    } catch { /* A missing or unreadable file starts a fresh history. */ }
  }
  days(key: string): QuotaDay[] { return (this.data[key]?.days ?? []).map(d => ({ ...d })); }
  retire(key: string) {
    if (!this.data[key]) return;
    // Preserve old observations without attributing them to the replacement account.
    this.data[`${key}#retired-${randomUUID()}`] = this.data[key];
    delete this.data[key]; this.save();
  }
  record(key: string, q: Quota, at: number) {
    const w = trackingWindow(q); if (!w) return;
    const prior = this.data[key], current = w.usedPercent;
    if (!prior || prior.label !== w.label) {
      const series: Series = { label: w.label, lastPercent: current, ...(w.resetsAt === undefined ? {} : { lastResetsAt: w.resetsAt }), days: prior?.days ?? [] };
      this.data[key] = series; seed(series, w, at);
      return this.save();
    }
    // Series baselined before seeding existed get the current window once.
    if (!prior.seeded) {
      // Rises already recorded inside the window are not counted twice.
      const resetsAt = prior.lastResetsAt ?? w.resetsAt, mins = durationMins(w), windowStart = resetsAt !== undefined && mins ? localDay(resetsAt - mins * 60_000) : localDay(at);
      const recorded = prior.days.filter(d => d.day >= windowStart).reduce((n, d) => n + d.percent, 0);
      seed(prior, { ...w, usedPercent: Math.max(0, prior.lastPercent - recorded), resetsAt }, at);
    }
    const rolled = (prior.lastResetsAt !== undefined && w.resetsAt !== undefined && Math.abs(w.resetsAt - prior.lastResetsAt) > 3_600_000) || current + 0.5 < prior.lastPercent;
    const delta = rolled ? current : Math.max(0, current - prior.lastPercent);
    prior.lastPercent = current;
    if (w.resetsAt === undefined) delete prior.lastResetsAt; else prior.lastResetsAt = w.resetsAt;
    if (delta > 0) {
      const day = localDay(at), found = prior.days.find(d => d.day === day);
      if (found) found.percent += delta; else prior.days.push({ day, percent: delta });
      const cutoff = localDay(at - retentionDays * 86_400_000);
      prior.days = prior.days.filter(d => d.day >= cutoff).sort((a, b) => a.day - b.day);
    }
    this.save();
  }
  private save() { try { atomicJSON(this.path, this.data); } catch { /* History is best effort. */ } }
}
