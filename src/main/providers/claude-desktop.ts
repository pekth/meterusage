import { readFileSync, statSync, existsSync } from "node:fs";
import { join } from "node:path";
import { createDecipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { selectJSON } from "../select-json";
import { date, object, text } from "./parsers";
import { Unavailable, quota, window } from "../../domain/models";

const uuid = /^[a-f\d]{8}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{4}-[a-f\d]{12}$/i;
const unavailable = () => new Unavailable("notSignedIn", "Claude Desktop");
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
export function desktopCredential(config: string, organization: string, password: string, now: number) {
  try {
    const root = object(selectJSON(config, { lastKnownAccountUuid: true, "oauth:tokenCacheV2": true }));
    const account = text(root.lastKnownAccountUuid)?.toLowerCase();
    if (!account || !uuid.test(account) || !uuid.test(organization)) throw unavailable();
    const cache = text(root["oauth:tokenCacheV2"]); if (!cache || cache.length > 1400000) throw unavailable();
    const plaintext = decryptDesktop(Buffer.from(cache, "base64"), password);
    try {
      // Select only scoped access tokens and expiry. Refresh tokens stay skipped.
      const entries = object(selectJSON(plaintext.toString("utf8"), { "*": { token: true, expiresAt: true } }));
      const candidates = Object.entries(entries).filter(([key, value]) => {
        const match = /^acct:([^|]+)\|([^:]+):([^:]+):https:\/\/api\.anthropic\.com:(.*)$/.exec(key);
        const entry = object(value), scopes = match?.[4].split(/\s+/);
        return match && match[1].toLowerCase() === account && uuid.test(match[2]) && match[3].toLowerCase() === organization.toLowerCase() && scopes?.includes("user:profile") && scopes.includes("user:inference") && typeof entry.expiresAt === "number" && Number.isFinite(entry.expiresAt) && entry.expiresAt > now + 120000 && !!text(entry.token);
      });
      // Fail closed for ambiguous caches instead of guessing which login to use.
      if (candidates.length !== 1) throw unavailable();
      return { token: text(object(candidates[0][1]).token)!, identity: createHash("sha256").update(account + ":" + organization.toLowerCase()).digest("hex") };
    } finally { plaintext.fill(0); }
  } catch { throw unavailable(); }
}
function configFile(home: string) {
  const path = join(home, "Library/Application Support/Claude/config.json");
  if (statSync(path).size > 2 * 1048576) throw unavailable();
  return readFileSync(path, "utf8");
}
export async function readDesktopCredential(home: string, password: string, now: number) {
  try {
    const config = configFile(home);
    const { DatabaseSync } = await import("node:sqlite");
    for (const relative of ["Cookies", "Network/Cookies"]) {
      const path = join(home, "Library/Application Support/Claude", relative); if (!existsSync(path)) continue;
      const db = new DatabaseSync(path, { readOnly: true });
      try {
        const rows = db.prepare("SELECT host_key, value, encrypted_value FROM cookies WHERE name = 'lastActiveOrg' AND host_key IN ('.claude.ai', 'claude.ai') ORDER BY last_update_utc DESC LIMIT 1").all();
        for (const row of rows) {
          let organization = typeof row.value === "string" ? row.value : "";
          if (!organization && row.encrypted_value instanceof Uint8Array && typeof row.host_key === "string") {
            const decrypted = decryptDesktop(row.encrypted_value, password), hash = createHash("sha256").update(row.host_key).digest();
            try { if (decrypted.subarray(0, 32).equals(hash)) organization = decrypted.subarray(32).toString("utf8"); }
            finally { decrypted.fill(0); }
          }
          return desktopCredential(config, organization, password, now);
        }
      } finally { db.close(); }
    }
    throw unavailable();
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
