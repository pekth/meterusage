import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { providers, type Provider, type ManagedAccount } from "../domain/models";
import { atomicJSON } from "./history";
import { runCommand, type Command } from "./providers/transport";
import { type Launch } from "./launch";
export const defaultsDomain = "dev.meterusage.app";
const suffix = (p: Provider) => p[0].toUpperCase() + p.slice(1);
export const providerPreference = (p: Provider) => `showProvider${suffix(p)}`;
export const trayPreference = (p: Provider) => `menuBarProvider${suffix(p)}`;
export type PreferenceValue = boolean | number | string | ManagedAccount[];
type Kind = "boolean" | "number" | "string" | "data" | "date";
const kinds: Record<string, Kind> = {
  refreshIntervalSeconds: "number", appearanceTheme: "string", accentTheme: "string", managedAccounts: "data",
  sideNotchPanelCorner: "string", updateLastCheckDate: "date", updateDismissedVersion: "string", updateAnnouncedVersion: "string",
  desktopCodexConnection: "string", desktopCodexCleanup: "string", desktopClaudeIdentity: "string",
  ...Object.fromEntries(["launchAtLogin", "showHeatmap", "showClaudeHeatmap", "showCodexHeatmap", "quotaAlertsEnabled", "sideNotchPanelEnabled", "sideNotchPanelPinned", "menuBarCompactEnabled", "onboardingCompleted", "updateCheckEnabled", "showPacingBurnRate", "showActivityTelemetry", "showDailyActivityChart", "showSideNotchResetButton", ...providers.flatMap(p => [providerPreference(p), trayPreference(p)])].map(k => [k, "boolean" as const])),
};
export const initialPreferences: Record<string, PreferenceValue> = {
  refreshIntervalSeconds: 60, appearanceTheme: "system", accentTheme: "blue", managedAccounts: [], sideNotchPanelCorner: "",
  launchAtLogin: false, showHeatmap: true, showClaudeHeatmap: true, showCodexHeatmap: true, quotaAlertsEnabled: false,
  sideNotchPanelEnabled: false, sideNotchPanelPinned: false, menuBarCompactEnabled: true, onboardingCompleted: false,
  updateCheckEnabled: true, showPacingBurnRate: true, showActivityTelemetry: true, showDailyActivityChart: true, showSideNotchResetButton: true,
  updateDismissedVersion: "", updateAnnouncedVersion: "",
  desktopCodexConnection: "", desktopCodexCleanup: "", desktopClaudeIdentity: "",
  ...Object.fromEntries(providers.flatMap(p => [[providerPreference(p), ["codex", "openCodeGo", "openRouter"].includes(p)], [trayPreference(p), true]])),
};
const codexTestPreferences: Record<string, PreferenceValue> = {
  launchAtLogin: false, updateCheckEnabled: false, desktopClaudeIdentity: "off",
  ...Object.fromEntries(providers.filter(p => p !== "codex").map(p => [providerPreference(p), false])),
};
export function validAccounts(raw: unknown): raw is ManagedAccount[] {
  return Array.isArray(raw) && raw.every(a => a && typeof a === "object" && typeof a.id === "string" && /^[A-Za-z0-9-]{1,80}$/.test(a.id) && ["codex", "claude"].includes(a.provider) && typeof a.label === "string" && a.label.length <= 100 && !/[\r\n]/.test(a.label) && typeof a.path === "string" && a.path.length <= 4096 && !/[\r\n\0]/.test(a.path) && typeof a.enabled === "boolean") && new Set(raw.map(a => a.id)).size === raw.length;
}
function validate(key: string, v: unknown): v is PreferenceValue {
  const kind = kinds[key]; if (!kind) return false;
  if (kind === "data") return validAccounts(v);
  if (kind === "date" || kind === "number") return typeof v === "number" && Number.isFinite(v);
  if (kind === "boolean") return typeof v === "boolean";
  if (typeof v !== "string" || v.length > 100 || /[\r\n\0]/.test(v)) return false;
  if (key === "appearanceTheme") return ["system", "light", "dark"].includes(v);
  if (key === "accentTheme") return ["blue", "violet", "teal", "amber", "rose", "graphite"].includes(v);
  if (key === "sideNotchPanelCorner") return v === "" || /^-?\d+(?:\.\d+)?,-?\d+(?:\.\d+)?$/.test(v);
  if (key === "desktopCodexConnection" || key === "desktopCodexCleanup") return v === "" || key === "desktopCodexConnection" && v === "off" || /^[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(v);
  if (key === "desktopClaudeIdentity") return v === "" || v === "off" || /^[a-f\d]{64}$/.test(v);
  return true;
}
export class Preferences {
  values: Record<string, PreferenceValue> = structuredClone(initialPreferences);
  private writes: Promise<void> = Promise.resolve();
  private constructor(readonly launch: Launch, readonly command: Command, readonly domain: string) {}
  static async load(launch: Launch, command: Command = runCommand, domain = defaultsDomain): Promise<Preferences> {
    const prefs = new Preferences(launch, command, domain);
    if (launch.codexTest) prefs.values.desktopCodexConnection = "off";
    if (launch.demo || launch.codexTest) {
      const path = join(launch.data, "preferences.json");
      if (existsSync(path)) { try { const raw = JSON.parse(readFileSync(path, "utf8")); for (const [key, v] of Object.entries(raw)) if (validate(key, v)) prefs.values[key] = v; } catch { /* Keep known defaults for a damaged candidate file. */ } }
      else if (launch.demo) for (const p of providers) prefs.values[providerPreference(p)] = true;
    } else {
      await Promise.all(Object.keys(kinds).map(async key => {
        try {
          const type = await command("/usr/bin/defaults", ["read-type", domain, key], { timeoutMs: 5000 });
          const raw = (await command("/usr/bin/defaults", ["read", domain, key], { timeoutMs: 5000 })).trim();
          const kind = kinds[key]; let value: unknown;
          if (kind === "data" && /data/i.test(type) && /^<[a-f\d\s]*>$/i.test(raw)) value = JSON.parse(Buffer.from(raw.slice(1, -1).replace(/\s/g, ""), "hex").toString("utf8"));
          else if (kind === "boolean" && /boolean|integer/i.test(type)) value = raw === "1" || raw === "true" || raw === "YES";
          else if (kind === "number" && /integer|float|double/i.test(type)) value = Number(raw);
          else if (kind === "date" && /date/i.test(type)) value = Date.parse(raw);
          else if (kind === "string" && /string/i.test(type)) value = raw;
          if (validate(key, value)) prefs.values[key] = value;
        } catch { /* An absent or mismatched key retains its registered default. */ }
      }));
    }
    if (launch.codexTest) Object.assign(prefs.values, codexTestPreferences);
    prefs.values.refreshIntervalSeconds = prefs.refreshInterval; return prefs;
  }
  get refreshInterval() { const stored = this.values.refreshIntervalSeconds as number; return Math.max(30, stored > 0 ? stored : 60); }
  get accounts() { return this.values.managedAccounts as ManagedAccount[]; }
  enabled(p: Provider) { return (!this.launch.codexTest || p === "codex") && this.values[providerPreference(p)] === true; }
  private enqueue(write: () => Promise<void>) {
    const result = this.writes.then(write); this.writes = result.catch(() => {}); return result;
  }
  set(key: string, value: unknown) { return this.enqueue(() => this.write(key, value)); }
  updateAccounts(update: (accounts: ManagedAccount[]) => ManagedAccount[]) {
    return this.enqueue(() => this.write("managedAccounts", update(structuredClone(this.accounts))));
  }
  private async write(key: string, value: unknown) {
    if (!validate(key, value)) throw new Error("Invalid preference");
    if (this.launch.codexTest && key in codexTestPreferences && value !== codexTestPreferences[key]) throw new Error("Preference unavailable in Codex test mode");
    if (key === "refreshIntervalSeconds") value = Math.max(30, (value as number) > 0 ? value as number : 60);
    if (this.launch.demo || this.launch.codexTest) {
      const next = { ...this.values, [key]: value as PreferenceValue }; atomicJSON(join(this.launch.data, "preferences.json"), next);
    } else {
      const kind = kinds[key]; const typed = kind === "data" ? ["-data", Buffer.from(JSON.stringify(value)).toString("hex")] : kind === "date" ? ["-date", new Date(value as number).toISOString()] : kind === "boolean" ? ["-bool", value ? "true" : "false"] : kind === "number" ? ["-float", String(value)] : ["-string", value as string];
      await this.command("/usr/bin/defaults", ["write", this.domain, key, ...typed], { timeoutMs: 5000 });
    }
    this.values[key] = value as PreferenceValue;
  }
}
