import { basename, relative } from "node:path";
import type { ManagedAccount } from "../domain/models";
import type { PreferenceValue } from "./preferences";
import type { Surface, SettingsState } from "../shared/ipc";
import { providers } from "../domain/models";
import { editableBooleans, providerKey, trayKey, type Request } from "../shared/ipc";
const empty = new Set(["state", "refresh", "settings", "close", "quit", "clearCache", "copyDiagnostics", "copyJSON", "share", "dragStart", "dragEnd", "notchContext", "updateInstall", "updateDismiss"]);
const id = (v: unknown) => typeof v === "string" && /^[A-Za-z0-9-]{1,80}$/.test(v);
const key = (v: unknown) => typeof v === "string" && providers.some(p => v === p || (v.startsWith(p + "#") && id(v.slice(p.length + 1))));
const string = (v: unknown, max: number) => typeof v === "string" && v.length <= max && !/[\r\n\0]/.test(v);
const boolKeys = new Set([...editableBooleans, ...providers.flatMap(p => [providerKey(p), trayKey(p)])]);
export function parseRequest(raw: unknown): Request {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("Invalid request");
  const r = raw as Record<string, unknown>, action = r.action;
  let fields: string[] = [], valid = false;
  if (typeof action === "string" && empty.has(action)) valid = true;
  else switch (action) {
    case "setPreference":
      fields = ["key", "value"];
      valid = typeof r.key === "string" && (boolKeys.has(r.key) ? typeof r.value === "boolean" : r.key === "refreshIntervalSeconds" ? typeof r.value === "number" && [30, 60, 120, 300, 900].includes(r.value) : r.key === "appearanceTheme" ? typeof r.value === "string" && ["system", "light", "dark"].includes(r.value) : r.key === "accentTheme" && typeof r.value === "string" && ["blue", "violet", "teal", "amber", "rose", "graphite"].includes(r.value));
      break;
    case "accountAdd": fields = ["provider"]; valid = r.provider === "codex" || r.provider === "claude"; break;
    case "accountUpdate": fields = ["id", ...("label" in r ? ["label"] : []), ...("enabled" in r ? ["enabled"] : [])]; valid = id(r.id) && fields.length > 1 && (!("label" in r) || string(r.label, 100)) && (!("enabled" in r) || typeof r.enabled === "boolean"); break;
    case "accountRemove": case "accountPath": fields = ["id"]; valid = id(r.id); break;
    case "reset": fields = ["key", "creditID"]; valid = key(r.key) && string(r.creditID, 200) && r.creditID !== ""; break;
    case "notchSelect": fields = ["key"]; valid = key(r.key); break;
    case "notchHover": fields = ["hovering"]; valid = typeof r.hovering === "boolean"; break;
    case "resize": fields = ["height", ...("width" in r ? ["width"] : [])]; valid = typeof r.height === "number" && Number.isFinite(r.height) && r.height >= 20 && r.height <= 2000 && (!("width" in r) || typeof r.width === "number" && Number.isFinite(r.width) && r.width >= 1 && r.width <= 10000); break;
  }
  if (!valid || Object.keys(r).some(k => k !== "action" && !fields.includes(k)) || fields.some(k => !(k in r))) throw new Error("Invalid request");
  return r as unknown as Request;
}
// A frame URL alone is insufficient: only registered app windows, their main
// frame and the exact loaded document may invoke the bridge.
export function trustedSender(event: { sender: { id: number; mainFrame: unknown }; senderFrame?: { url: string } | null }, documents: ReadonlyMap<number, string>) {
  return event.senderFrame === event.sender.mainFrame && documents.get(event.sender.id) === event.senderFrame?.url;
}

export function projectSettings(values: Record<string, PreferenceValue>, accounts: ManagedAccount[], home: string, surface?: Surface): SettingsState {
  return {
    values: Object.fromEntries(["refreshIntervalSeconds", "appearanceTheme", "accentTheme", ...editableBooleans, ...providers.flatMap(p => [providerKey(p), trayKey(p)])].map(k => [k, values[k] as boolean | number | string])),
    accounts: accounts.map(a => {
      const sub = relative(home, a.path), pathLabel = a.path.startsWith("~") ? a.path : !sub.startsWith("..") ? `~/${sub}` : basename(a.path);
      return { id: a.id, provider: a.provider, label: a.label, enabled: a.enabled, ...(surface === "settings" ? { pathLabel } : {}) };
    }),
  };
}
