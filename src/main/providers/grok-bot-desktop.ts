import { closeSync, constants, fstatSync, lstatSync, openSync, readSync } from "node:fs";
import { dirname, join } from "node:path";
import { createHash } from "node:crypto";
import { selectJSON } from "../select-json";
import { object } from "./parsers";
import { decryptDesktop } from "./claude-desktop";
import { type Command } from "./transport";
import { Unavailable, failed, quota, window } from "../../domain/models";

export const grokBotConnectionErrors = {
  store: "Could not connect Grok Bot Desktop: could not read a stable sign-in store.",
  keychain: "Could not connect Grok Bot Desktop: could not access its macOS Keychain item.",
  credentials: "Could not connect Grok Bot Desktop: could not validate the active account and access token.",
  decryption: "Could not connect Grok Bot Desktop: could not decrypt the sign-in cache with its Keychain item.",
  request: "Could not connect Grok Bot Desktop: the allowance request failed.",
  verification: "Could not connect Grok Bot Desktop: the account or sign-in store could not be verified after the request.",
  quota: "Could not connect Grok Bot Desktop: the provider did not report a supported allowance.",
  preferences: "Could not connect Grok Bot Desktop: could not save connection preferences.",
} as const;
export class GrokBotFailure extends Unavailable {
  constructor(readonly stage: keyof typeof grokBotConnectionErrors, code: Unavailable["code"] = "notSignedIn") {
    super(code, "Grok Bot Desktop");
  }
}
const unavailable = () => new Unavailable("notSignedIn", "Grok Bot Desktop");
const hash = (value: string) => createHash("sha256").update(value).digest("hex");
const scopePattern = /^[a-f0-9]{64}$/;
const selected = (raw: string, shape: Parameters<typeof selectJSON>[1], onScalar?: (raw: string) => void) => object(selectJSON(raw, shape, onScalar, true));
function envelope(raw: unknown, scope: string, password: string, allowLegacy = false) {
  if (typeof raw !== "string" || raw.length > 65536) throw unavailable();
  const match = /^scoped:v1:([a-f0-9]{64}):([A-Za-z0-9+/]+={0,2})$/.exec(raw);
  if (match ? match[1] !== scope : !allowLegacy) throw unavailable();
  // Bot also persists legacy encrypted values; the full JWT subject still binds the account.
  const encoded = match ? match[2] : raw;
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) throw unavailable();
  const bytes = Buffer.from(encoded, "base64");
  if (bytes.toString("base64") !== encoded || bytes.subarray(0, 3).toString() !== "v10") throw unavailable();
  let plaintext: Buffer;
  try { plaintext = decryptDesktop(bytes, password); }
  catch { throw new GrokBotFailure("decryption"); }
  try { return plaintext.toString("utf8"); } finally { plaintext.fill(0); }
}
// Only the active access-token/team values are decoded. Refresh tokens stay skipped.
export function grokBotCredential(raw: string, password: string, now: number, onScalar?: (raw: string) => void) {
  try {
    if (Buffer.byteLength(raw) > 4 * 1048576) throw unavailable();
    const root = selected(raw, { version: true, "cursor-accounts": true }, onScalar);
    if (root.version !== 1 || typeof root["cursor-accounts"] !== "string") throw unavailable();
    const accounts = root["cursor-accounts"], active = selected(accounts, { active: true }, onScalar).active;
    if (typeof active !== "string" || !scopePattern.test(active)) throw unavailable();
    const values = object(object(selected(accounts, { accounts: { [active]: { "cursor-access-token": true, "cursor-selected-team-id": true } } }, onScalar).accounts)[active]);
    const token = envelope(values["cursor-access-token"], active, password, true);
    if (token.length > 16384 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) throw unavailable();
    const payload = selected(Buffer.from(token.split(".")[1], "base64url").toString("utf8"), { sub: true, exp: true }, onScalar);
    if (typeof payload.sub !== "string" || payload.sub.length < 1 || payload.sub.length > 512 || /[\x00-\x20\x7f]/.test(payload.sub) || hash(payload.sub) !== active || typeof payload.exp !== "number" || !Number.isFinite(payload.exp * 1000) || payload.exp * 1000 <= now + 60000) throw unavailable();
    let team: string | undefined;
    if (values["cursor-selected-team-id"] !== undefined) {
      team = envelope(values["cursor-selected-team-id"], active, password);
      if (!/^(?:0|[1-9]\d*)$/.test(team) || !Number.isSafeInteger(Number(team))) throw unavailable();
    }
    return { token, team, identity: hash(`grok-bot-desktop\0${active}\0${team ?? "personal"}`), expiresAt: payload.exp * 1000 };
  } catch (error) { throw error instanceof GrokBotFailure ? error : new GrokBotFailure("credentials"); }
}
function snapshot(path: string) {
  const dirs: string[] = [];
  for (let dir = dirname(path); ; dir = dirname(dir)) { dirs.push(dir); if (dirname(dir) === dir) break; }
  return JSON.stringify([...dirs, path].map((file, index) => {
    const s = lstatSync(file, { bigint: true });
    if (index < dirs.length ? !s.isDirectory() : !s.isFile() || s.nlink !== 1n || s.size <= 0 || s.size > 4 * 1048576) throw unavailable();
    return (index < dirs.length ? [s.dev, s.ino, s.mode, s.uid, s.gid] : [s.dev, s.ino, s.mode, s.uid, s.gid, s.nlink, s.size, s.mtimeNs, s.ctimeNs]).map(String);
  }));
}
export async function readGrokBotCredential(home: string, helper: string, command: Command, now: number, allowUI: boolean, signal: AbortSignal, guard: () => void) {
  const check = () => { guard(); signal.throwIfAborted(); };
  let stage: keyof typeof grokBotConnectionErrors = "store";
  try {
    check();
    const path = join(home, "Library/Application Support/Grok Bot/sand-secrets.json"), before = snapshot(path);
    check(); const fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    let raw: string;
    try {
      const stat = fstatSync(fd, { bigint: true });
      const descriptor = () => { const s = fstatSync(fd, { bigint: true }); return [s.dev, s.ino, s.mode, s.uid, s.gid, s.nlink, s.size, s.mtimeNs, s.ctimeNs].map(String); };
      const expected = JSON.parse(before).at(-1);
      if (!stat.isFile() || stat.nlink !== 1n || stat.size > 4 * 1048576 || JSON.stringify(descriptor()) !== JSON.stringify(expected)) throw unavailable();
      check(); const bytes = Buffer.alloc(4 * 1048576 + 1);
      let length = 0, count: number;
      do { check(); count = readSync(fd, bytes, length, bytes.length - length, null); length += count; } while (count && length < bytes.length);
      if (length > 4 * 1048576) throw unavailable();
      raw = bytes.subarray(0, length).toString("utf8"); bytes.fill(0);
      check(); if (JSON.stringify(descriptor()) !== JSON.stringify(expected)) throw unavailable();
    } finally { closeSync(fd); }
    check(); if (snapshot(path) !== before) throw unavailable();
    check();
    stage = "keychain";
    const password = await command(helper, allowUI ? ["--grok-bot", "--allow-ui"] : ["--grok-bot"], { signal, timeoutMs: allowUI ? 60000 : 5000, maxBytes: 4096 });
    check(); stage = "credentials"; const credential = grokBotCredential(raw, password, now);
    stage = "store"; check(); if (snapshot(path) !== before) throw unavailable();
    return { ...credential, store: hash(before + "\0" + raw) };
  } catch (error) { throw error instanceof GrokBotFailure ? error : new GrokBotFailure(stage); }
}
export function grokBotQuota(raw: string, now: number) {
  try {
    const v = selected(raw, { usagePercent: true, nextResetTimestampUtc: true, includedLimitZero: true, hasNonZeroIncludedLimit: true, usesPooledEnterpriseAllowance: true, sandTrialExpiresAt: true });
    for (const key of ["includedLimitZero", "hasNonZeroIncludedLimit", "usesPooledEnterpriseAllowance"]) if (v[key] !== undefined && typeof v[key] !== "boolean") throw new Error();
    if (v.usesPooledEnterpriseAllowance === true || v.includedLimitZero === true && v.hasNonZeroIncludedLimit === true || v.includedLimitZero === false && v.hasNonZeroIncludedLimit === false) throw new Error();
    const paid = v.includedLimitZero === false || v.hasNonZeroIncludedLimit === true;
    const timestamp = (value: unknown) => {
      if (typeof value !== "string" || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?Z$/.test(value)) return NaN;
      const n = Date.parse(value);
      return Number.isFinite(n) && new Date(n).toISOString().slice(0, 19) === value.slice(0, 19) ? n : NaN;
    };
    const trial = !paid && timestamp(v.sandTrialExpiresAt) > now;
    const reset = paid && v.nextResetTimestampUtc !== undefined ? timestamp(v.nextResetTimestampUtc) : undefined;
    if ((!paid && !trial) || typeof v.usagePercent !== "number" || !Number.isFinite(v.usagePercent) || v.usagePercent < 0 || v.usagePercent > 100 || reset !== undefined && (!Number.isFinite(reset) || reset <= now)) throw new Error();
    return quota("grok", [window(trial ? "Grok Bot Desktop · Trial" : "Grok Bot Desktop", v.usagePercent, reset)], now);
  } catch { throw new GrokBotFailure("quota", "noData"); }
}
export type GrokBotRPC = (token: string, team: string | undefined, signal: AbortSignal) => Promise<string>;
export function grokBotTransport(fetcher: typeof fetch = fetch): GrokBotRPC {
  return async (token, team, signal) => {
    const bounded = AbortSignal.any([signal, AbortSignal.timeout(30000)]);
    try {
      bounded.throwIfAborted();
      if (!/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token) || token.length > 16384 || team !== undefined && (!/^(?:0|[1-9]\d*)$/.test(team) || !Number.isSafeInteger(Number(team)))) throw unavailable();
      const response = await fetcher("https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus", { method: "POST", body: "{}", redirect: "error", cache: "no-store", signal: bounded, headers: { "Content-Type": "application/json", "Connect-Protocol-Version": "1", "User-Agent": "MeterUsage/0.2.41", Authorization: `Bearer ${token}`, ...(team === undefined ? {} : { "x-cursor-team-id": team }) } });
      if (response.status !== 200 || response.redirected) { await response.body?.cancel(); if ([401, 403].includes(response.status)) throw unavailable(); throw failed("grok"); }
      if (Number(response.headers.get("content-length")) > 1048576) { await response.body?.cancel(); throw failed("grok"); }
      const reader = response.body?.getReader(); if (!reader) throw failed("grok");
      const chunks: Buffer[] = []; let bytes = 0;
      try {
        while (true) { bounded.throwIfAborted(); const { done, value } = await reader.read(); if (done) break; bytes += value.length; if (bytes > 1048576) throw failed("grok"); chunks.push(Buffer.from(value)); }
        bounded.throwIfAborted(); return Buffer.concat(chunks).toString("utf8");
      } finally { await reader.cancel(); }
    } catch (error) { throw error instanceof Unavailable ? error : failed("grok"); }
  };
}
