import { type Quota, type QuotaWindow, window, slotKey, headlineWindow } from "./models";
import type { Snapshot } from "../shared/state";
export interface Rect { x: number; y: number; width: number; height: number }
export const stripWidth = 44, cardWidth = 250;
// Coordinates here use Electron's top-left origin. Persistence converts the
// saved AppKit top-right corner at the native boundary.
export function notchFrame(anchor: { x: number; y: number }, size: { width: number; height: number }, cardOnRight: boolean, screen: Rect): Rect {
  const width = Math.ceil(size.width), height = Math.min(Math.ceil(size.height), Math.floor(screen.height));
  const x = cardOnRight ? anchor.x - stripWidth : anchor.x - width;
  return { x: Math.round(Math.min(Math.max(x, screen.x), Math.max(screen.x + screen.width - width, screen.x))), y: Math.round(Math.min(Math.max(anchor.y, screen.y), Math.max(screen.y + screen.height - height, screen.y))), width, height };
}
export function cardOnRight(anchorX: number, screen: Rect) {
  const left = anchorX - stripWidth - screen.x, right = screen.x + screen.width - anchorX;
  return left < cardWidth && right > left;
}

// Account spend is a notch display fallback, not a new report quota window.
export function effectiveWindows(q: Quota): QuotaWindow[] {
  if (q.windows.length || q.provider !== "openRouter") return q.windows;
  const c = q.credits;
  return c?.unit === "dollars" && c.usedDollars !== undefined && c.limitDollars !== undefined && c.limitDollars > 0 ? [window("Account balance", c.usedDollars / c.limitDollars * 100)] : [];
}
export function notchEntries(s: Snapshot) {
  const counts = new Map<string, number>();
  return s.notchSlots.flatMap(slot => {
    let digit: number | undefined;
    if (slot.slotID) { digit = (counts.get(slot.provider) ?? 1) + 1; counts.set(slot.provider, digit); }
    const key = slotKey(slot), state = s.quotas[key], fresh = state?.status === "value", q = fresh ? state.value : s.archived[key], w = q && headlineWindow(slot.provider, effectiveWindows(q));
    return w ? [{ slot, key, window: w, fresh, digit }] : [];
  });
}
export function minimumShareSize(width: number, height: number, nativeScale: number) {
  const scale = Math.max(2, nativeScale);
  return { width: Math.ceil(width * scale), height: Math.ceil(height * scale) };
}
