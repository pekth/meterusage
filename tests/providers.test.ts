import { describe, it, expect, afterEach, vi } from "vite-plus/test";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, statSync, createReadStream } from "node:fs";
import { open, readdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { selectJSON } from "../src/main/select-json";
import { claudeTierSelection, parseClaudePlan, parseCodex, parseClaudeQuota, parseOpenRouter, parseOpenCode, parseGrok, parseLocalQuota, parseAntigravity, parseStatus } from "../src/main/providers/parsers";
import { ClaudeActivitySource, scanCodex, parseClaudeLine, claudeLineSelection, parseCodexTokenLine, opaqueID } from "../src/main/providers/activity";
import { codexRPC, runCommand, httpTransport, endpoints } from "../src/main/providers/transport";
const roots: string[] = [];
vi.mock("node:fs", async original => { const fs = await original<typeof import("node:fs")>(); return { ...fs, statSync: vi.fn(fs.statSync), createReadStream: vi.fn(fs.createReadStream) }; });
vi.mock("node:fs/promises", async original => { const fs = await original<typeof import("node:fs/promises")>(); return { ...fs, open: vi.fn(fs.open), readdir: vi.fn(fs.readdir) }; });
const temp = () => { const root = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); roots.push(root); return root; };
afterEach(() => { vi.mocked(statSync).mockReset(); vi.mocked(createReadStream).mockReset(); vi.mocked(open).mockReset(); vi.mocked(readdir).mockReset(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const fixture = (name: string) => readFileSync(join("Tests/MeterUsageTests/Fixtures", name), "utf8");
const now = Date.parse("2026-10-06T12:00:00Z");
describe("selective privacy boundary", () => {
  it("materializes tier scalars only, including escaped keys and nested unknown values", () => {
    const scalars: string[] = [];
    const input = String.raw`{"oauth\u0041ccount":{"organizationRateLimitTier":"max_20x","email":"invented@example.invalid","unknown":{"array":[{"secret":"private\\value"},true,12,null]}},"projects":{"private":"omitted"}}`;
    const result = selectJSON(input, claudeTierSelection, scalar => scalars.push(scalar));
    expect(scalars).toEqual(['"max_20x"']); expect(JSON.stringify(result)).not.toContain("private");
    expect(parseClaudePlan(input)).toBe("Max 20×");
  });
  it("skips transcript bodies and tools before scalar decoding", () => {
    const input = JSON.stringify({ type: "assistant", timestamp: "2026-10-06T11:00:00Z", message: { model: "claude-sonnet-4-6", content: [{ text: "PRIVATE_CONTENT" }], tool: { arguments: "PRIVATE_ARGUMENTS" }, usage: { input_tokens: 0, output_tokens: 7 } } });
    const scalars: string[] = []; selectJSON(input, claudeLineSelection, scalar => scalars.push(scalar));
    expect(scalars.join()).not.toContain("PRIVATE"); expect(parseClaudeLine(input)?.tokens.input).toBe(0); expect(parseClaudeLine(input)?.tokens.output).toBe(7);
  });
  it("rejects malformed and trailing input, handles arrays and prototype keys", () => {
    for (const s of ['{"ok":1', '{"skip":"bad\\x"}', '{"ok":01}', '{} trailing', '{"a":[1,]}']) expect(() => selectJSON(s, { ok: true })).toThrow();
    expect(selectJSON('[{"x":2,"ignored":"value"}]', { '*': { x: true } })).toEqual([{ x: 2 }]);
    expect(selectJSON('{"__proto__":{"polluted":true},"ok":1}', { ok: true })).toEqual({ ok: 1 });
  });
});
describe("quota fixture parity", () => {
  it("keeps valid base Codex quota when optional model windows are malformed", () => {
    const q = parseCodex(JSON.stringify({ result: { rateLimits: { primary: { usedPercent: 0, windowDurationMins: 300 } }, rateLimitsByLimitId: { broken: { primary: {} }, valid: { limitName: "Valid model", secondary: { usedPercent: 30, windowDurationMins: 10080 } } } } }), now);
    expect(q.windows[0].usedPercent).toBe(0); expect(q.groups.map(g => g.id)).toEqual(["codex"]);
  });
  it("uses the Swift Codex fixture and classifies duration, not window position", () => {
    const q = parseCodex(fixture("codex_ratelimits.json"), now);
    expect(q.windows.map(w => w.label)).toEqual(["Weekly"]); expect(q.windows[0].usedPercent).toBe(42);
    expect(q.credits?.balance).toBe(25.5); expect(q.credits?.dollarBalance).toBe(1.02); expect(q.windows[0].resetsAt).toBe(1893456000000);
  });
  it("keeps model groups, reset details and zero-valued windows when optional credits are malformed", () => {
    const q = parseCodex(JSON.stringify({ result: { rateLimits: { primary: { usedPercent: 0, windowDurationMins: 300 }, credits: { balance: "bad" } }, rateLimitsByLimitId: { model: { limitName: "Model", secondary: { usedPercent: 30, windowDurationMins: 10080 } } }, rateLimitResetCredits: { availableCount: 1, credits: [{ id: "synthetic-credit", expiresAt: "2030-01-01T00:00:00Z" }] } } }), now);
    expect(q.windows[0].usedPercent).toBe(0); expect(q.credits).toBeUndefined(); expect(q.groups).toHaveLength(2); expect(q.resetCredits[0].id).toBe("synthetic-credit");
    expect(() => parseCodex('{"error":{"code":-32603,"message":"backend unreachable"}}')).toThrow("Offline");
    expect(() => parseCodex('{"error":{"message":"not logged in"}}')).toThrow("Not signed in");
  });
  it("preserves Claude legacy and scoped windows, extra usage and tier projection", () => {
    expect(parseClaudePlan(fixture("claude_account.json"))).toBe("Max 20×");
    expect(parseClaudeQuota(fixture("optional_quota.json"), now).windows.map(w => w.usedPercent)).toEqual([61, 24]);
    const q = parseClaudeQuota(JSON.stringify({ limits: [{ kind: "weekly_scoped", percent: 12, scope: { model: { display_name: "Fable" } } }, { kind: "session", percent: 0 }, { kind: "weekly_all", percent: 24 }], five_hour: { used_percentage: 99 }, extra_usage: { is_enabled: true, used_credits: 100, monthly_limit: 1000 } }), now);
    expect(q.windows.map(w => w.label)).toEqual(["5-hour", "Weekly · All models", "Weekly · Fable"]); expect(q.credits?.balance).toBe(9);
  });
  it("treats account credits as optional and never substitutes absent usage with a quota percentage", () => {
    expect(parseOpenRouter('{"data":{"usage":0,"limit":100}}', "invalid", now).windows[0].usedPercent).toBe(0);
    expect(parseOpenRouter('{"data":{"usage":10}}', '{"data":{"total_credits":"100","total_usage":"30"}}').credits?.balance).toBe(70);
    expect(parseOpenRouter('{"data":{"limit":100}}').windows).toEqual([]);
    expect(() => parseOpenRouter('{"data":{}}')).toThrow("No usage");
  });
  it("validates OpenCode windows and Grok allowance timestamps", () => {
    const usage = { rolling: { status: "ok", percent: 0, resetsAt: "2026-10-06T15:00:00.504Z" }, weekly: { status: "over_limit", percent: 100 }, monthly: { status: "ok", percent: 40 } };
    expect(parseOpenCode(JSON.stringify({ usage })).windows.map(w => w.usedPercent)).toEqual([0, 100, 40]);
    expect(() => parseOpenCode(JSON.stringify({ usage: { ...usage, rolling: { percent: 0 } } }))).toThrow();
    expect(() => parseOpenCode('{"error":{"type":"AuthError"}}')).toThrow("Not signed in");
    expect(parseGrok('{"config":{"creditUsagePercent":0,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-10-07T00:00:00.123Z"}}}').windows[0].usedPercent).toBe(0);
    expect(() => parseGrok('{"config":{"currentPeriod":{"end":"2026-10-07T00:00:00Z"}}}')).toThrow("No usage");
  });
  it("parses each local snapshot without conflating zero and absent", () => {
    for (const [p, key, label] of [["cursor", "fast_requests", "Fast requests"], ["copilot", "premium_requests", "Premium requests"], ["gemini", "requests", "Daily"]] as const) {
      expect(parseLocalQuota(p, JSON.stringify({ [key]: { used_percent: 0 } })).windows[0].label).toBe(label);
      expect(parseLocalQuota(p, '{}').windows).toEqual([]);
    }
  });
  it("maps Antigravity remaining percentages, ordered model groups and status components", () => {
    const q = parseAntigravity("Gemini Models\tWeekly Limit Remaining\t98.89%\t2026-10-07T00:00:00Z\nClaude/GPT\tFive Hour Limit Remaining\t100%\t2026-10-06T15:00:00Z", now);
    expect(q.windows[0].usedPercent).toBeCloseTo(1.11); expect(q.windows[1].label).toBe("Claude/GPT 5-hour"); expect(q.groups[1].windows[0].label).toBe("5-hour limit");
    expect(parseStatus("codex", '{"components":[{"name":"Images","status":"major_outage"},{"name":"Codex","status":"operational"}]}').severity).toBe("operational");
  });
});
describe("activity and account boundaries", () => {
  it("keeps valid Claude sessions when siblings disappear or cannot be read", async () => {
    const root = temp(), project = join(root, "-fixture-project"); mkdirSync(project);
    const line = JSON.stringify({ type: "assistant", timestamp: new Date(now).toISOString(), message: { model: "fixture", usage: { output_tokens: 7 } } }) + "\n";
    for (const name of ["valid", "gone", "unreadable", "vanished"]) writeFileSync(join(project, `${name}.jsonl`), line);
    const stat = vi.mocked(statSync).getMockImplementation()!, stream = vi.mocked(createReadStream).getMockImplementation()!;
    vi.mocked(statSync).mockImplementation(((path) => { if (String(path).endsWith("gone.jsonl")) throw Object.assign(new Error("fixture deletion"), { code: "ENOENT" }); return stat(path); }) as typeof statSync);
    vi.mocked(createReadStream).mockImplementation((path, options) => { if (String(path).endsWith("unreadable.jsonl")) throw Object.assign(new Error("fixture permission"), { code: "EACCES" }); if (String(path).endsWith("vanished.jsonl")) rmSync(path); return stream(path, options); });
    const a = await new ClaudeActivitySource(root).scan(now); expect(a.sessions).toHaveLength(1); expect(a.sessions[0].tokens.output).toBe(7); expect(a.daily[0].tokens.output).toBe(7);
    const aborted = new AbortController(), cancellation = new Error("fixture cancellation"); vi.mocked(createReadStream).mockImplementation(() => { aborted.abort(cancellation); throw new Error("fixture cancelled during read"); });
    await expect(new ClaudeActivitySource(root).scan(now, aborted.signal)).rejects.toBe(cancellation);
    const listing = new AbortController(); vi.mocked(readdir).mockImplementation(async () => { listing.abort(cancellation); return []; });
    await expect(new ClaudeActivitySource(root).scan(now, listing.signal)).rejects.toBe(cancellation);
  });
  it("uses Codex per-file metadata and ledger fallbacks without losing readable siblings", async () => {
    const root = temp(), at = new Date(now).toISOString();
    const line = [JSON.stringify({ timestamp: at, payload: { cwd: "/invented/project" } }), '{"type":"turn_context","payload":{"model":"gpt-5.4"}}', '{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7}}}}', ""].join("\n");
    for (const name of ["valid", "gone", "unreadable", "ledger-failure", "metadata-only"]) writeFileSync(join(root, `${name}.jsonl`), line);
    const stat = vi.mocked(statSync).getMockImplementation()!, read = vi.mocked(open).getMockImplementation()!;
    vi.mocked(statSync).mockImplementation(((path) => { if (String(path).endsWith("gone.jsonl") || String(path).endsWith("metadata-only.jsonl")) throw Object.assign(new Error("fixture deletion"), { code: "ENOENT" }); return stat(path); }) as typeof statSync);
    const calls = new Map<string, number>();
    vi.mocked(open).mockImplementation(async (path, flags, mode) => { const name = String(path), call = (calls.get(name) ?? 0) + 1; calls.set(name, call); if (name.endsWith("gone.jsonl") || name.endsWith("unreadable.jsonl") || (name.endsWith("ledger-failure.jsonl") && call > 1)) throw Object.assign(new Error("fixture read failure"), { code: "EACCES" }); return read(path, flags, mode); });
    const a = await scanCodex(root, now); expect(a.sessions).toHaveLength(4); expect(a.sessions.find(s => s.id === opaqueID(join(root, "valid.jsonl")))?.tokens.input).toBe(7);
    expect(a.sessions.find(s => s.id === opaqueID(join(root, "metadata-only.jsonl")))).toMatchObject({ startedAt: now, tokens: { input: 7 } });
    expect(a.sessions.find(s => s.id === opaqueID(join(root, "ledger-failure.jsonl")))?.tokens.input).toBe(0); expect(a.daily.reduce((n, d) => n + d.tokens.input, 0)).toBe(14);
    const aborted = new AbortController(), cancellation = new Error("fixture cancellation"); vi.mocked(open).mockImplementation(async () => { aborted.abort(cancellation); throw new Error("fixture cancelled during read"); });
    await expect(scanCodex(root, now, aborted.signal)).rejects.toBe(cancellation);
    const listing = new AbortController(); vi.mocked(readdir).mockImplementation(async () => { listing.abort(cancellation); return []; });
    await expect(scanCodex(root, now, listing.signal)).rejects.toBe(cancellation);
  });
  it("separates Claude accounts and reuses compatible sanitized scan cache", async () => {
    const root = temp(), primary = join(root, "primary"), alternate = join(root, "alternate");
    for (const [dir, count] of [[primary, 7], [alternate, 13]] as const) { mkdirSync(join(dir, "-synthetic-project"), { recursive: true }); writeFileSync(join(dir, "-synthetic-project", "session.jsonl"), JSON.stringify({ type: "assistant", timestamp: new Date(now).toISOString(), message: { model: "claude-sonnet-4-6", content: "DO_NOT_CACHE", usage: { output_tokens: count } } }) + "\n"); }
    const cache = join(root, "cache.json"), a = await new ClaudeActivitySource(primary, cache).scan(now), b = await new ClaudeActivitySource(alternate).scan(now);
    expect(a.sessions[0].tokens.output).toBe(7); expect(b.sessions[0].tokens.output).toBe(13);
    expect((await new ClaudeActivitySource(primary, cache).scan(now)).sessions).toEqual(a.sessions);
    expect(readFileSync(cache, "utf8")).not.toContain("DO_NOT_CACHE"); expect(readFileSync(cache, "utf8")).not.toContain(primary);
    expect(a.sessions[0].id).toBe(opaqueID("session"));
  });
  it("reads the last Codex ledger and nearest preceding model, excluding overlap", async () => {
    const root = temp();
    const ledger = (input: number) => JSON.stringify({ type: "event_msg", payload: { type: "token_count", info: { total_token_usage: { input_tokens: input, cached_input_tokens: 3, output_tokens: 10, reasoning_output_tokens: 4 } } } });
    writeFileSync(join(root, "synthetic.jsonl"), [JSON.stringify({ timestamp: new Date(now).toISOString(), payload: { cwd: "/invented/home/project", thread_source: "automation" } }), '{"type":"turn_context","payload":{"model":"gpt-5"}}', ledger(8), '{"type":"turn_context","payload":{"model":"gpt-5.4"}}', ledger(15), '{"type":"response_item","payload":{"content":"PRIVATE"}}', ''].join("\n"));
    const a = await scanCodex(root, now); expect(a.sessions[0].model).toBe("gpt-5.4"); expect(a.sessions[0].tokens).toEqual({ input: 12, output: 6, reasoning: 4, cacheRead: 3, cacheWrite: 0 }); expect(a.sessions[0].projectName).toBe("project"); expect(a.sessions[0].isAutomation).toBe(true);
    expect(parseCodexTokenLine('{"type":"response_item","payload":{}}')).toBeUndefined();
  });
});
describe("bounded transports", () => {
  it("waits for initialize, redirects one account and tears down the RPC child", async () => {
    const root = temp(), binary = join(root, "fake-codex");
    writeFileSync(binary, `#!/usr/bin/env node\nconst rl=require('node:readline').createInterface({input:process.stdin});let ready=false;rl.on('line',line=>{const r=JSON.parse(line);if(r.method==='initialize'){setTimeout(()=>{ready=true;process.stdout.write(JSON.stringify({id:1,result:{installationId:'PRIVATE'}})+'\\n')},25)}else if(r.method==='account/rateLimits/read'){if(!ready)process.exit(2);process.stdout.write(JSON.stringify({id:2,result:{home:process.env.CODEX_HOME}})+'\\n')}});`, { mode: 0o700 });
    const response = await codexRPC(binary, { env: { ...process.env, CODEX_HOME: "synthetic-account" }, timeoutMs: 1000 });
    expect(JSON.parse(response).result.home).toBe("synthetic-account"); expect(response).not.toContain("PRIVATE");
  });
  it("bounds timeout, abort and output and never propagates stderr", async () => {
    await expect(runCommand(process.execPath, ["-e", "process.stderr.write('PRIVATE');setInterval(()=>{},1000)"], { timeoutMs: 50 })).rejects.toThrow("timed out");
    const controller = new AbortController(); const pending = runCommand(process.execPath, ["-e", "setInterval(()=>{},1000)"], { signal: controller.signal }); controller.abort(); await expect(pending).rejects.toThrow("cancelled");
    await expect(runCommand(process.execPath, ["-e", "process.stdout.write('x'.repeat(10000))"], { maxBytes: 100 })).rejects.toThrow("limit");
    await expect(runCommand(process.execPath, ["-e", "process.stderr.write('PRIVATE');process.exit(1)"])).rejects.toThrow("command failed");
  });
  it("rejects redirects and unauthenticated responses using fixed endpoint routes", async () => {
    let received: RequestInit | undefined;
    const http = httpTransport(async (_url, init) => { received = init; return new Response('{}', { status: 401 }); });
    await expect(http(endpoints.openRouterKey, "openRouter", "synthetic-key")).rejects.toThrow("Not signed in");
    expect(received?.redirect).toBe("error");
    const forbidden = httpTransport(async () => { throw new Error("must not call"); });
    await expect(forbidden("https://example.invalid/" as typeof endpoints.openRouterKey, "openRouter", "synthetic-key")).rejects.toThrow("Couldn't read");
  });
});
