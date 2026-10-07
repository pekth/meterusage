import { accessSync, constants } from "node:fs";
import { copyFile, mkdtemp, readdir, rm } from "node:fs/promises";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";
import { type Usage, type Tokens, tokens, addTokens, totalTokens, localDay, weekStart, Unavailable } from "../../domain/models";
import { telemetry } from "../../domain/telemetry";
import { runCommand, type Command, type CommandOptions } from "./transport";
import { parseAntigravity } from "./parsers";
import { antigravityHistory } from "./usage";
import { readFile } from "node:fs/promises";

interface Field { number: number; varint?: number; bytes?: Uint8Array }
// Unknown protobuf values are skipped as byte ranges; no text decoding occurs.
function fields(data: Uint8Array): Field[] {
  let offset = 0; const out: Field[] = [];
  const varint = () => { let value = 0n; for (let shift = 0n; shift < 64n && offset < data.length; shift += 7n) { const b = data[offset++]; value |= BigInt(b & 127) << shift; if (!(b & 128)) return value <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(value) : undefined; } };
  while (offset < data.length) {
    const tag = varint(); if (tag === undefined || tag < 8) break;
    const number = Math.floor(tag / 8), wire = tag % 8;
    if (wire === 0) { const v = varint(); if (v === undefined) break; out.push({ number, varint: v }); }
    else if (wire === 2) { const length = varint(); if (length === undefined || length > data.length - offset) break; out.push({ number, bytes: data.subarray(offset, offset + length) }); offset += length; }
    else if (wire === 1 || wire === 5) { const length = wire === 1 ? 8 : 4; if (length > data.length - offset) break; offset += length; }
    else break;
  }
  return out;
}
const message = (fs: Field[], number: number) => { const raw = fs.find(f => f.number === number)?.bytes; return raw && fields(raw); };
const integer = (fs: Field[], number: number) => fs.find(f => f.number === number)?.varint;
export function parseGeneration(data: Uint8Array): Tokens | undefined {
  const model = message(fields(data), 1), usage = model && message(model, 4); if (!usage) return;
  const t = tokens({ input: integer(usage, 2) ?? 0, output: integer(usage, 3) ?? 0, cacheRead: integer(usage, 5) ?? 0, reasoning: integer(usage, 9) ?? 0 }); return totalTokens(t) > 0 ? t : undefined;
}
export function parseStep(data: Uint8Array): { role: "user" | "model"; timestamp: number } | undefined {
  const fs = fields(data), source = integer(fs, 3), created = message(fs, 1), seconds = created && integer(created, 1);
  if ((source !== 4 && source !== 2) || seconds === undefined || seconds <= 1000000000 || seconds >= 4102444800) return;
  return { role: source === 4 ? "user" : "model", timestamp: seconds * 1000 };
}
export interface Conversation { generations: Uint8Array[]; steps: Uint8Array[] }
export function conversationUsage(databases: Conversation[], now: number): Usage {
  const sessions = databases.flatMap(d => {
    const t = d.generations.reduce((sum, raw) => addTokens(sum, parseGeneration(raw) ?? tokens()), tokens());
    const events = d.steps.flatMap(raw => { const event = parseStep(raw); return event ? [event] : []; });
    const userTurns = events.filter(e => e.role === "user").map(e => e.timestamp), lastActivity = events.length ? Math.max(...events.map(e => e.timestamp)) : undefined;
    return totalTokens(t) > 0 || userTurns.length ? [{ tokens: t, userTurns, lastActivity }] : [];
  });
  if (!sessions.length) throw new Unavailable("noData");
  const all = sessions.reduce((sum, s) => addTokens(sum, s.tokens), tokens()), today = localDay(now), week = weekStart(now);
  const sumSince = (at: number) => sessions.filter(s => (s.lastActivity ?? -Infinity) >= at).reduce((sum, s) => addTokens(sum, s.tokens), tokens());
  const todayTokens = sumSince(today), weekTokens = sumSince(week), items = sessions.flatMap(s => { const start = s.userTurns[0] ?? s.lastActivity; return start === undefined ? [] : [{ startedAt: start, endedAt: s.lastActivity, tokens: totalTokens(s.tokens), messageCount: s.userTurns.length }]; });
  return { provider: "antigravity", sessionCount: sessions.length, messageCount: sessions.reduce((n, s) => n + s.userTurns.length, 0), tokens: totalTokens(all) > 0 ? all : undefined, todaySessionCount: sessions.filter(s => s.userTurns.length && s.userTurns[0] >= today).length, todayMessageCount: sessions.flatMap(s => s.userTurns).filter(at => at >= today).length, todayTokens: totalTokens(todayTokens) > 0 ? todayTokens : undefined, weekTokens: totalTokens(weekTokens) > 0 ? weekTokens : undefined, usageWindows: ([ ["last 24h", 1], ["last 7d", 7], ["last 30d", 30] ] as const).map(([label, days]) => { const rs = sessions.filter(s => (s.lastActivity ?? -Infinity) >= now - days * 86400000); return { label, sessionCount: rs.length, messageCount: rs.reduce((n, s) => n + s.userTurns.length, 0), tokens: rs.reduce((t, s) => addTokens(t, s.tokens), tokens()), estimatedCostUSD: 0 }; }), telemetry: telemetry(items, [], now), capturedAt: Math.max(...sessions.map(s => s.lastActivity ?? -Infinity)) === -Infinity ? now : Math.max(...sessions.map(s => s.lastActivity ?? -Infinity)) };
}
export async function readConversations(directory: string, now: number, signal?: AbortSignal): Promise<Usage> {
  signal?.throwIfAborted();
  const { DatabaseSync } = await import("node:sqlite"), databases: Conversation[] = [];
  const entries = await readdir(directory, { withFileTypes: true });
  for (const entry of entries.filter(e => e.isFile() && e.name.endsWith(".db")).sort((a, b) => a.name.localeCompare(b.name))) {
    signal?.throwIfAborted();
    const temporary = await mkdtemp(join(tmpdir(), "meterusage-agy-")), target = join(temporary, entry.name), source = join(directory, entry.name);
    try {
      await copyFile(source, target);
      for (const suffix of ["-wal", "-shm"]) { try { await copyFile(source + suffix, target + suffix); } catch (e) { if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e; } }
      // Recover only the private copy. The live DB and its WAL stay untouched.
      const db = new DatabaseSync(target, { readOnly: false });
      try { const blobs = (sql: string) => db.prepare(sql).all().flatMap(r => r.blob instanceof Uint8Array ? [r.blob] : []); databases.push({ generations: blobs("SELECT data AS blob FROM gen_metadata ORDER BY idx"), steps: blobs("SELECT metadata AS blob FROM steps WHERE metadata IS NOT NULL ORDER BY idx") }); } finally { db.close(); }
    } catch { signal?.throwIfAborted(); /* One corrupt conversation does not hide the rest. */ }
    finally { await rm(temporary, { recursive: true, force: true }); }
  }
  return conversationUsage(databases, now);
}
export class AntigravityRuntime {
  private recoveryFailedAt?: number;
  private pending?: Promise<string | undefined>;
  constructor(readonly candidates: string[], readonly command: Command = runCommand, readonly env?: NodeJS.ProcessEnv) {}
  resolve(signal?: AbortSignal, now = Date.now()): Promise<string | undefined> {
    if (this.pending) return this.pending;
    this.pending = this.select(signal, now).finally(() => { this.pending = undefined; }); return this.pending;
  }
  private async select(signal: AbortSignal | undefined, now: number): Promise<string | undefined> {
    const available = this.candidates.filter(p => { try { accessSync(p, constants.X_OK); return true; } catch { return false; } });
    for (const p of available) if (await this.probe(p, ["info"], { signal })) return p;
    if (signal?.aborted || (this.recoveryFailedAt !== undefined && now - this.recoveryFailedAt < 60000)) return;
    const podman = available.find(p => basename(p) === "podman");
    if (!podman || !await this.probe(podman, ["machine", "inspect", "podman-machine-default"], { signal })) return;
    if (!await this.probe(podman, ["machine", "start", "podman-machine-default"], { signal }) || !await this.probe(podman, ["info"], { signal })) { this.recoveryFailedAt = now; return; }
    this.recoveryFailedAt = undefined; return podman;
  }
  private async probe(binary: string, args: string[], options: CommandOptions): Promise<boolean> { try { await this.run(binary, args, options); return true; } catch { return false; } }
  run(binary: string, args: string[], options: CommandOptions = {}) { return this.command(binary, args, { ...options, env: this.env, timeoutMs: args[0] === "info" || args.includes("inspect") ? 5000 : 30000 }); }
  async quota(now: number, signal?: AbortSignal) {
    const runtime = await this.resolve(signal); if (!runtime) throw new Unavailable("noData");
    for (const args of [["image", "inspect", "antigravity-cli:local"], ["volume", "inspect", "antigravity-config"], ["volume", "inspect", "antigravity-bin"]]) if (!await this.probe(runtime, args, { signal })) throw new Unavailable("noData");
    return parseAntigravity(await this.run(runtime, ["run", "--rm", "--pull=never", "-v", "antigravity-config:/root/.gemini", "-v", "antigravity-bin:/root/.local/bin", "antigravity-cli:local", "-p", "/usage"], { signal }), now);
  }
  async usage(root: string, now: number, signal?: AbortSignal): Promise<Usage> {
    signal?.throwIfAborted();
    try { return await readConversations(join(root, "conversations"), now, signal); } catch { signal?.throwIfAborted(); /* Older native history comes next. */ }
    try { return antigravityHistory(await readFile(join(root, "history.jsonl"), { encoding: "utf8", signal }), now); } catch { signal?.throwIfAborted(); /* Container fallback uses existing volumes only. */ }
    const runtime = await this.resolve(signal); if (!runtime) throw new Unavailable("dataNotFound", "Antigravity usage");
    for (const args of [["volume", "inspect", "antigravity-config"], ["image", "inspect", "alpine"]]) if (!await this.probe(runtime, args, { signal })) throw new Unavailable("dataNotFound", "Antigravity usage");
    const temporary = await mkdtemp(join(tmpdir(), "meterusage-agy-container-"));
    try {
      await this.run(runtime, ["run", "--rm", "--pull=never", "-v", "antigravity-config:/data:ro", "-v", `${temporary}:/out`, "alpine", "sh", "-c", "cp /data/antigravity-cli/conversations/*.db /data/antigravity-cli/conversations/*.db-wal /data/antigravity-cli/conversations/*.db-shm /out/ 2>/dev/null; test -n \"$(ls /out/*.db 2>/dev/null)\""], { signal });
      return await readConversations(temporary, now, signal);
    } catch { signal?.throwIfAborted(); /* Older container installs keep only history. */ }
    finally { await rm(temporary, { recursive: true, force: true }); }
    try { return antigravityHistory(await this.run(runtime, ["run", "--rm", "--pull=never", "-v", "antigravity-config:/data:ro", "alpine", "cat", "/data/antigravity-cli/history.jsonl"], { signal }), now); } catch { throw new Unavailable("dataNotFound", "Antigravity usage"); }
  }
}
export function runtimeCandidates(env: NodeJS.ProcessEnv): string[] {
  return [...new Set(["/opt/homebrew/bin/docker", "/opt/homebrew/bin/podman", "/usr/local/bin/docker", "/usr/local/bin/podman", "/usr/bin/docker", ...(env.PATH ?? "").split(":").flatMap(p => [join(p, "docker"), join(p, "podman")])])];
}
