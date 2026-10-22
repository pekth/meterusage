import { normalizeProviderOrder, orderedSlots, validProviderOrder } from "../domain/provider-order";
import { NotchFold } from "../main/notch-fold";
import { demoSources } from "../main/demo";
import { value, missing, slotKey } from "../domain/models";
import { editableBooleans, providerKey, trayKey, type Bridge, type ViewState } from "../shared/ipc";
// Dedicated browser-demo builds have no IPC, filesystem, credentials or live
// transports. They are a visual test target, never a native-parity receipt.
export async function previewBridge(): Promise<Bridge> {
  const clock = Date.now(), sources = demoSources(() => clock), slots = orderedSlots(sources.map(s => s.slot), undefined);
  const state: ViewState = { systemDark: true, snapshot: { demo: true, refreshing: false, clock, lastRefreshedAt: clock, slots, traySlots: slots.filter(s => s.provider !== "openRouter"), notchSlots: slots, quotas: {}, archived: {}, activities: {}, usages: {}, plans: {}, statuses: {}, appearance: { theme: "dark", accent: "blue", heatmap: true, claudeHeatmap: true, codexHeatmap: true, pacing: true, telemetry: true, chart: true, resetButton: true, compactTray: true, notch: true, pinned: false, onboarding: false }, archiveWriteFailed: false, clearingCache: false }, settings: { providerOrder: normalizeProviderOrder(undefined), values: { refreshIntervalSeconds: 60, appearanceTheme: "dark", accentTheme: "blue", ...Object.fromEntries(editableBooleans.map(k => [k, true])), ...Object.fromEntries(slots.flatMap(s => [[providerKey(s.provider), true], [trayKey(s.provider), true]])) }, accounts: [] }, notch: { expanded: false, cardOnRight: false, selected: "codex", dragging: false } };
  await Promise.all(sources.map(async s => { const k = slotKey(s.slot); for (const kind of ["quota", "activity", "usage", "plan", "status"] as const) { const read = s[kind]; if (!read) continue; const field = ({ quota: "quotas", activity: "activities", usage: "usages", plan: "plans", status: "statuses" } as const)[kind]; try { Object.assign(state.snapshot[field], { [kind === "status" ? s.slot.provider : k]: value(await read()) }); } catch (e) { Object.assign(state.snapshot[field], { [k]: missing(e, s.slot.provider) }); } } }));
  const observers = new Set<(s: ViewState) => void>();
  const publish = () => { for (const observer of observers) observer(structuredClone(state)); };
  const folding = new NotchFold(() => state.notch.dragging, () => { state.notch.expanded = false; publish(); });
  return { subscribe: observe => { observers.add(observe); return () => { observers.delete(observe); }; }, request: async r => {
    if (r.action === "state") return { ok: true, state: structuredClone(state) };
    if (r.action === "setPreference") {
      state.settings.values[r.key] = r.value;
      if (r.key === "appearanceTheme") state.snapshot.appearance.theme = String(r.value);
      if (r.key === "accentTheme") state.snapshot.appearance.accent = String(r.value);
      if (r.key === "onboardingCompleted") state.snapshot.appearance.onboarding = r.value === true;
    } else if (r.action === "providerOrder") {
      if (!validProviderOrder(r.order)) return { ok: false, error: "Invalid order" };
      state.settings.providerOrder = [...r.order];
      for (const key of ["slots", "traySlots", "notchSlots"] as const) state.snapshot[key] = orderedSlots(state.snapshot[key], r.order);
    } else if (r.action === "notchSelect") { state.notch.selected = r.key; state.notch.expanded = true; }
    else if (r.action === "notchHover") { folding.hovered = r.hovering; if (r.hovering) state.notch.expanded = true; folding.changed(); }
    else if (["resize", "refresh"].includes(r.action)) { /* Synthetic visual actions only. */ }
    else return { ok: false, error: "This action requires the native candidate." };
    publish(); return { ok: true };
  } };
}
