import type { Snapshot } from "./state";
import type { Provider } from "../domain/models";
export const channel = "meterusage:request", stateChannel = "meterusage:state";
export const statusPages = { codex: "https://status.openai.com/", claude: "https://status.claude.com/", cursor: "https://status.cursor.com/", copilot: "https://www.githubstatus.com/" };
export type Surface = "flyout" | "settings" | "notch" | "tray" | "share";
export enum PanelSize { Small = "small", Medium = "medium", Large = "large" }
export const panelScales = { [PanelSize.Small]: 0.9, [PanelSize.Medium]: 1, [PanelSize.Large]: 1.15 };
export type ConnectionProvider = "codex" | "claude" | "grok";
export interface ConnectionState { provider: ConnectionProvider; status: "disconnected" | "connecting" | "connected" | "failed" | "unsupported" }
export interface SettingsState {
  values: Record<string, boolean | number | string>;
  accounts: { id: string; provider: "codex" | "claude"; label: string; pathLabel?: string; enabled: boolean }[];
}
export interface ViewState {
  connections?: ConnectionState[];
  snapshot: Snapshot; settings: SettingsState; systemDark: boolean;
  notch: { expanded: boolean; cardOnRight: boolean; selected: string; dragging: boolean; maxHeight?: number };
  update?: { version: string; state: "idle" | "downloading" | "installing" | "failed" };
}
export type Request =
  | { action: "state" | "refresh" | "settings" | "close" | "quit" | "clearCache" | "copyDiagnostics" | "copyJSON" | "dragStart" | "dragEnd" | "notchContext" | "updateInstall" | "updateDismiss" }
  | { action: "share"; key: string }
  | { action: "statusPage"; provider: keyof typeof statusPages }
  | { action: "setPreference"; key: string; value: boolean | number | string }
  | { action: "accountAdd"; provider: "codex" | "claude" }
  | { action: "connect" | "disconnect" | "connectionCancel"; provider: ConnectionProvider }
  | { action: "accountUpdate"; id: string; label?: string; enabled?: boolean }
  | { action: "accountRemove"; id: string }
  | { action: "accountPath"; id: string }
  | { action: "reset"; key: string; creditID: string }
  | { action: "notchSelect"; key: string }
  | { action: "notchHover"; hovering: boolean }
  | { action: "shareResize"; height: number }
  | { action: "resize"; height: number; width?: number };
export type Reply = { ok: true; state?: ViewState } | { ok: false; error: string };
export interface Bridge { request(request: Request): Promise<Reply>; subscribe(observer: (state: ViewState) => void): () => void }
declare global { interface Window { meterusage?: Bridge } }
export const editableBooleans = ["launchAtLogin", "showHeatmap", "showClaudeHeatmap", "showCodexHeatmap", "quotaAlertsEnabled", "sideNotchPanelEnabled", "sideNotchPanelPinned", "menuBarCompactEnabled", "onboardingCompleted", "updateCheckEnabled", "showPacingBurnRate", "showActivityTelemetry", "showDailyActivityChart", "showSideNotchResetButton"];
export const providerKey = (p: Provider) => `showProvider${p[0].toUpperCase()}${p.slice(1)}`;
export const trayKey = (p: Provider) => `menuBarProvider${p[0].toUpperCase()}${p.slice(1)}`;
