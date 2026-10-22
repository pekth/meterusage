import type { ApiBillingProvider, ApiBillingReading } from "../domain/api-billing";
import type { Slot, Loaded, Quota, Activity, Usage, ServiceStatus, Provider, AccountActivity } from "../domain/models";
export interface Snapshot {
  apiBilling?: Partial<Record<ApiBillingProvider, ApiBillingReading>>;
  demo: boolean; refreshing: boolean; clock: number; lastRefreshedAt?: number;
  slots: Slot[]; traySlots: Slot[]; notchSlots: Slot[];
  quotas: Record<string, Loaded<Quota>>; archived: Record<string, Quota>;
  accountActivities?: Record<string, Loaded<AccountActivity>>;
  activities: Record<string, Loaded<Activity>>;
  /** Per-slot daily rise in quota used, from that provider's own readings. */
  quotaActivity?: Record<string, { day: number; percent: number; estimated?: boolean }[]>; usages: Record<string, Loaded<Usage>>;
  plans: Record<string, Loaded<string>>; statuses: Partial<Record<Provider, Loaded<ServiceStatus>>>;
  appearance: { theme: string; accent: string; heatmap: boolean; claudeHeatmap: boolean; codexHeatmap: boolean; pacing: boolean; telemetry: boolean; chart: boolean; resetButton: boolean; compactTray: boolean; notch: boolean; pinned: boolean; onboarding: boolean };
  historyError?: "loadFailed" | "writeFailed"; archiveWriteFailed: boolean; clearingCache: boolean;
}
