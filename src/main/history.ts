import { readFileSync, writeFileSync, renameSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { randomUUID } from "node:crypto";
import { type Daily, type Quota, type Slot, type Tokens, tokens, totalTokens, slotKey, quota, window, providers } from "../domain/models";

export function atomicJSON(path: string, value: unknown) {
  mkdirSync(dirname(path), { recursive: true });
  const tmp = `${path}.${randomUUID()}.tmp`;
  writeFileSync(tmp, JSON.stringify(value), { mode: 0o600 });
  renameSync(tmp, path);
}
interface StoredDaily { dayISO: string; tokens: Tokens; estimatedCostUSD: number; sessionCount: number; peakUsedPercent?: number }
function validRecord(v: unknown): v is StoredDaily {
  if (!v || typeof v !== "object") return false;
  const r = v as StoredDaily;
  return typeof r.dayISO === "string" && /^\d{4}-\d{2}-\d{2}$/.test(r.dayISO) && Number.isFinite(Date.parse(r.dayISO)) && r.tokens != null && ["input", "output", "reasoning", "cacheRead", "cacheWrite"].every(k => Number.isFinite(r.tokens[k as keyof Tokens])) && Number.isFinite(r.estimatedCostUSD) && Number.isFinite(r.sessionCount) && (r.peakUsedPercent === undefined || Number.isFinite(r.peakUsedPercent));
}
export class HistoryStore {
  private data: Record<string, StoredDaily[]> = Object.create(null);
  error?: "loadFailed" | "writeFailed";
  constructor(readonly path: string) {
    try {
      const parsed: unknown = JSON.parse(readFileSync(path, "utf8"));
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) || !Object.values(parsed).every(v => Array.isArray(v) && v.every(validRecord))) throw new Error("Invalid history");
      this.data = Object.assign(Object.create(null), parsed);
    } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") this.error = "loadFailed"; }
  }
  records(key: string): Daily[] {
    return (this.data[key] ?? []).map(r => ({ day: Date.parse(r.dayISO), tokens: r.tokens, estimatedCostUSD: r.estimatedCostUSD, sessionCount: r.sessionCount }));
  }
  record(key: string, daily: Daily[], peakUsedPercent?: number) {
    if (!daily.length) return;
    const byDay = new Map((this.data[key] ?? []).map(r => [r.dayISO, r]));
    for (const d of daily) {
      const dayISO = new Date(d.day).toISOString().slice(0, 10), prior = byDay.get(dayISO);
      if (!prior || totalTokens(prior.tokens) <= totalTokens(d.tokens)) byDay.set(dayISO, { dayISO, tokens: tokens(d.tokens), estimatedCostUSD: d.estimatedCostUSD, sessionCount: d.sessionCount, ...(peakUsedPercent === undefined ? {} : { peakUsedPercent }) });
    }
    this.data[key] = [...byDay.values()].sort((a, b) => a.dayISO.localeCompare(b.dayISO));
    if (this.error === "loadFailed") return;
    try { atomicJSON(this.path, this.data); this.error = undefined; } catch { this.error = "writeFailed"; }
  }
}
const swiftEpoch = Date.UTC(2001, 0, 1);
const fromDate = (v: unknown) => v == null ? undefined : typeof v === "number" && Number.isFinite(v) && Math.abs(swiftEpoch + v * 1000) <= 8640000000000000 ? swiftEpoch + v * 1000 : (() => { throw new Error("Invalid archive date"); })();
const toDate = (v: number | undefined) => v === undefined ? undefined : (v - swiftEpoch) / 1000;
function archiveObject(raw: unknown): Record<string, unknown> {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("Invalid archive object");
  return raw as Record<string, unknown>;
}
function archiveString(raw: unknown): string | undefined {
  if (raw == null) return;
  if (typeof raw !== "string") throw new Error("Invalid archive string");
  return raw;
}
function archiveNumber(raw: unknown): number | undefined {
  if (raw == null) return;
  if (typeof raw !== "number" || !Number.isFinite(raw)) throw new Error("Invalid archive number");
  return raw;
}
function archiveInteger(raw: unknown): number | undefined {
  const value = archiveNumber(raw);
  if (value !== undefined && !Number.isSafeInteger(value)) throw new Error("Invalid archive integer");
  return value;
}
function decodeWindow(value: unknown): import("../domain/models").QuotaWindow {
  const raw = archiveObject(value);
  if (typeof raw.label !== "string") throw new Error("Invalid archive window");
  const used = archiveNumber(raw.usedPercent);
  if (used === undefined) throw new Error("Invalid archive window");
  const w = window(raw.label, used, fromDate(raw.resetsAt), archiveInteger(raw.windowDurationMins));
  if (raw.pacingBaseline != null) {
    const b = archiveObject(raw.pacingBaseline), usedPercent = archiveNumber(b.usedPercent);
    if (usedPercent === undefined) throw new Error("Invalid archive baseline");
    w.pacingBaseline = { usedPercent, capturedAt: fromDate(b.capturedAt), observedAt: fromDate(b.observedAt) };
  }
  return w;
}
function encodeWindow(w: import("../domain/models").QuotaWindow) {
  return { ...w, resetsAt: toDate(w.resetsAt), pacingBaseline: w.pacingBaseline && { ...w.pacingBaseline, capturedAt: toDate(w.pacingBaseline.capturedAt), observedAt: toDate(w.pacingBaseline.observedAt) } };
}
export function readArchive(path: string): Record<string, Quota> {
  try {
    const entries = JSON.parse(readFileSync(path, "utf8"));
    if (!Array.isArray(entries)) return {};
    const result: Record<string, Quota> = Object.create(null);
    for (const entry of entries) {
      const e = archiveObject(entry), provider = providers.find(p => p === e.provider);
      if (!provider || typeof e.capturedAt !== "number" || !Number.isFinite(e.capturedAt) || !Array.isArray(e.windows)) return {};
      const slot: Slot = { provider, slotID: archiveString(e.slotID) ?? "", label: archiveString(e.label) ?? "" };
      const q = quota(provider, e.windows.map(decodeWindow), fromDate(e.capturedAt));
      if (e.groups != null) {
        if (!Array.isArray(e.groups)) throw new Error("Invalid archive groups");
        q.groups = e.groups.map(value => { const g = archiveObject(value); if (typeof g.id !== "string" || typeof g.title !== "string" || !Array.isArray(g.windows)) throw new Error("Invalid archive group"); return { id: g.id, title: g.title, windows: g.windows.map(decodeWindow) }; });
      }
      if (e.credits != null) {
        const c = archiveObject(e.credits), units = archiveObject(c.unit), cases = Object.keys(units);
        const unit = cases.length === 1 && ["credits", "dollars"].includes(cases[0]) ? cases[0] : undefined;
        const balance = archiveNumber(c.balance);
        if (!unit || balance === undefined || typeof c.hasCredits !== "boolean" || typeof c.unlimited !== "boolean") throw new Error("Invalid archive credit");
        archiveObject(units[unit]);
        q.credits = { balance, unit: unit as "credits" | "dollars", hasCredits: c.hasCredits, unlimited: c.unlimited, usedDollars: archiveNumber(c.usedDollars), limitDollars: archiveNumber(c.limitDollars), dollarBalance: archiveNumber(c.dollarBalance) };
      }
      q.resetCreditCount = archiveInteger(e.resetCreditCount);
      q.planType = archiveString(e.planType); q.resetPacingSince = fromDate(e.resetPacingSince);
      if (e.resetCredits != null) {
        if (!Array.isArray(e.resetCredits)) throw new Error("Invalid archive resets");
        q.resetCredits = e.resetCredits.map(value => { const c = archiveObject(value); if (typeof c.id !== "string" || typeof c.title !== "string") throw new Error("Invalid archive reset"); return { id: c.id, title: c.title, status: archiveString(c.status), expiresAt: fromDate(c.expiresAt) }; });
      }
      result[slotKey(slot)] = q;
    }
    return result;
  } catch { return {}; }
}
export function saveArchive(path: string, readings: { slot: Slot; quota: Quota }[]) {
  atomicJSON(path, readings.map(({ slot: s, quota: q }) => ({ provider: s.provider, slotID: s.slotID || undefined, label: s.label || undefined, capturedAt: toDate(q.capturedAt), windows: q.windows.map(encodeWindow), groups: q.groups.length ? q.groups.map(g => ({ ...g, windows: g.windows.map(encodeWindow) })) : undefined, credits: q.credits && { ...q.credits, unit: { [q.credits.unit]: {} } }, resetCreditCount: q.resetCreditCount, resetCredits: q.resetCredits.length ? q.resetCredits.map(c => ({ ...c, expiresAt: toDate(c.expiresAt) })) : undefined, planType: q.planType, resetPacingSince: toDate(q.resetPacingSince) })));
}
