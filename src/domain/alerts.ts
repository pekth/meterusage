import { type Slot, type Quota, type Loaded, slotKey, slotName, headlineWindow } from "./models";
import { pace, effectivePace, etaSeconds } from "./pacing";
export interface Alert { slot: Slot; kind: "threshold" | "paceCliff" | "paceSoftWarning" | "expiringCredit"; title: string; body: string; sound: boolean }
export class AlertEvaluator {
  private highWater = new Map<string, number>();
  private credits = new Set<string>();
  private cliffs = new Set<string>();
  private soft = new Set<string>();
  forgetSlot(slot: string) {
    for (const state of [this.highWater, this.credits, this.cliffs, this.soft]) for (const key of state.keys()) if (key.startsWith(`${slot}/`)) state.delete(key);
  }
  events(slots: Slot[], quotas: Record<string, Loaded<Quota>>, burns: Record<string, number>, now: number): Alert[] {
    const events: Alert[] = [];
    for (const slot of slots) {
      const state = quotas[slotKey(slot)]; if (state?.status !== "value") continue;
      const q = state.value, name = slotName(slot);
      const options = slots.filter(s => slotKey(s) !== slotKey(slot)).flatMap(s => { const q = quotas[slotKey(s)]; const w = q?.status === "value" ? headlineWindow(s.provider, q.value.windows) : undefined; return w && w.usedPercent < 50 ? [`${slotName(s)} ${Math.trunc(w.usedPercent)}%`] : []; });
      const nudge = options.length ? ` Switch suggestion: ${options.join(" · ")}` : "";
      for (const w of q.windows) {
        const key = `${slotKey(slot)}/${w.label}`, previous = this.highWater.get(key) ?? 0;
        if (w.usedPercent < previous - 0.001) { this.highWater.set(key, 0); this.cliffs.delete(key); this.soft.delete(key); }
        const rearmed = this.highWater.get(key) ?? 0, threshold = w.usedPercent >= 95 ? 95 : w.usedPercent >= 80 ? 80 : undefined;
        if (threshold !== undefined && w.usedPercent > rearmed && rearmed < threshold) events.push({ slot, kind: "threshold", title: threshold === 95 ? "Quota almost gone" : "Quota getting low", body: `${name} ${w.label} window is at ${Math.round(w.usedPercent)}% used.${nudge}`, sound: threshold === 95 });
        this.highWater.set(key, Math.max(rearmed, w.usedPercent));
        const raw = pace(w, now), p = raw && effectivePace(raw, burns[slotKey(slot)], now);
        if (p?.status !== "deficit") continue;
        if (w.usedPercent >= 50 && !this.soft.has(key)) { this.soft.add(key); events.push({ slot, kind: "paceSoftWarning", title: `${name} pace warning`, body: `${w.label} window at ${Math.round(w.usedPercent)}% used and burning faster than pace.${nudge}`, sound: false }); }
        const eta = etaSeconds(p, w.resetsAt, now);
        if (eta !== undefined && eta < 1800 && !this.cliffs.has(key)) { this.cliffs.add(key); events.push({ slot, kind: "paceCliff", title: `${name} burning fast`, body: `${w.label} window projected to empty in ~${Math.max(1, Math.trunc(eta / 60))}m before reset.${nudge}`, sound: true }); }
      }
      for (const credit of q.resetCredits) {
        const key = `${slotKey(slot)}/${credit.id}`;
        if (!this.credits.has(key) && credit.expiresAt !== undefined && credit.expiresAt > now && credit.expiresAt - now <= 86400000) { this.credits.add(key); events.push({ slot, kind: "expiringCredit", title: "Reset credit expiring", body: `A ${name} reset credit (${credit.title}) expires within 24 hours.`, sound: false }); }
      }
    }
    return events;
  }
}
