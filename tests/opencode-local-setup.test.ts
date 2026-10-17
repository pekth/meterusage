import { afterEach, expect, it, vi } from "vite-plus/test";
import { DatabaseSync } from "node:sqlite";
import { accessSync, chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compose } from "../src/main/composition";
import { Preferences } from "../src/main/preferences";
import type { Launch } from "../src/main/launch";
import { cliPath, type Command, type HTTP } from "../src/main/providers/transport";
import { openCodeQuery } from "../src/main/providers/usage";

const fixtureRoots = vi.hoisted(() => new Set<string>());
vi.mock("node:fs", async importOriginal => {
  const actual = await importOriginal<typeof import("node:fs")>();
  return { ...actual, accessSync: vi.fn((path: string, mode?: number) => {
    if (![...fixtureRoots].some(root => path.startsWith(root + "/"))) throw new Error("Outside synthetic executable roots");
    return actual.accessSync(path, mode);
  }) };
});
const now = Date.parse("2026-10-16T12:00:00Z");
afterEach(() => { for (const root of fixtureRoots) rmSync(root, { recursive: true, force: true }); fixtureRoots.clear(); vi.clearAllMocks(); });
function fixture() {
  const home = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-opencode-local-")); fixtureRoots.add(home);
  const launch: Launch = { home, data: join(home, "app-data"), env: { PATH: "/synthetic-empty-path" }, demo: false, candidate: false };
  return { home, launch };
}
function executable(home: string, path = ".bun/bin/opencode", mode = 0o700) {
  const binary = join(home, path); mkdirSync(join(binary, ".."), { recursive: true }); writeFileSync(binary, "synthetic executable fixture\n"); chmodSync(binary, mode); return binary;
}
async function source(launch: Launch, command: Command) {
  const prefs = await Preferences.load(launch, async () => { throw new Error("No synthetic native preferences"); });
  const http = vi.fn<HTTP>(async () => { throw new Error("Forbidden provider HTTP"); });
  return { source: compose(launch, prefs, { command, http, now: () => now }).find(s => s.slot.provider === "openCodeGo")!, http };
}
it("reads Go-only local DB activity without auth, allowance or HTTP and preserves database bytes", async () => {
  const { home, launch } = fixture(), path = join(home, ".local/share/opencode/opencode.db"); mkdirSync(join(path, ".."), { recursive: true });
  const db = new DatabaseSync(path);
  try {
    db.exec("CREATE TABLE session(id TEXT, model TEXT, tokens_input INTEGER, tokens_output INTEGER, tokens_reasoning INTEGER, tokens_cache_read INTEGER, tokens_cache_write INTEGER, cost REAL, time_created INTEGER, time_updated INTEGER, directory TEXT); CREATE TABLE message(session_id TEXT, body TEXT);");
    const insert = db.prepare("INSERT INTO session VALUES(?,?,?,?,?,?,?,?,?,?,?)");
    insert.run("go", '{"providerID":"opencode-go"}', 100, 20, 3, 4, 5, 0.2, now, now, "/synthetic/project");
    insert.run("other", '{"providerID":"other-provider"}', 9000, 9000, 0, 0, 0, 9, now, now, "/synthetic/other");
    db.exec("INSERT INTO message VALUES('go','PRIVATE_BODY'),('other','PRIVATE_BODY')");
  } finally { db.close(); }
  const before = readFileSync(path), command = vi.fn<Command>(async () => { throw new Error("Forbidden CLI"); });
  const f = await source(launch, command);
  await expect(f.source.quota!()).rejects.toMatchObject({ code: "dataNotFound" });
  const usage = await f.source.usage!();
  expect(usage).toMatchObject({ provider: "openCodeGo", sessionCount: 1, messageCount: 1, tokens: { input: 100, output: 20, reasoning: 3, cacheRead: 4, cacheWrite: 5 } });
  expect(JSON.stringify(usage)).not.toContain("PRIVATE_BODY");
  expect(existsSync(join(home, ".local/share/opencode/auth.json"))).toBe(false);
  expect(readFileSync(path)).toEqual(before); expect(f.http).not.toHaveBeenCalled(); expect(command).not.toHaveBeenCalled();
});
it("finds a Bun-only OpenCode and falls back to only the fixed read-only JSON query", async () => {
  const { home, launch } = fixture(), binary = executable(home), signal = new AbortController().signal;
  const command = vi.fn<Command>(async () => JSON.stringify([{ input: 12, output: 2, messages: 1, created: now, updated: now }]));
  const f = await source(launch, command);
  await expect(f.source.quota!()).rejects.toMatchObject({ code: "dataNotFound" });
  expect((await f.source.usage!(signal)).tokens?.input).toBe(12);
  expect(command).toHaveBeenCalledExactlyOnceWith(binary, ["db", "--format", "json", openCodeQuery], expect.objectContaining({ signal }));
  expect(openCodeQuery).toContain("'opencode-go'"); expect(openCodeQuery).not.toMatch(/INSERT|UPDATE|DELETE|body|content|prompt/);
  expect(f.http).not.toHaveBeenCalled();
});
it("keeps missing and nonexecutable OpenCode unavailable", async () => {
  const { home, launch } = fixture(), command = vi.fn<Command>();
  expect(() => cliPath("opencode", home, launch.env)).toThrow("not found");
  executable(home, ".bun/bin/opencode", 0o600);
  const f = await source(launch, command);
  await expect(f.source.usage!()).rejects.toMatchObject({ code: "cliNotFound" });
  expect(command).not.toHaveBeenCalled(); expect(f.http).not.toHaveBeenCalled();
});
it("does not add Bun discovery or change the search order for other tools", () => {
  const { home, launch } = fixture(); executable(home, ".bun/bin/codex");
  expect(() => cliPath("codex", home, launch.env)).toThrow("not found");
  expect(vi.mocked(accessSync).mock.calls.map(([path]) => path)).toEqual(["/opt/homebrew/bin/codex", "/usr/local/bin/codex", join(home, ".cargo/bin/codex"), join(home, ".local/bin/codex"), "/synthetic-empty-path/codex"]);
});
