import type { Slot, Loaded, Quota, Activity, Usage, ServiceStatus, Provider } from "../domain/models";
export interface Snapshot {
  demo: boolean; refreshing: boolean; clock: number; lastRefreshedAt?: number;
  slots: Slot[]; traySlots: Slot[]; notchSlots: Slot[];
  quotas: Record<string, Loaded<Quota>>; archived: Record<string, Quota>;
  activities: Record<string, Loaded<Activity>>; usages: Record<string, Loaded<Usage>>;
  plans: Record<string, Loaded<string>>; statuses: Partial<Record<Provider, Loaded<ServiceStatus>>>;
  appearance: { theme: string; accent: string; heatmap: boolean; claudeHeatmap: boolean; codexHeatmap: boolean; pacing: boolean; telemetry: boolean; chart: boolean; resetButton: boolean; compactTray: boolean; notch: boolean; pinned: boolean; onboarding: boolean };
  historyError?: "loadFailed" | "writeFailed"; archiveWriteFailed: boolean; clearingCache: boolean;
}
