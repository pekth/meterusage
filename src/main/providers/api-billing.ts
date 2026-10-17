import { closeSync, constants, fstatSync, lstatSync, mkdirSync, openSync, readSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { type ApiBillingProvider, type ApiBillingReading, type ApiBillingSnapshot } from "../../domain/api-billing";
import { selectJSON, type Selection } from "../select-json";

const day = 86400000, maxBytes = 1048576;
const invalid = () => new Error("API billing data unavailable");
const record = (value: unknown): Record<string, unknown> => { if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid(); return value as Record<string, unknown>; };
const timestamp = (value: unknown): number => { if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0 || value > 8640000000000000) throw invalid(); return value; };
const monthStart = (value: number) => { const at = new Date(value); return Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), 1); };
const amount = (value: unknown): number => { if (typeof value !== "number" || !Number.isFinite(value) || value < 0 || value > Number.MAX_SAFE_INTEGER) throw invalid(); return value; };
const directory = (home: string) => join(home, "Library/Application Support/MeterUsage/api-usage");
export const apiBillingPath = (home: string, provider: ApiBillingProvider) => join(directory(home), `${provider}.json`);

function privateDirectory(home: string) {
  let path = home;
  for (const part of ["", "Library", "Application Support", "MeterUsage", "api-usage"]) {
    path = join(path, part);
    const stat = lstatSync(path);
    if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || (stat.mode & 0o022) || part === "api-usage" && (stat.mode & 0o077)) throw invalid();
  }
}

export function parseApiBillingSnapshot(raw: string, provider: ApiBillingProvider, now = Date.now()): ApiBillingSnapshot {
  if (Buffer.byteLength(raw) > maxBytes) throw invalid();
  const root = record(selectJSON(raw, { schema: true, provider: true, capturedAt: true, monthStart: true, periodEnd: true, currency: true, daily: { "*": { start: true, end: true, amountUSD: true } } }, undefined, true));
  const scalarRows = record(selectJSON(raw, { daily: { "*": true } }));
  if (Array.isArray(scalarRows.daily) && scalarRows.daily.length) throw invalid();
  const capturedAt = timestamp(root.capturedAt), start = timestamp(root.monthStart), periodEnd = timestamp(root.periodEnd);
  if (root.schema !== 1 || root.provider !== provider || root.currency !== "USD" || capturedAt > now + 60000 || start !== monthStart(capturedAt) || periodEnd < start || periodEnd !== Math.floor(capturedAt / 1000) * 1000 || !Array.isArray(root.daily) || root.daily.length > 31) throw invalid();
  const daily = root.daily.map(value => {
    const row = record(value), from = timestamp(row.start), to = timestamp(row.end);
    if (from < start || from >= periodEnd || from % day !== 0 || to <= from || to > from + day) throw invalid();
    return { start: from, end: to, amountUSD: amount(row.amountUSD) };
  }).sort((a, b) => a.start - b.start);
  if (daily.some((row, i) => i > 0 && row.start < daily[i - 1].end)) throw invalid();
  amount(daily.reduce((sum, row) => sum + row.amountUSD, 0));
  return { schema: 1, provider, capturedAt, monthStart: start, periodEnd, currency: "USD", daily };
}

export function readApiBilling(home: string, provider: ApiBillingProvider, now = Date.now()): ApiBillingReading {
  let fd: number | undefined;
  try {
    privateDirectory(home);
    fd = openSync(apiBillingPath(home, provider), constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const stat = fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid?.() || stat.mode & 0o077 || stat.nlink !== 1 || stat.size > maxBytes) throw invalid();
    const buffer = Buffer.alloc(maxBytes + 1); let size = 0;
    while (size < buffer.length) { const count = readSync(fd, buffer, size, buffer.length - size, null); if (!count) break; size += count; }
    const after = fstatSync(fd);
    if (size !== stat.size || after.size !== stat.size || after.mtimeMs !== stat.mtimeMs || after.ctimeMs !== stat.ctimeMs || after.ino !== stat.ino || after.dev !== stat.dev) throw invalid();
    const value = parseApiBillingSnapshot(buffer.subarray(0, size).toString("utf8"), provider, now);
    return { status: "value", value, stale: now - value.capturedAt >= day || monthStart(now) !== value.monthStart };
  } catch (error) {
    return { status: "missing", code: (error as NodeJS.ErrnoException).code === "ENOENT" ? "notConfigured" : "unavailable" };
  } finally { if (fd !== undefined) closeSync(fd); }
}

export function writeApiBilling(home: string, snapshot: ApiBillingSnapshot) {
  const value = parseApiBillingSnapshot(JSON.stringify(snapshot), snapshot.provider, snapshot.capturedAt);
  // Validate existing ancestors before recursive mkdir can follow a symlink.
  let path = home;
  for (const part of ["", "Library", "Application Support", "MeterUsage", "api-usage"]) {
    path = join(path, part);
    try { const stat = lstatSync(path); if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || stat.mode & 0o022) throw invalid(); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; mkdirSync(path, { mode: 0o700 }); }
  }
  privateDirectory(home);
  const target = apiBillingPath(home, value.provider), temp = join(directory(home), `.${randomUUID()}.tmp`);
  try {
    try { const stat = lstatSync(target); if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid?.() || stat.mode & 0o077 || stat.nlink !== 1) throw invalid(); }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error; }
    writeFileSync(temp, JSON.stringify(value) + "\n", { mode: 0o600, flag: "wx" });
    renameSync(temp, target);
  } finally { rmSync(temp, { force: true }); }
}

