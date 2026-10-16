import { lstatSync } from "node:fs";
import { join, dirname } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash } from "node:crypto";
import { selectJSON } from "../select-json";
import { date, object } from "./parsers";
import { runCommand, type Command } from "./transport";
import { Unavailable, quota, window } from "../../domain/models";

const unavailable = () => new Unavailable("notSignedIn", "Grok Bot via Cursor");
const subject = (value: unknown) => {
  if (typeof value !== "string" || value.length > 512) throw unavailable();
  const id = value.split("|").at(-1);
  if (!id || !/^[A-Za-z0-9._-]+$/.test(id)) throw unavailable();
  return id;
};
const identity = (id: string) => createHash("sha256").update(`cursor-grok:${id}`).digest("hex");
export function cursorCredential(token: string, now: number) {
  try {
    if (token.length > 16384 || !/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(token)) throw unavailable();
    const payload = object(selectJSON(Buffer.from(token.split(".")[1], "base64url").toString("utf8"), { sub: true, exp: true }));
    const id = subject(payload.sub);
    if (typeof payload.exp !== "number" || !Number.isFinite(payload.exp) || payload.exp * 1000 <= now + 60000) throw unavailable();
    return { cookie: `WorkosCursorSessionToken=${id}%3A%3A${token}`, identity: identity(id), expiresAt: payload.exp * 1000 };
  } catch { throw unavailable(); }
}
export function cursorIdentity(raw: string, credential: ReturnType<typeof cursorCredential>) {
  try {
    if (identity(subject(object(selectJSON(raw, { sub: true })).sub)) !== credential.identity) throw unavailable();
  } catch { throw unavailable(); }
}
async function closedCursor(command: Command, signal?: AbortSignal) {
  // comm excludes process arguments, which can contain private data.
  const raw = await command("/bin/ps", ["-axo", "pid=,comm="], { signal, timeoutMs: 5000, maxBytes: 2 * 1048576 });
  const lines = raw.trim().split("\n");
  if (!raw.trim() || lines.some(line => !/^\s*\d+\s+\S.*$/.test(line))) throw unavailable();
  if (lines.some(line => /cursor/i.test(line.replace(/^\s*\d+\s+/, "")))) throw unavailable();
}
function storeSnapshot(path: string) {
  const directories: string[] = [];
  for (let dir = dirname(path); ; dir = dirname(dir)) { directories.push(dir); if (dirname(dir) === dir) break; }
  return JSON.stringify([...directories, path, path + "-wal", path + "-shm", path + "-journal"].map((file, index) => {
    let stat;
    try { stat = lstatSync(file, { bigint: true }); }
    catch (error) { if (index > directories.length && (error as NodeJS.ErrnoException).code === "ENOENT") return null; throw error; }
    if (index < directories.length ? !stat.isDirectory() : !stat.isFile() || stat.nlink !== 1n) throw unavailable();
    if (file === path && (stat.size < 100n || stat.size > 268435456n) || (file === path + "-wal" || file === path + "-journal") && stat.size !== 0n) throw unavailable();
    // Access times may change on reads. Identity, content-change and sidecar metadata must stay fixed.
    return (index > 0 && index < directories.length ? [stat.dev, stat.ino, stat.mode, stat.uid, stat.gid] : [stat.dev, stat.ino, stat.mode, stat.uid, stat.gid, stat.nlink, stat.size, stat.mtimeNs, stat.ctimeNs]).map(String);
  }));
}
export async function readCursorCredential(home: string, now: number, command: Command = runCommand, signal?: AbortSignal) {
  try {
    signal?.throwIfAborted();
    await closedCursor(command, signal);
    const path = join(home, "Library/Application Support/Cursor/User/globalStorage/state.vscdb"), before = storeSnapshot(path);
    const { DatabaseSync } = await import("node:sqlite");
    signal?.throwIfAborted();
    const uri = pathToFileURL(path); uri.searchParams.set("immutable", "1"); uri.searchParams.set("mode", "ro");
    // immutable disables SQLite writes, locks and sidecar bookkeeping even if another process races us.
    const db = new DatabaseSync(uri.href, { readOnly: true, allowExtension: false });
    let token: string;
    try {
      const rows = db.prepare("SELECT CASE WHEN length(value) <= 32768 THEN value END AS value FROM ItemTable WHERE key = 'cursorAuth/accessToken' LIMIT 2").all();
      if (rows.length !== 1) throw unavailable();
      const value = rows[0].value;
      if (typeof value === "string") token = value;
      else if (value instanceof Uint8Array && value.length <= 32768) {
        const bytes = Buffer.from(value);
        const utf16 = bytes.length % 2 === 0 && bytes.every((b, i) => i % 2 ? b === 0 : b > 0 && b < 128);
        token = bytes.toString(utf16 ? "utf16le" : "utf8");
      } else throw unavailable();
    } finally { db.close(); }
    if (storeSnapshot(path) !== before) throw unavailable();
    await closedCursor(command, signal);
    if (storeSnapshot(path) !== before) throw unavailable();
    signal?.throwIfAborted();
    return { ...cursorCredential(token, now), store: createHash("sha256").update(before).digest("hex") };
  } catch { throw unavailable(); }
}
export function cursorGrokQuota(raw: string, now: number) {
  try {
    const value = object(selectJSON(raw, { usagePercent: true, nextResetTimestampUtc: true, includedLimitZero: true, hasNonZeroIncludedLimit: true, sandTrialExpiresAt: true }));
    for (const key of ["includedLimitZero", "hasNonZeroIncludedLimit"]) if (value[key] != null && typeof value[key] !== "boolean") throw new Unavailable("noData");
    const paid = typeof value.includedLimitZero === "boolean" ? !value.includedLimitZero : value.hasNonZeroIncludedLimit === true;
    const trial = !paid && typeof value.sandTrialExpiresAt === "string" && (date(value.sandTrialExpiresAt) ?? 0) > now;
    const percent = value.usagePercent, reset = paid && typeof value.nextResetTimestampUtc === "string" ? date(value.nextResetTimestampUtc) : undefined;
    if ((!paid && !trial) || typeof percent !== "number" || !Number.isFinite(percent) || percent < 0 || percent > 100 || paid && value.nextResetTimestampUtc != null && reset === undefined) throw new Unavailable("noData");
    return quota("grok", [window(trial ? "Grok Bot via Cursor · Trial" : "Grok Bot via Cursor", percent, reset)], now);
  } catch { throw new Unavailable("noData"); }
}
