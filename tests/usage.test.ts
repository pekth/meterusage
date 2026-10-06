import { describe, it, expect, afterEach } from "vite-plus/test";
import { DatabaseSync } from "node:sqlite";
import { mkdtempSync, writeFileSync, rmSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { parseGeneration, parseStep, conversationUsage, readConversations, AntigravityRuntime } from "../src/main/providers/antigravity";
import { antigravityHistory, grokUsage, openCodeUsage, parseOpenCodeRows, openCodeQuery, openRouterUsage } from "../src/main/providers/usage";
import { type Command } from "../src/main/providers/transport";
const roots: string[] = []; const temp = () => { const root = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); roots.push(root); return root; };
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const now = Date.parse("2026-10-06T12:00:00Z");
function varint(n: number) { const bytes: number[] = []; do { const b = n % 128; n = Math.floor(n / 128); bytes.push(b + (n ? 128 : 0)); } while (n); return Buffer.from(bytes); }
const integer = (field: number, value: number) => Buffer.concat([varint(field * 8), varint(value)]);
const nested = (field: number, bytes: Uint8Array) => Buffer.concat([varint(field * 8 + 2), varint(bytes.length), bytes]);
const generation = nested(1, nested(4, Buffer.concat([integer(2, 100), integer(3, 20), integer(5, 50), integer(9, 7), nested(14, Buffer.from("PRIVATE_TEXT"))])));
const step = (source: number, at: number) => Buffer.concat([nested(1, integer(1, at / 1000)), integer(3, source), nested(10, Buffer.from("PRIVATE_PROMPT"))]);
describe("Antigravity numeric conversation contract", () => {
  it("decodes numeric fields and role/timestamps without decoding unrelated bytes", () => {
    expect(parseGeneration(generation)).toEqual({ input: 100, output: 20, reasoning: 7, cacheRead: 50, cacheWrite: 0 });
    expect(parseStep(step(4, now))).toEqual({ role: "user", timestamp: now }); expect(parseStep(step(7, now))).toBeUndefined(); expect(parseGeneration(Buffer.from([255, 255]))).toBeUndefined();
    const u = conversationUsage([{ generations: [generation], steps: [step(4, now - 2 * 86400000), step(4, now), step(2, now)] }], now);
    expect(u.messageCount).toBe(2); expect(u.todaySessionCount).toBe(0); expect(u.todayMessageCount).toBe(1); expect(u.todayTokens?.input).toBe(100); expect(u.usageWindows?.[0].sessionCount).toBe(1); expect(JSON.stringify(u)).not.toContain("PRIVATE");
  });
  it("includes uncheckpointed WAL state through an isolated copy and preserves source bytes", async () => {
    const root = temp(), path = join(root, "synthetic.db"), db = new DatabaseSync(path);
    try {
      db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE gen_metadata(idx INTEGER,data BLOB); CREATE TABLE steps(idx INTEGER,metadata BLOB); CREATE TABLE private_content(body TEXT);");
      db.prepare("INSERT INTO gen_metadata VALUES(?,?)").run(1, generation); db.prepare("INSERT INTO steps VALUES(?,?)").run(1, step(4, now)); db.exec("INSERT INTO private_content VALUES('UNREAD_CONTENT')");
      const before = readFileSync(path), wal = readFileSync(path + "-wal");
      const result = await readConversations(root, now); expect(result.tokens?.input).toBe(100); expect(result.messageCount).toBe(1);
      expect(readFileSync(path)).toEqual(before); expect(readFileSync(path + "-wal")).toEqual(wal); expect(JSON.stringify(result)).not.toContain("UNREAD_CONTENT");
    } finally { db.close(); }
  });
  it("leaves token totals unknown in old history and user-turn-only databases", () => {
    const history = JSON.stringify({ conversationId: "synthetic", timestamp: new Date(now).toISOString(), prompt: "PRIVATE" });
    expect(antigravityHistory(history + "\n" + history, now).tokens).toBeUndefined(); expect(antigravityHistory(history + "\n" + history, now).messageCount).toBe(2);
    expect(conversationUsage([{ generations: [], steps: [step(4, now)] }], now).tokens).toBeUndefined();
  });
});
describe("existing runtime recovery", () => {
  it("prefers an already healthy runtime without starting a machine", async () => {
    const root = temp(), docker = join(root, "docker"), podman = join(root, "podman"); for (const p of [docker, podman]) writeFileSync(p, "", { mode: 0o700 });
    const calls: string[][] = [], command: Command = async (binary, args) => { calls.push([binary, ...args]); return "healthy"; };
    expect(await new AntigravityRuntime([docker, podman], command).resolve()).toBe(docker); expect(calls).toEqual([[docker, "info"]]);
  });
  it("inspects before starting, never creates a machine, and cools down failed recovery", async () => {
    const root = temp(), podman = join(root, "podman"); writeFileSync(podman, "", { mode: 0o700 });
    const calls: string[][] = [], command: Command = async (_binary, args) => { calls.push(args); if (args.includes("inspect")) return "existing"; throw new Error("unavailable"); };
    const runtime = new AntigravityRuntime([podman], command);
    expect(await runtime.resolve(undefined, now)).toBeUndefined(); expect(calls).toEqual([["info"], ["machine", "inspect", "podman-machine-default"], ["machine", "start", "podman-machine-default"]]);
    calls.length = 0; expect(await runtime.resolve(undefined, now + 1000)).toBeUndefined(); expect(calls).toEqual([["info"]]);
  });
  it("checks existing image and volumes before quota invocation", async () => {
    const root = temp(), docker = join(root, "docker"); writeFileSync(docker, "", { mode: 0o700 }); const calls: string[][] = [];
    const runtime = new AntigravityRuntime([docker], async (_binary, args) => { calls.push(args); if (args[0] === "run") return "Gemini Models\tWeekly Limit Remaining\t100%\t2030-01-01T00:00:00Z"; return "exists"; });
    expect((await runtime.quota(now)).windows[0].usedPercent).toBe(0);
    expect(calls.slice(1, 4)).toEqual([["image", "inspect", "antigravity-cli:local"], ["volume", "inspect", "antigravity-config"], ["volume", "inspect", "antigravity-bin"]]); expect(calls.at(-1)).toContain("--pull=never");
  });
});
describe("supplemental usage", () => {
  it("counts Grok summaries, not context counters, and leaves cost/tokens unknown", () => {
    const u = grokUsage([JSON.stringify({ created_at: now / 1000, updated_at: now / 1000 + 60, num_chat_messages: 4, context_tokens: 99999, title: "PRIVATE" })], now);
    expect(u.tokens).toBeUndefined(); expect(u.estimatedCostUSD).toBeUndefined(); expect(u.messageCount).toBe(4); expect(u.telemetry?.longestChatSeconds).toBe(60); expect(JSON.stringify(u)).not.toContain("PRIVATE");
  });
  it("uses OpenCode updated time for rolling burn and keeps provider filtering in read-only SQL", () => {
    const rows = parseOpenCodeRows(JSON.stringify([{ input: 100, output: 20, cost: 0.2, created: now / 1000 - 3 * 86400, updated: now / 1000, directory: "/invented/project", messages: 3 }]));
    const u = openCodeUsage(rows, now); expect(u.todaySessionCount).toBe(0); expect(u.todayTokens?.input).toBe(100); expect(u.usageWindows?.[0].sessionCount).toBe(1); expect(u.projectBreakdown?.[0].project).toBe("project");
    expect(openCodeQuery).toContain("'opencode-go'"); expect(openCodeQuery).not.toMatch(/body|content|prompt|INSERT|UPDATE|DELETE/);
  });
  it("aggregates OpenRouter UTC days and explicit all-zero measured telemetry", () => {
    const u = openRouterUsage(JSON.stringify({ data: [{ date: "2026-10-06", prompt_tokens: 10, completion_tokens: 2, requests: 1, usage: 0.1 }, { date: "2026-10-06", prompt_tokens: 20, completion_tokens: 3, reasoning_tokens: 4, requests: 2, usage: 0.2 }] }), now);
    expect(u.todayTokens?.input).toBe(30); expect(u.todayMessageCount).toBe(3); expect(u.telemetry?.todayTokens).toBe(39);
    const zero = openRouterUsage('{"data":[]}', now); expect(zero.tokens?.input).toBe(0); expect(zero.telemetry?.lifetimeTokens).toBe(0);
  });
});