const selection = {
  has_more: true, next_page: true, data: { "*": { start_time: true, end_time: true, starting_at: true, ending_at: true,
    results: { "*": { amount: { value: true, currency: true }, currency: true } } } },
} as const;

export async function collectApiBilling(provider: ApiBillingProvider, key: string, now = Date.now(), fetcher: typeof fetch = fetch): Promise<ApiBillingSnapshot> {
  if (!(provider === "openai" || provider === "anthropic") || !key || key.length > 8192 || /\s/.test(key)) throw invalid();
  const capturedAt = timestamp(now), start = monthStart(now), end = Math.floor(now / 1000) * 1000, daily: ApiBillingSnapshot["daily"] = [], pages = new Set<string>();
  const signal = AbortSignal.timeout(30000);
  let cursor: string | undefined;
  try {
    for (let page = 0; page < 32; page++) {
      const url = new URL(provider === "openai" ? "https://api.openai.com/v1/organization/costs" : "https://api.anthropic.com/v1/organizations/cost_report");
      url.searchParams.set(provider === "openai" ? "start_time" : "starting_at", provider === "openai" ? String(start / 1000) : new Date(start).toISOString());
      url.searchParams.set(provider === "openai" ? "end_time" : "ending_at", provider === "openai" ? String(end / 1000) : new Date(end).toISOString());
      url.searchParams.set("bucket_width", "1d"); url.searchParams.set("limit", "31");
      if (cursor) url.searchParams.set("page", cursor);
      const response = await fetcher(url, { method: "GET", redirect: "error", cache: "no-store", credentials: "omit", signal,
        headers: { Accept: "application/json", "User-Agent": "MeterUsage API snapshot helper/1", ...(provider === "openai" ? { Authorization: `Bearer ${key}` } : { "x-api-key": key, "anthropic-version": "2023-06-01" }) } });
      signal.throwIfAborted();
      const length = response.headers.get("content-length");
      if (response.redirected || !response.ok || !response.body || length !== null && (!/^\d+$/.test(length) || Number(length) > maxBytes)) {
        await response.body?.cancel();
        if (!response.redirected && (response.status === 401 || response.status === 403)) throw new Error("API billing authentication failed");
        throw invalid();
      }
      const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
      try { while (true) { const part = await reader.read(); signal.throwIfAborted(); if (part.done) break; size += part.value.byteLength; if (size > maxBytes) throw invalid(); chunks.push(part.value); } }
      finally { await reader.cancel(); }
      const raw = Buffer.concat(chunks).toString("utf8");
      // Anthropic's amount is a decimal scalar in cents; OpenAI uses a dollar object.
      const fields: Selection = provider === "openai" ? selection : { ...selection, data: { "*": { ...selection.data["*"], results: { "*": { amount: true, currency: true } } } } };
      const root = record(selectJSON(raw, fields, undefined, true));
      if (!Array.isArray(root.data) || typeof root.has_more !== "boolean") throw invalid();
      const scalarBuckets = record(selectJSON(raw, { data: { "*": true } }));
      const scalarResults = record(selectJSON(raw, { data: { "*": { results: { "*": true } } } }));
      if ((scalarBuckets.data as unknown[]).length || (scalarResults.data as unknown[]).some(row => { const results = record(row).results; return Array.isArray(results) && results.length > 0; })) throw invalid();
      for (const value of root.data) {
        const bucket = record(value), from = provider === "openai" ? timestamp(bucket.start_time) * 1000 : Date.parse(String(bucket.starting_at)), to = provider === "openai" ? timestamp(bucket.end_time) * 1000 : Date.parse(String(bucket.ending_at));
        if (!Array.isArray(bucket.results)) throw invalid();
        if (!bucket.results.length) continue;
        let amountUSD = 0;
        for (const result of bucket.results) {
          const row = record(result);
          if (provider === "openai") { const value = record(row.amount); if (value.currency !== "usd") throw invalid(); amountUSD += amount(value.value); }
          else { if (row.currency !== "USD" || typeof row.amount !== "string" || !/^\d+(?:\.\d+)?$/.test(row.amount)) throw invalid(); amountUSD += amount(Number(row.amount)) / 100; }
        }
        daily.push({ start: from, end: to, amountUSD });
      }
      if (!root.has_more) return parseApiBillingSnapshot(JSON.stringify({ schema: 1, provider, capturedAt, monthStart: start, periodEnd: end, currency: "USD", daily }), provider, now);
      if (typeof root.next_page !== "string" || !root.next_page || root.next_page.length > 4096 || pages.has(root.next_page)) throw invalid();
      cursor = root.next_page; pages.add(cursor);
    }
    throw invalid();
  } catch (error) { throw new Error(error instanceof Error && error.message === "API billing authentication failed" ? error.message : "API billing data unavailable"); }
}
