import { providers, type Provider, type Slot } from "./models";
export function normalizeProviderOrder(raw: unknown): Provider[] {
  const known = Array.isArray(raw) ? raw.filter((p): p is Provider => providers.includes(p)) : [];
  return [...new Set([...known, ...providers])];
}
export function validProviderOrder(raw: unknown): raw is Provider[] {
  return Array.isArray(raw) && raw.length === providers.length && providers.every(p => raw.includes(p));
}
export function orderedSlots(slots: readonly Slot[], order: unknown): Slot[] {
  return normalizeProviderOrder(order).flatMap(p => slots.filter(s => s.provider === p));
}
export function moveProvider(order: readonly Provider[], provider: Provider, offset: -1 | 1): Provider[] {
  const next = [...order], from = next.indexOf(provider), to = from + offset;
  if (from >= 0 && to >= 0 && to < next.length) [next[from], next[to]] = [next[to], next[from]];
  return next;
}
