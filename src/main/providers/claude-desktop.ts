import { closeSync, constants, fstatSync, lstatSync, openSync, readSync, existsSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { createDecipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { runCommand, type Command } from "./transport";
import { selectJSON } from "../select-json";
import { date, object, text } from "./parsers";
import { Unavailable, quota, window } from "../../domain/models";

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
} as const;
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
export function desktopCredential(config: string, stores: { version: string; cookies: string }[], password: string, now: number, reading?: ReadStage): DesktopCredential {
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
        const plaintext = decryptDesktop(Buffer.from(row.encrypted_value, "hex"), password);
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
export async function readDesktopCredential(home: string, password: string, now: number, reading?: ReadStage, command: Command = runCommand, signal?: AbortSignal): Promise<DesktopCredential> {
  try {
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
export function desktopQuota(raw: string, now: number) {
  const keys = ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_opus", "seven_day_oauth_apps", "seven_day_cowork"];
  const selected = object(selectJSON(raw, Object.fromEntries(keys.map(key => [key, { utilization: true, resets_at: true }]))));
  const windows = keys.flatMap(key => {
    if (selected[key] == null) return [];
    const value = object(selected[key]), percent = value.utilization, reset = date(value.resets_at);
    if (typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 100 || value.resets_at != null && reset === undefined) throw new Unavailable("noData");
    const label = key === "five_hour" ? "5-hour" : key === "seven_day" ? "Weekly · All models" : `Weekly · ${key.slice(10).replaceAll("_", " ")}`;
    return [window(label, percent, reset, key === "five_hour" ? 300 : 10080)];
  });
  if (!windows.length) throw new Unavailable("noData");
  return quota("claude", windows, now);
}
