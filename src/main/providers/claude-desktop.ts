import { closeSync, constants, fstatSync, lstatSync, openSync, readSync, existsSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { createDecipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { runCommand, type Command } from "./transport";
import { selectJSON } from "../select-json";
import { date, displayText, object, text } from "./parsers";
import { Unavailable, quota, window, type ResetCredit } from "../../domain/models";
import { readStableFile, type Decrypt } from "./windows-dpapi";
import { pathToFileURL } from "node:url";

const uuid = /^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i;
const unavailable = () => new Unavailable("notSignedIn", "Claude Desktop");
export const desktopReadErrors = {
  challenge: "Claude requires browser verification for account allowance. Open Claude usage to view it in your browser. Your current source is unchanged.",
  configuration: "Could not read Claude Desktop's account configuration.",
  organization: "Could not read Claude Desktop's active organization cookie.",
  decryption: "Could not decrypt Claude Desktop's session cookies with its Keychain entry.",
  request: "Could not read Claude account allowance. Try connecting again later.",
  verification: "Could not verify the same Claude Desktop account and session after the allowance request. Try connecting again.",
  response: "Claude did not report a supported account allowance.",
  selection: "Claude Desktop's cache has no current session for the active account and organization.",
  ambiguous: "Claude Desktop's cache has conflicting session or organization cookies. MeterUsage cannot safely choose one.",
  locked: "Could not open Claude Desktop's cookie store while Claude Desktop holds it. Quit Claude Desktop, then try connecting again.",
} as const;
/** Windows wording for the stages that name the macOS Keychain. */
export const windowsDesktopReadErrors = { ...desktopReadErrors, decryption: "Could not decrypt Claude Desktop's session cookies with its Windows-protected key." } as const;
type ReadStage = (stage: keyof typeof desktopReadErrors) => void;
export function decryptDesktop(bytes: Uint8Array, password: string): Buffer {
  const input = Buffer.from(bytes);
  if (input.length > 1048576 || input.subarray(0, 3).toString() !== "v10") throw unavailable();
  const key = pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1");
  try {
    const cipher = createDecipheriv("aes-128-cbc", key, Buffer.alloc(16, 32));
    return Buffer.concat([cipher.update(input.subarray(3)), cipher.final()]);
  } catch { throw unavailable(); }
  finally { key.fill(0); }
}
export const validClaudeIdentity = (value: unknown): value is string => typeof value === "string" && /^web-v1:[a-f\d]{64}$/.test(value);
export const claudeIdentity = (account: string, organization: string) => "web-v1:" + createHash("sha256").update(account.toLowerCase() + ":" + organization.toLowerCase()).digest("hex");
export interface DesktopCredential { account: string; organization: string; cookie: string; identity: string }
// Query only the two fixed cookies. Ciphertext and metadata remain in bounded RAM.
export const desktopCookieSQL = "SELECT host_key, name, path, is_secure, is_httponly, CAST(expires_utc AS TEXT) AS expires_utc, hex(encrypted_value) AS encrypted_value FROM cookies WHERE name IN ('sessionKey', 'lastActiveOrg') AND host_key IN ('.claude.ai', 'claude.ai') LIMIT 33";
export const desktopSchemaSQL = "SELECT CAST(value AS TEXT) AS version FROM meta WHERE key = 'version' LIMIT 2";
/** `secret` is the macOS Safe Storage password or, on Windows, a decryptor bound to the Local State key. */
export function desktopCredential(config: string, stores: { version: string; cookies: string }[], secret: string | Decrypt, now: number, reading?: ReadStage): DesktopCredential {
  const decrypt: Decrypt = typeof secret === "string" ? bytes => decryptDesktop(bytes, secret) : secret;
  try {
    reading?.("configuration");
    if (Buffer.byteLength(config) > 2 * 1048576 || !Number.isSafeInteger(now) || stores.length < 1 || stores.length > 2) throw unavailable();
    const account = text(object(selectJSON(config, { lastKnownAccountUuid: true }, undefined, true)).lastKnownAccountUuid)?.toLowerCase();
    if (!account || !uuid.test(account)) throw unavailable();
    reading?.("organization");
    const values = { sessionKey: new Set<string>(), lastActiveOrg: new Set<string>() };
    const expiry = (BigInt(now) + 120000n + 11644473600000n) * 1000n;
    for (const store of stores) {
      if (Buffer.byteLength(store.version) > 1024 || Buffer.byteLength(store.cookies) > 2 * 1048576) throw unavailable();
      const versions = JSON.parse(store.version), rows = JSON.parse(store.cookies);
      if (!Array.isArray(versions) || versions.length !== 1 || versions[0].version !== "24" || !Array.isArray(rows) || rows.length > 32) throw unavailable();
      for (const raw of rows) {
        const row = object(raw), name = row.name;
        if (name !== "sessionKey" && name !== "lastActiveOrg" || row.host_key !== ".claude.ai" && row.host_key !== "claude.ai" || row.path !== "/" || row.is_secure !== 1 || name === "sessionKey" && row.is_httponly !== 1 || typeof row.expires_utc !== "string" || !/^[1-9]\d{0,18}$/.test(row.expires_utc) || BigInt(row.expires_utc) > 9223372036854775807n || BigInt(row.expires_utc) <= expiry || typeof row.encrypted_value !== "string" || row.encrypted_value.length > 65536 || !/^(?:[a-f\d]{2})+$/i.test(row.encrypted_value)) throw unavailable();
        reading?.("decryption");
        let plaintext: Buffer;
        try { plaintext = decrypt(Buffer.from(row.encrypted_value, "hex")); } catch { throw unavailable(); }
        let value: string;
        try {
          const digest = createHash("sha256").update(row.host_key).digest();
          if (!plaintext.subarray(0, 32).equals(digest)) throw unavailable();
          value = plaintext.subarray(32).toString("utf8");
        } finally { plaintext.fill(0); }
        if (name === "sessionKey" ? !/^[A-Za-z0-9._~-]{1,16384}$/.test(value) : !uuid.test(value)) throw unavailable();
        values[name].add(name === "lastActiveOrg" ? value.toLowerCase() : value);
      }
    }
    reading?.("selection");
    if (values.sessionKey.size !== 1 || values.lastActiveOrg.size !== 1) {
      if (values.sessionKey.size > 1 || values.lastActiveOrg.size > 1) reading?.("ambiguous");
      throw unavailable();
    }
    const organization = [...values.lastActiveOrg][0];
    return { account, organization, cookie: "sessionKey=" + [...values.sessionKey][0], identity: claudeIdentity(account, organization) };
  } catch { throw unavailable(); }
}
function configFile(root: string) {
  const fd = openSync(join(root, "config.json"), constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.size > 2 * 1048576) throw unavailable();
    const bytes = Buffer.alloc(2 * 1048576 + 1);
    let length = 0, count: number;
    do { count = readSync(fd, bytes, length, bytes.length - length, null); length += count; } while (count && length < bytes.length);
    if (length > 2 * 1048576) throw unavailable();
    return bytes.subarray(0, length).toString("utf8");
  } finally { closeSync(fd); }
}
// Windows has no sandbox-exec or sqlite3. Electron's own SQLite opens each store read-only and
// immutable, so it takes no locks and writes no journal, WAL or shared-memory file beside it.
async function windowsStores(root: string, signal?: AbortSignal, reading?: ReadStage): Promise<{ version: string; cookies: string }[]> {
  const { DatabaseSync } = await import("node:sqlite"), stores: { version: string; cookies: string }[] = [];
  for (const relative of [["Cookies"], ["Network", "Cookies"]]) {
    const path = join(root, ...relative);
    if (!existsSync(path)) continue;
    if (realpathSync(path) !== path || !lstatSync(path).isFile()) throw unavailable();
    signal?.throwIfAborted();
    const uri = pathToFileURL(path); uri.searchParams.set("immutable", "1"); uri.searchParams.set("mode", "ro");
    let db: import("node:sqlite").DatabaseSync | undefined;
    // Close a store that opened but failed its first query; an open handle would keep the file locked on Windows.
    try { db = new DatabaseSync(uri.href, { readOnly: true, allowExtension: false }); db.prepare(desktopSchemaSQL).all(); }
    catch { try { db?.close(); } catch { /* Already closed. */ } reading?.("locked"); throw unavailable(); }
    try { stores.push({ version: JSON.stringify(db.prepare(desktopSchemaSQL).all()), cookies: JSON.stringify(db.prepare(desktopCookieSQL).all()) }); }
    finally { db.close(); }
  }
  return stores;
}
/** `windows.root` is Claude Desktop's app data folder (%APPDATA%\\Claude); without it the macOS store is read. */
export async function readDesktopCredential(home: string, secret: string | Decrypt, now: number, reading?: ReadStage, command: Command = runCommand, signal?: AbortSignal, windows?: { root: string }): Promise<DesktopCredential> {
  if (windows) {
    try {
      signal?.throwIfAborted(); reading?.("configuration");
      const root = realpathSync(windows.root), config = () => readStableFile(join(root, "config.json"), 2 * 1048576);
      const text = config();
      reading?.("organization");
      const stores = await windowsStores(root, signal, reading);
      signal?.throwIfAborted();
      const result = desktopCredential(text, stores, secret, now, reading);
      const after = object(selectJSON(config(), { lastKnownAccountUuid: true }, undefined, true)).lastKnownAccountUuid;
      if (typeof after !== "string" || after.toLowerCase() !== result.account) throw unavailable();
      return result;
    } catch { throw unavailable(); }
  }
  const password = secret;
  try {
    if (typeof password !== "string") throw unavailable();
    signal?.throwIfAborted(); reading?.("configuration");
    const root = realpathSync(join(home, "Library/Application Support/Claude"));
    const config = configFile(root), stores: { version: string; cookies: string }[] = [];
    // Canonical paths keep the deny rule on the actual store, including WAL/SHM.
    const sandbox = `(version 1)(allow default)(deny file-write* (subpath ${JSON.stringify(root)}))`;
    reading?.("organization");
    for (const relative of ["Cookies", "Network/Cookies"]) {
      const path = join(root, relative);
      if (!existsSync(path)) continue;
      if (realpathSync(path) !== path || !lstatSync(path).isFile()) throw unavailable();
      const read = async (sql: string, maxBytes: number) => {
        signal?.throwIfAborted();
        const raw = await command("/usr/bin/sandbox-exec", ["-p", sandbox, "/usr/bin/sqlite3", "-init", "/dev/null", "-batch", "-readonly", "-json", path, sql], { signal, timeoutMs: 5000, maxBytes });
        signal?.throwIfAborted(); return raw;
      };
      stores.push({ version: await read(desktopSchemaSQL, 1024), cookies: await read(desktopCookieSQL, 2 * 1048576) });
    }
    signal?.throwIfAborted();
    const result = desktopCredential(config, stores, password, now, reading);
    const after = object(selectJSON(configFile(root), { lastKnownAccountUuid: true }, undefined, true)).lastKnownAccountUuid;
    if (typeof after !== "string" || after.toLowerCase() !== result.account) throw unavailable();
    return result;
  } catch { throw unavailable(); }
}
export function verifyDesktopAccount(raw: string, credential: DesktopCredential) {
  try {
    if (Buffer.byteLength(raw) > 1048576) throw unavailable();
    const account = object(object(selectJSON(raw, { account: { uuid: true, memberships: { "*": { organization: { uuid: true } } } } }, undefined, true)).account);
    if (typeof account.uuid !== "string" || !uuid.test(account.uuid) || account.uuid.toLowerCase() !== credential.account || !Array.isArray(account.memberships)) throw unavailable();
    let matches = 0;
    for (const membership of account.memberships) {
      const id = object(object(membership).organization).uuid;
      if (typeof id !== "string" || !uuid.test(id)) throw unavailable();
      if (id.toLowerCase() === credential.organization) matches++;
    }
    if (matches !== 1) throw unavailable();
  } catch { throw unavailable(); }
}
const maxResetGrants = 200, maxFreeResets = 50;
/** Claude grant identifiers are redemption handles: kept in memory for redemption, never archived or reported. */
export const claudeGrantID = /^[A-Za-z0-9_-]{1,64}$/;
type Grant = { id?: string; left: number; startsAt?: number; endsAt?: number; paused: boolean; usableNow?: boolean };
const grantBound = (value: unknown) => { if (value == null) return undefined; const at = date(value); if (at === undefined) throw new Error("Invalid reset bound"); return at; };
function resetGrant(value: unknown): Grant | undefined {
  try {
    const g = object(value), left = g.resets_left, total = g.resets_total;
    if (!Number.isSafeInteger(left) || (left as number) < 0 || typeof g.paused !== "boolean") return undefined;
    if (total != null && (!Number.isSafeInteger(total) || (total as number) < (left as number))) return undefined;
    if (g.usable_now != null && typeof g.usable_now !== "boolean") return undefined;
    const id = typeof g.id === "string" && claudeGrantID.test(g.id) ? g.id : undefined;
    return { id, left: left as number, startsAt: grantBound(g.starts_at), endsAt: grantBound(g.ends_at), paused: g.paused, usableNow: g.usable_now as boolean | undefined };
  } catch { return undefined; }
}
/**
 * Claude's saved "Reset for free" grants, from the usage response's `cedar_ember` block. A live grant is not paused,
 * has resets left, has started and has not expired. It is redeemable when Claude reports it usable now, its identifier
 * is well formed and, when Claude names the next grant, it is that grant. A malformed block or an implausible inventory
 * shows no resets and never affects the usage windows.
 */
export function desktopFreeResets(block: unknown, now: number): { count: number; credits: ResetCredit[] } {
  const none = { count: 0, credits: [] };
  if (block == null || typeof block !== "object" || Array.isArray(block)) return none;
  const b = block as Record<string, unknown>;
  if (b.eligible !== true || !Array.isArray(b.grants) || b.grants.length > maxResetGrants) return none;
  const next = typeof b.next_grant_id === "string" ? b.next_grant_id : undefined;
  let count = 0; const credits: ResetCredit[] = [];
  for (const [index, grant] of b.grants.map(resetGrant).entries()) {
    if (!grant || grant.paused || grant.left === 0 || grant.startsAt !== undefined && grant.startsAt > now || grant.endsAt !== undefined && grant.endsAt <= now) continue;
    if (count + grant.left > maxFreeResets) return none;
    count += grant.left;
    const redeemable = grant.id !== undefined && grant.usableNow !== false && (next === undefined || grant.id === next);
    credits.push({ id: grant.id ?? `claude-free-reset-${index}`, title: grant.left > 1 ? `Free reset ×${grant.left}` : "Free reset", status: redeemable ? "available" : "Not usable yet", expiresAt: grant.endsAt });
  }
  credits.sort((a, b) => (a.expiresAt ?? Infinity) - (b.expiresAt ?? Infinity));
  return { count, credits };
}
const resetSelection = { eligible: true, next_grant_id: true, grants: { "*": { id: true, resets_left: true, resets_total: true, paused: true, starts_at: true, ends_at: true, usable_now: true } } } as const;
const scopedLimitSelection = { "*": { kind: true, percent: true, resets_at: true, scope: { model: { display_name: true } } } } as const;
// Selecting `resets_at: true` drops an object or array value. This pass keeps such a value as an empty container, so
// the entry can be rejected without reading its contents. Both passes keep the same container entries, so they align.
const scopedResetShapeSelection = { limits: { "*": { resets_at: {} } } } as const;
/**
 * Per-model weekly plan limits, such as Fable's on Max, from the usage response's `limits` array. Claude lists them
 * there as `weekly_scoped` entries named by model. A malformed entry is skipped and never affects the other windows,
 * and a model that a legacy `seven_day_*` key already shows is not repeated.
 */
function desktopModelWeeklyWindows(limits: unknown, resetShapes: unknown, shown: string[]) {
  if (!Array.isArray(limits) || !Array.isArray(resetShapes) || resetShapes.length !== limits.length) return [];
  const seen = new Set(shown);
  return limits.flatMap((entry, index) => {
    if (typeof object(resetShapes[index]).resets_at === "object") return [];
    const limit = object(entry), percent = limit.percent, reset = date(limit.resets_at), name = displayText(object(object(limit.scope).model).display_name);
    if (limit.kind !== "weekly_scoped" || !name || typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 100 || limit.resets_at != null && reset === undefined) return [];
    const label = `Weekly · ${name}`;
    if (seen.has(label.toLowerCase())) return [];
    seen.add(label.toLowerCase());
    return [window(label, percent, reset, 10080)];
  });
}
export function desktopQuota(raw: string, now: number) {
  const keys = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps", "seven_day_cowork"];
  const selected = object(selectJSON(raw, { ...Object.fromEntries(keys.map(key => [key, { utilization: true, resets_at: true }])), limits: scopedLimitSelection, cedar_ember: resetSelection }));
  const windows = keys.flatMap(key => {
    if (selected[key] == null) return [];
    const value = object(selected[key]), percent = value.utilization, reset = date(value.resets_at);
    if (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 100 || value.resets_at != null && reset === undefined) throw new Unavailable("noData");
    const label = key === "five_hour" ? "5-hour" : key === "seven_day" ? "Weekly · All models" : `Weekly · ${key.slice(10).replaceAll("_", " ")}`;
    return [window(label, percent, reset, key === "five_hour" ? 300 : 10080)];
  });
  if (!windows.length) throw new Unavailable("noData");
  windows.splice(windows.findIndex(w => w.label === "Weekly · All models") + 1 || windows.length, 0, ...desktopModelWeeklyWindows(selected.limits, object(selectJSON(raw, scopedResetShapeSelection)).limits, windows.map(w => w.label.toLowerCase())));
  const q = quota("claude", windows, now), resets = desktopFreeResets(selected.cedar_ember, now);
  if (resets.count) { q.resetCreditCount = resets.count; q.resetCredits = resets.credits; }
  return q;
}
/** Messages shown when Claude does not apply a confirmed free reset. */
export const claudeResetErrors = {
  notLimited: "You're not at a Claude limit, so the reset wasn't used. Try again when you reach one.",
  alreadyUsed: "This Claude reset was already used.",
  ineligible: "Claude says this reset isn't available to your account.",
  cooldown: "Claude resets are cooling down. Try again later.",
  unconfirmed: "Claude couldn't confirm the reset. If you're still limited in a moment, try again.",
  failed: "Couldn't redeem Claude reset",
} as const;
/** Returns when Claude applied the reset; otherwise throws an Error carrying one of `claudeResetErrors`. */
export function claudeResetOutcome(raw: string): void {
  let result: unknown;
  try { result = object(selectJSON(raw, { result: true })).result; } catch { throw new Error(claudeResetErrors.failed); }
  if (result === "reset") return;
  const message = result === "not_limited" ? claudeResetErrors.notLimited : result === "already_used" ? claudeResetErrors.alreadyUsed : result === "ineligible" ? claudeResetErrors.ineligible : result === "cooldown" ? claudeResetErrors.cooldown : result === "unavailable" ? claudeResetErrors.unconfirmed : claudeResetErrors.failed;
  throw new Error(message);
}
