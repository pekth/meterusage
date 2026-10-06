import { type Slot, type Quota, type Loaded, type Provider, slotKey } from "./models";
import { pace, effectivePace, etaSeconds, formatETA, paceText } from "./pacing";

export const iso = (at: number) => new Date(at).toISOString().replace(/\.\d{3}Z$/, "Z");
export interface WindowReport { label: string; used_percent: number; remaining_percent: number; resets_at?: string; eta_seconds?: number; eta_text?: string; pacing?: string; burn_rate?: number }
export interface ProviderReport { provider: Provider; account?: string; status: "ok" | "unavailable"; reason?: string; plan?: string; windows: WindowReport[]; credits?: { balance: number; unit: "credits" | "dollars"; dollar_balance?: number } }
export interface LimitsReport { schema: 1; generated_at: string; providers: ProviderReport[] }
export function limitsReport(order: Slot[], quotas: Record<string, Loaded<Quota>>, burns: Record<string, number> = {}, now = Date.now()): LimitsReport {
  return {
    schema: 1,
    generated_at: iso(now),
    providers: order.map(s => {
      const state = quotas[slotKey(s)];
      const account = s.slotID ? { account: s.label } : {};
      if (state?.status !== "value") return { provider: s.provider, ...account, status: "unavailable", ...(state?.status === "missing" ? { reason: state.reason } : {}), windows: [] };
      const q = state.value;
      return {
        provider: s.provider, ...account, status: "ok", ...(q.planType === undefined ? {} : { plan: q.planType }),
        windows: q.windows.map(w => {
          const raw = pace(w, now), p = raw && effectivePace(raw, burns[slotKey(s)], now);
          const eta = p && etaSeconds(p, w.resetsAt, now);
          return {
            label: w.label, used_percent: w.usedPercent, remaining_percent: Math.max(0, 100 - w.usedPercent),
            ...(w.resetsAt === undefined ? {} : { resets_at: iso(w.resetsAt) }),
            ...(eta === undefined ? {} : { eta_seconds: eta, eta_text: formatETA(eta) }),
            ...(p ? { pacing: paceText(p), burn_rate: p.burnRate } : {}),
          };
        }),
        ...(q.credits ? { credits: { balance: q.credits.balance, unit: q.credits.unit, ...(q.credits.dollarBalance === undefined ? {} : { dollar_balance: q.credits.dollarBalance }) } } : {}),
      };
    }),
  };
}
export function canonicalJSON(v: unknown): string {
  const sorted = (x: unknown): unknown => Array.isArray(x) ? x.map(sorted) : x !== null && typeof x === "object" ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sorted((x as Record<string, unknown>)[k])])) : x;
  return JSON.stringify(sorted(v));
}
