import { createReadStream, readFileSync, statSync, existsSync } from "node:fs";
import { readdir, open } from "node:fs/promises";
import { createInterface } from "node:readline";
import { basename, join } from "node:path";
import { type Activity, type Session, type Daily, type Tokens, type Provider, tokens, totalTokens, addTokens, utcDay, Unavailable } from "../../domain/models";
import { telemetry } from "../../domain/telemetry";
import { estimate } from "../../domain/pricing";
import { atomicJSON } from "../history";
import { selectJSON } from "../select-json";
import { object, number, date, displayText, text } from "./parsers";

export function opaqueID(raw: string): string {
  let hash = 0xcbf29ce484222325n;
  for (const b of Buffer.from(raw, "utf8")) hash = BigInt.asUintN(64, (hash ^ BigInt(b)) * 0x100000001b3n);
  return hash.toString(16).padStart(16, "0");
}
export const projectName = (raw: string, encoded = false) => displayText(encoded ? raw.split("-").filter(Boolean).at(-1) : basename(raw)) ?? "unknown";
export async function filesIn(root: string, suffix: string, recursive = true, signal?: AbortSignal): Promise<string[]> {
  signal?.throwIfAborted();
  let entries; try { entries = await readdir(root, { withFileTypes: true }); } catch { signal?.throwIfAborted(); return []; }
  signal?.throwIfAborted();
  const out: string[] = [];
  for (const e of entries) {
    if (e.name.startsWith(".")) continue;
    signal?.throwIfAborted();
    if (e.isDirectory() && recursive) out.push(...await filesIn(join(root, e.name), suffix, true, signal));
    else if (e.isFile() && e.name.endsWith(suffix)) out.push(join(root, e.name));
  }
  return out;
}
const usageShape = { input_tokens: true, output_tokens: true, cache_read_input_tokens: true, cache_creation_input_tokens: true } as const;
export const claudeLineSelection = { type: true, timestamp: true, message: { model: true, usage: usageShape } } as const;
interface ClaudeParsed { tokens: Tokens; totalCostUSD: number; messageCount: number; model?: string; earliestTimestamp?: number; dailyBuckets: { dayEpoch: number; bucket: { tokens: Tokens; costUSD: number } }[] }
export function parseClaudeLine(line: string): { tokens: Tokens; model: string; at?: number } | undefined {
  if (!line.includes('"usage"') || !line.includes('"assistant"')) return;
  try {
    const r = object(selectJSON(line, claudeLineSelection)), m = object(r.message), u = object(m.usage);
    if (r.type !== "assistant" || !m.usage) return;
    return { tokens: tokens({ input: number(u.input_tokens) ?? 0, output: number(u.output_tokens) ?? 0, cacheRead: number(u.cache_read_input_tokens) ?? 0, cacheWrite: number(u.cache_creation_input_tokens) ?? 0 }), model: displayText(m.model) ?? "unknown", at: date(r.timestamp) };
  } catch { return; }
}
async function parseClaudeFile(path: string, signal?: AbortSignal): Promise<ClaudeParsed> {
  const result: ClaudeParsed = { tokens: tokens(), totalCostUSD: 0, messageCount: 0, dailyBuckets: [] }, buckets = new Map<number, { tokens: Tokens; costUSD: number }>();
  const stream = createReadStream(path, { signal }), lines = createInterface({ input: stream, crlfDelay: Infinity });
  try {
    for await (const line of lines) {
      const parsed = parseClaudeLine(line); if (!parsed) continue;
      const cost = estimate(parsed.model, parsed.tokens).costUSD;
      result.tokens = addTokens(result.tokens, parsed.tokens); result.totalCostUSD += cost; result.messageCount++; result.model = parsed.model;
      if (parsed.at !== undefined) {
        result.earliestTimestamp = Math.min(result.earliestTimestamp ?? Infinity, parsed.at / 1000);
        const day = utcDay(parsed.at) / 1000, b = buckets.get(day) ?? { tokens: tokens(), costUSD: 0 };
        buckets.set(day, { tokens: addTokens(b.tokens, parsed.tokens), costUSD: b.costUSD + cost });
      }
    }
  } finally { lines.close(); stream.destroy(); }
  result.dailyBuckets = [...buckets].map(([dayEpoch, bucket]) => ({ dayEpoch, bucket })); return result;
}
function cacheParsed(v: unknown): ClaudeParsed | undefined {
  const r = object(v), t = object(r.tokens);
  if (![t.input, t.output, t.cacheRead, t.cacheWrite, r.totalCostUSD, r.messageCount].every(n => typeof n === "number" && Number.isFinite(n)) || !Array.isArray(r.dailyBuckets)) return;
  if (r.earliestTimestamp != null && (typeof r.earliestTimestamp !== "number" || !Number.isFinite(new Date(r.earliestTimestamp * 1000).getTime()))) return;
  const buckets: ClaudeParsed["dailyBuckets"] = [];
  for (const raw of r.dailyBuckets) {
    const e = object(raw), b = object(e.bucket), tok = object(b.tokens);
    if (typeof e.dayEpoch !== "number" || !Number.isFinite(new Date(e.dayEpoch * 1000).getTime()) || typeof b.costUSD !== "number" || !Number.isFinite(b.costUSD) || ![tok.input, tok.output, tok.cacheRead, tok.cacheWrite].every(n => typeof n === "number" && Number.isFinite(n))) return;
    buckets.push({ dayEpoch: e.dayEpoch, bucket: { tokens: tokens({ input: tok.input as number, output: tok.output as number, reasoning: number(tok.reasoning) ?? 0, cacheRead: tok.cacheRead as number, cacheWrite: tok.cacheWrite as number }), costUSD: b.costUSD } });
  }
  return { tokens: tokens({ input: t.input as number, output: t.output as number, reasoning: number(t.reasoning) ?? 0, cacheRead: t.cacheRead as number, cacheWrite: t.cacheWrite as number }), totalCostUSD: r.totalCostUSD as number, messageCount: r.messageCount as number, model: displayText(r.model), earliestTimestamp: number(r.earliestTimestamp), dailyBuckets: buckets };
}
export class ClaudeActivitySource {
  private cache: Record<string, { mtime: number; size: number; result: ClaudeParsed }> = Object.create(null);
  private loaded = false;
  constructor(readonly root: string, readonly cacheFile?: string) {}
  async scan(now = Date.now(), signal?: AbortSignal): Promise<Activity> {
    signal?.throwIfAborted();
    if (!existsSync(this.root)) throw new Unavailable("noData");
    if (!this.loaded && this.cacheFile) {
      try { for (const [key, v] of Object.entries(object(JSON.parse(readFileSync(this.cacheFile, "utf8"))))) { const e = object(v), result = cacheParsed(e.result); if (result && number(e.mtime) !== undefined && number(e.size) !== undefined && /^[a-f0-9]{16}$/.test(key)) this.cache[key] = { mtime: number(e.mtime)!, size: number(e.size)!, result }; } } catch { /* Scan cache is disposable; durable history is not. */ }
    }
    this.loaded = true;
    const sessions: Session[] = [], daily = new Map<number, Daily>(); let dirty = false;
    for (const path of await filesIn(this.root, ".jsonl", true, signal)) {
      const relative = path.slice(this.root.length + 1).split("/"); if (relative.length !== 2) continue;
      try {
        const stat = statSync(path), key = opaqueID(path), previous = this.cache[key];
        signal?.throwIfAborted();
        const parsed = previous?.mtime === stat.mtimeMs / 1000 && previous.size === stat.size ? previous.result : await parseClaudeFile(path, signal);
        if (previous?.result !== parsed) { this.cache[key] = { mtime: stat.mtimeMs / 1000, size: stat.size, result: parsed }; dirty = true; }
        if (!parsed.messageCount) continue;
        sessions.push({ id: opaqueID(basename(path, ".jsonl")), projectName: projectName(relative[0], true), model: parsed.model ?? "unknown", tokens: parsed.tokens, estimatedCostUSD: parsed.totalCostUSD, startedAt: parsed.earliestTimestamp === undefined ? Date.parse("0001-01-01T00:00:00Z") : parsed.earliestTimestamp * 1000, lastActivityAt: stat.mtimeMs, messageCount: parsed.messageCount });
        for (const { dayEpoch, bucket } of parsed.dailyBuckets) {
          const d = dayEpoch * 1000, prior = daily.get(d) ?? { day: d, tokens: tokens(), estimatedCostUSD: 0, sessionCount: 0 };
          daily.set(d, { day: d, tokens: addTokens(prior.tokens, bucket.tokens), estimatedCostUSD: prior.estimatedCostUSD + bucket.costUSD, sessionCount: prior.sessionCount + 1 });
        }
      } catch { signal?.throwIfAborted(); /* A failed session read does not discard its readable siblings. */ }
    }
    signal?.throwIfAborted();
    if (dirty && this.cacheFile) { try { atomicJSON(this.cacheFile, this.cache); } catch { /* A cache write failure does not hide live usage. */ } }
    if (!sessions.length) throw new Unavailable("noData");
    return makeActivity("claude", sessions, [...daily.values()], now);
  }
}
export const codexStartSelection = { timestamp: true, payload: { cwd: true, thread_source: true } } as const;
export const codexLedgerSelection = { type: true, payload: { type: true, info: { total_token_usage: { input_tokens: true, cached_input_tokens: true, output_tokens: true, reasoning_output_tokens: true } } } } as const;
export function parseCodexTokenLine(line: string): Tokens | undefined {
  if (!line.includes('"total_token_usage"')) return;
  try {
    const r = object(selectJSON(line, codexLedgerSelection)), p = object(r.payload), u = object(object(p.info).total_token_usage);
    if (r.type !== "event_msg" || p.type !== "token_count") return;
    const input = number(u.input_tokens) ?? 0, output = number(u.output_tokens) ?? 0, cache = number(u.cached_input_tokens) ?? 0, reasoning = number(u.reasoning_output_tokens) ?? 0;
    if (input <= 0 && output <= 0) return;
    return tokens({ input: Math.max(0, input - cache), output: Math.max(0, output - reasoning), reasoning, cacheRead: cache });
  } catch { return; }
}
export function parseCodexModel(line: string): string | undefined {
  if (!line.includes("turn_context")) return;
  try { const r = object(selectJSON(line, { type: true, payload: { model: true } })); return r.type === "turn_context" ? displayText(object(r.payload).model) : undefined; } catch { return; }
}
async function codexLedger(path: string, signal?: AbortSignal) {
  const file = await open(path, "r"); let ledger: Tokens | undefined, model: string | undefined;
  try {
    let remaining = (await file.stat()).size, spent = 0, modelSpent = 0, pending = Buffer.alloc(0);
    while (remaining > 0 && spent < 16 * 1048576) {
      signal?.throwIfAborted();
      const length = Math.min(1048576, remaining), offset = remaining - length, chunk = Buffer.alloc(length);
      await file.read(chunk, 0, length, offset); remaining = offset; spent += length;
      const buffer = Buffer.concat([chunk, pending]), newline = buffer.indexOf(10);
      if (newline < 0) { pending = buffer; continue; }
      pending = buffer.subarray(0, newline);
      const lines = buffer.subarray(newline + 1).toString("utf8").split("\n").reverse();
      for (const line of lines) {
        if (!ledger) { ledger = parseCodexTokenLine(line); continue; }
        model = parseCodexModel(line); if (model) return { tokens: ledger, model };
      }
      if (ledger) { modelSpent += length; if (modelSpent >= 4 * 1048576) break; }
    }
    return { tokens: ledger ?? tokens(), model: model ?? "codex" };
  } finally { await file.close(); }
}
export async function scanCodex(root: string, now = Date.now(), signal?: AbortSignal): Promise<Activity> {
  const paths = await filesIn(root, ".jsonl", true, signal); if (!paths.length) throw new Unavailable("noData");
  const sessions: Session[] = [], daily = new Map<number, Daily>();
  for (const path of paths) {
    signal?.throwIfAborted();
    let modified: number | undefined, first: Record<string, unknown> = Object.create(null);
    try { modified = statSync(path).mtimeMs; } catch { signal?.throwIfAborted(); }
    try {
      const file = await open(path, "r");
      try { const b = Buffer.alloc(65536); const { bytesRead } = await file.read(b, 0, b.length, 0); const lineEnd = b.subarray(0, bytesRead).indexOf(10); if (lineEnd >= 0) first = object(selectJSON(b.subarray(0, lineEnd).toString("utf8"), codexStartSelection)); } finally { await file.close(); }
    } catch { signal?.throwIfAborted(); /* mtime is the legacy fallback. */ }
    const start = date(first.timestamp) ?? modified; if (start === undefined) continue;
    let ledger = { tokens: tokens(), model: "codex" };
    try { ledger = await codexLedger(path, signal); } catch { signal?.throwIfAborted(); /* Swift retains dated sessions without a readable token ledger. */ }
    const payload = object(first.payload), cost = estimate(ledger.model, ledger.tokens).costUSD;
    sessions.push({ id: opaqueID(path), projectName: text(payload.cwd) ? projectName(text(payload.cwd)!) : "", model: ledger.model, tokens: ledger.tokens, estimatedCostUSD: cost, startedAt: start, lastActivityAt: modified, messageCount: 0, isAutomation: payload.thread_source === "automation" });
    const day = utcDay(start), prior = daily.get(day) ?? { day, tokens: tokens(), estimatedCostUSD: 0, sessionCount: 0 };
    daily.set(day, { day, tokens: addTokens(prior.tokens, ledger.tokens), estimatedCostUSD: prior.estimatedCostUSD + cost, sessionCount: prior.sessionCount + 1 });
  }
  signal?.throwIfAborted();
  if (!sessions.length) throw new Unavailable("noData");
  return makeActivity("codex", sessions, [...daily.values()], now);
}
function makeActivity(provider: Provider, sessions: Session[], daily: Daily[], now: number): Activity {
  return { provider, sessions: sessions.sort((a, b) => a.startedAt - b.startedAt), daily: daily.sort((a, b) => a.day - b.day), scannedAt: now, telemetry: telemetry(sessions.map(s => ({ startedAt: s.startedAt, tokens: totalTokens(s.tokens), messageCount: s.messageCount })), daily, now) };
}
