import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync, lstatSync, symlinkSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { cursorCredential, cursorIdentity, cursorGrokQuota, readCursorCredential } from "../src/main/providers/cursor-grok";
import { endpoints, httpTransport, type HTTP, type Command } from "../src/main/providers/transport";
import { DesktopConnections } from "../src/main/connections";
import { Preferences } from "../src/main/preferences";
import { compose } from "../src/main/composition";
import { projectSettings } from "../src/main/ipc";
import { Coordinator } from "../src/main/coordinator";
import { Unavailable } from "../src/domain/models";

const now = Date.parse("2026-10-16T12:00:00Z"), roots: string[] = [], writers: DatabaseSync[] = [], coordinators: Coordinator[] = [];
const token = (sub = "auth0|fixture-user", exp = now / 1000 + 3600) => `${Buffer.from('{"alg":"fixture"}').toString("base64url")}.${Buffer.from(JSON.stringify({ sub, exp, privateField: "OMIT" })).toString("base64url")}.synthetic`;
const paid = JSON.stringify({ usagePercent: 25, includedLimitZero: false, nextResetTimestampUtc: "2026-10-20T12:00:00Z", privateField: "OMIT" });
function fixture() {
  const home = mkdtempSync(join(tmpdir(), "meterusage-cursor-fixture-")); roots.push(home);
  const directory = join(home, "Library/Application Support/Cursor/User/globalStorage"), path = join(directory, "state.vscdb");
  mkdirSync(directory, { recursive: true });
  const db = new DatabaseSync(path); writers.push(db);
  db.exec("CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value)");
  const set = (value: string | Uint8Array = token()) => db.prepare("INSERT OR REPLACE INTO ItemTable VALUES ('cursorAuth/accessToken', ?)").run(value);
  set();
  return { home, db, path, directory, set };
}
async function setup() {
  const f = fixture(), stored = new Map<string, string>();
  const command = vi.fn<Command>(async (_binary, args) => {
    if (_binary === "/bin/ps") return "  1 /sbin/launchd\n 42 /synthetic/MeterUsage";
    const key = args[2];
    if (args[0] === "write") { stored.set(key, args[4]); return ""; }
    if (!stored.has(key)) throw new Error("Absent fixture preference");
    return args[0] === "read-type" ? key === "showProviderGrok" ? "boolean" : "string" : stored.get(key)!;
  });
  const launch = { home: f.home, data: join(f.home, "app-data"), env: {}, demo: false, candidate: false };
  const prefs = await Preferences.load(launch, command);
  let handler: HTTP = async url => url === endpoints.cursorIdentity ? '{"sub":"auth0|fixture-user","email":"OMIT"}' : paid;
  const http = vi.fn<HTTP>((...args) => handler(...args));
  const connections = new DesktopConnections(launch, prefs, "/synthetic/helper", () => {}, command, http, () => now);
  const connect = async () => {
    await prefs.set("desktopGrokSource", "cursor");
    await prefs.set("desktopGrokIdentity", cursorCredential(token(), now).identity);
    await prefs.set("showProviderGrok", true);
    return true;
  };
  return { ...f, prefs, launch, command, stored, http, connections, connect, handler: (value: HTTP) => { handler = value; } };
}
beforeEach(() => { vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("Forbidden live network"); })); });
afterEach(() => {
  for (const c of coordinators.splice(0)) c.stop();
  for (const db of writers.splice(0)) db.close();
  vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals();
  for (const home of roots.splice(0)) rmSync(home, { recursive: true, force: true });
});
it("derives the established cookie and opaque identity with a strict >60 second expiry", () => {
  const credential = cursorCredential(token(), now);
  expect(credential.cookie).toBe(`WorkosCursorSessionToken=fixture-user%3A%3A${token()}`);
  expect(credential.identity).toMatch(/^[a-f0-9]{64}$/);
  expect(() => cursorIdentity('{"sub":"fixture-user"}', credential)).not.toThrow();
  expect(() => cursorIdentity('{"sub":"AUTH0|FIXTURE-USER"}', credential)).toThrow("Not signed in");
  for (const raw of ['{}', '{"email":"fixture@example.invalid"}', '{"sub":"other"}']) expect(() => cursorIdentity(raw, credential)).toThrow("Not signed in");
  for (const exp of [now / 1000 - 1, now / 1000 + 60, NaN, Infinity]) expect(() => cursorCredential(token(undefined, exp), now)).toThrow("Not signed in");
  expect(cursorCredential(token(undefined, now / 1000 + 60.001), now).identity).toBe(credential.identity);
  for (const raw of ["", "not.jwt", token("a;cookie=bad"), token("x\r\nHeader"), token(""), "a.e30.b", token() + ";other=1", "a." + "a".repeat(17000) + ".b"]) expect(() => cursorCredential(raw, now)).toThrow("Not signed in");
});
const closed: Command = async () => "  1 /sbin/launchd\n 42 /synthetic/MeterUsage";
function close(f: ReturnType<typeof fixture>) { f.db.close(); writers.splice(writers.indexOf(f.db), 1); }
function snapshot(directory: string) {
  return readdirSync(directory).sort().map(name => {
    const path = join(directory, name), bytes = readFileSync(path), s = lstatSync(path, { bigint: true });
    return { name, bytes: bytes.toString("base64"), hash: createHash("sha256").update(bytes).digest("hex"), stats: [s.dev, s.ino, s.mode, s.uid, s.gid, s.nlink, s.size, s.mtimeNs, s.ctimeNs].map(String) };
  });
}
it.each(["text", "utf8", "utf16", "checkpointed-wal", "empty-sidecars"])("reads a closed/checkpointed store (%s) with all bytes, hashes and change stats preserved", async mode => {
  const f = fixture();
  f.db.prepare("INSERT INTO ItemTable VALUES ('unselected/private', ?)").run("OMIT_PRIVATE");
  f.set(mode === "utf8" ? Buffer.from(token()) : mode === "utf16" ? Buffer.from(token(), "utf16le") : token());
  if (mode === "checkpointed-wal") f.db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_checkpoint(TRUNCATE)");
  close(f);
  if (mode === "empty-sidecars") for (const suffix of ["-wal", "-shm", "-journal"]) writeFileSync(f.path + suffix, "");
  const before = snapshot(f.directory);
  expect(await readCursorCredential(f.home, now, closed)).toMatchObject(cursorCredential(token(), now));
  expect(snapshot(f.directory)).toEqual(before);
});
it.each(["wal", "journal"])("rejects nonempty %s with every file unchanged, including existing shm", async sidecar => {
  const f = fixture();
  if (sidecar === "wal") { f.db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0"); f.set(token("uncheckpointed")); }
  else { close(f); writeFileSync(f.path + "-journal", "synthetic hot journal"); }
  const before = snapshot(f.directory);
  await expect(readCursorCredential(f.home, now, closed)).rejects.toMatchObject({ code: "notSignedIn" });
  expect(snapshot(f.directory)).toEqual(before);
});
it("does not mistake Apple's system cursor UI service for the Cursor editor", async () => {
  const f = fixture(); close(f);
  const command: Command = async () => "  1 /sbin/launchd\n 854 /System/Library/PrivateFrameworks/Fixture.framework/CursorUIViewService";
  const before = snapshot(f.directory);
  expect(await readCursorCredential(f.home, now, command)).toMatchObject(cursorCredential(token(), now));
  expect(snapshot(f.directory)).toEqual(before);
});
it.each([
  "/Applications/Cursor.app/Contents/MacOS/Cursor",
  "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper (Renderer)",
  "/Applications/Other.app/Contents/MacOS/CursorUIViewService",
])("still rejects a Cursor-named process outside Apple's system service: %s", async executable => {
  const f = fixture(); close(f);
  const command: Command = async () => ` 42 ${executable}`;
  await expect(readCursorCredential(f.home, now, command)).rejects.toMatchObject({ code: "notSignedIn" });
});
it.each(["active", "post-active", "ambiguous", "unavailable", "stat-change", "sidecar-created", "symlink"])("fails closed for process/filesystem evidence: %s", async action => {
  const f = fixture(); close(f); let calls = 0;
  if (action === "symlink") { rmSync(f.path); symlinkSync("absent", f.path); }
  const command: Command = async () => {
    calls++;
    if (action === "unavailable") throw new Error("OMIT provider details");
    if (action === "ambiguous") return "unknown process list";
    if (action === "active" || action === "post-active" && calls === 2) return " 42 /Applications/Cursor.app/Contents/MacOS/Cursor";
    if (calls === 2 && action === "stat-change") utimesSync(f.path, new Date(0), new Date(0));
    if (calls === 2 && action === "sidecar-created") writeFileSync(f.path + "-shm", "external race");
    return closed("", []);
  };
  await expect(readCursorCredential(f.home, now, command)).rejects.toMatchObject({ code: "notSignedIn" });
  if (action === "active" || action === "ambiguous" || action === "unavailable") expect(calls).toBe(1);
});
it("fails closed for absent, malformed, expired and duplicate stores without creating sidecars", async () => {
  const f = fixture();
  f.db.prepare("DELETE FROM ItemTable").run(); await expect(readCursorCredential(f.home, now, closed)).rejects.toMatchObject({ code: "notSignedIn" });
  for (const value of ["bad", token(undefined, now / 1000 + 60)]) { f.set(value); await expect(readCursorCredential(f.home, now, closed)).rejects.toMatchObject({ code: "notSignedIn" }); }
  f.db.exec("DROP TABLE ItemTable; CREATE TABLE ItemTable (key TEXT, value TEXT)");
  f.db.prepare("INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?), ('cursorAuth/accessToken', ?)").run(token(), token());
  await expect(readCursorCredential(f.home, now, closed)).rejects.toMatchObject({ code: "notSignedIn" }); close(f);
  const names = readdirSync(f.directory); writeFileSync(f.path, "bad");
  await expect(readCursorCredential(f.home, now, closed)).rejects.toMatchObject({ code: "notSignedIn" });
  expect(readdirSync(f.directory)).toEqual(names); rmSync(f.path);
  await expect(readCursorCredential(f.home, now, closed)).rejects.toMatchObject({ code: "notSignedIn" });
});
it("never opens Cursor's store when cancelled during SQLite import", async () => {
  const f = fixture(); close(f);
  const controller = new AbortController(), opened = vi.fn(), queried = vi.fn();
  vi.doMock("node:sqlite", () => {
    controller.abort();
    return { DatabaseSync: class {
      constructor() { opened(); }
      prepare() { queried(); return { all: () => [{ value: token() }] }; }
      close() {}
    } };
  });
  try {
    await expect(readCursorCredential(f.home, now, closed, controller.signal)).rejects.toMatchObject({ code: "notSignedIn" });
    expect(controller.signal.aborted).toBe(true);
    expect(opened).not.toHaveBeenCalled();
    expect(queried).not.toHaveBeenCalled();
  } finally { vi.doUnmock("node:sqlite"); }
});
it("keeps established paid, legacy and trial semantics, missing quota and measured zero distinct", () => {
  const q = cursorGrokQuota(paid, now); expect(q.windows).toEqual([{ label: "Grok Bot via Cursor", usedPercent: 25, resetsAt: Date.parse("2026-10-20T12:00:00Z") }]);
  expect(JSON.stringify(q)).not.toContain("OMIT");
  expect(cursorGrokQuota('{"usagePercent":0,"hasNonZeroIncludedLimit":true}', now).windows[0].usedPercent).toBe(0);
  const trial = cursorGrokQuota(JSON.stringify({ usagePercent: 100, includedLimitZero: true, hasNonZeroIncludedLimit: true, nextResetTimestampUtc: "2026-10-20T12:00:00Z", sandTrialExpiresAt: "2026-10-17T12:00:00Z" }), now).windows[0];
  expect(trial.label).toContain("Trial"); expect(trial.resetsAt).toBeUndefined(); expect(trial.windowDurationMins).toBeUndefined();
  for (const value of [{}, { usagePercent: 0 }, { includedLimitZero: false }, { usagePercent: 0, includedLimitZero: true }, { usagePercent: 0, includedLimitZero: true, sandTrialExpiresAt: "2026-10-16T12:00:00Z" }, { usagePercent: 0, sandTrialExpiresAt: "invalid" }, { usagePercent: 0, includedLimitZero: "false" }, { usagePercent: -1, includedLimitZero: false }, { usagePercent: 101, includedLimitZero: false }, { usagePercent: 0, includedLimitZero: false, nextResetTimestampUtc: "bad" }]) expect(() => cursorGrokQuota(JSON.stringify(value), now)).toThrow("No usage yet");
});
it("restores a saved legacy Cursor source, keeps its hash private and keeps CLI explicit", async () => {
  const f = await setup();
  const providerBefore = snapshot(f.directory);
  expect(await f.connect()).toBe(true);
  expect(snapshot(f.directory)).toEqual(providerBefore);
  const identity = f.prefs.values.desktopGrokIdentity;
  expect(f.connections.state.find(c => c.provider === "grok")).toMatchObject({ source: "account", accountMethod: "cursor" });
  expect(identity).toMatch(/^[a-f\d]{64}$/); expect(f.connections.enabled("grok")).toBe(true);
  const source = compose(f.launch, f.prefs, { connections: f.connections }).find(s => s.slot.provider === "grok")!;
  expect(Object.keys(source).sort()).toEqual(["accountBound", "quota", "slot"]); expect((await source.quota!()).windows[0].usedPercent).toBe(25);
  for (const value of [JSON.stringify(f.connections.state), JSON.stringify(projectSettings(f.prefs.values, [], f.home)), JSON.stringify([...f.stored])]) expect(value).not.toMatch(/fixture-user|synthetic|OMIT|WorkosCursor/);
  expect(JSON.stringify(projectSettings(f.prefs.values, [], f.home))).not.toContain(identity as string);
  const reloaded = await Preferences.load(f.launch, f.command); expect(reloaded.values.desktopGrokIdentity).toBe(identity);
  await f.connections.disconnect("grok"); expect(f.prefs.values.desktopGrokIdentity).toBe("off");
  expect(compose(f.launch, f.prefs).find(s => s.slot.provider === "grok")!.usage).toBeUndefined();
  await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  await f.connections.useLocal("grok"); expect(f.prefs.values.desktopGrokIdentity).toBe(""); expect(compose(f.launch, f.prefs).find(s => s.slot.provider === "grok")!.usage).toBeTypeOf("function");
  await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
});
it("rejects mismatched server identities, missing quota and account switches for a saved Cursor source", async () => {
  const f = await setup(); await f.connect();
  f.handler(async () => '{"sub":"other"}'); await expect(f.connections.quota("grok")).rejects.toThrow("Not signed in");
  expect(f.http.mock.calls.map(c => c[0])).toEqual([endpoints.cursorIdentity]);
  f.handler(async url => url === endpoints.cursorIdentity ? '{"sub":"fixture-user"}' : '{}'); await expect(f.connections.quota("grok")).rejects.toMatchObject({ code: "noData" });
  f.set(token("other")); f.http.mockClear(); await expect(f.connections.quota("grok")).rejects.toMatchObject({ code: "notSignedIn" }); expect(f.http).not.toHaveBeenCalled();
});
it.each(["switch", "disconnect", "local", "reconnect", "abort"])("rejects stale quota results after %s", async action => {
  const f = await setup(); await f.connect();
  let release!: (raw: string) => void, ready!: () => void;
  const waiting = new Promise<void>(r => { ready = r; });
  f.handler(async url => url === endpoints.cursorIdentity ? '{"sub":"fixture-user"}' : new Promise<string>(r => { release = r; ready(); }));
  const controller = new AbortController(), reading = f.connections.quota("grok", controller.signal), failure = expect(reading).rejects.toThrow(); await waiting;
  if (action === "switch") f.set(token("other"));
  if (action === "disconnect" || action === "reconnect") await f.connections.disconnect("grok");
  if (action === "local") await f.connections.useLocal("grok");
  if (action === "abort") controller.abort();
  if (action === "reconnect") { f.handler(async url => url === endpoints.cursorIdentity ? '{"sub":"fixture-user"}' : paid); await f.connect(); }
  const processReads = f.command.mock.calls.filter(c => c[0] === "/bin/ps").length;
  release(paid); await failure;
  if (action !== "switch") expect(f.command.mock.calls.filter(c => c[0] === "/bin/ps")).toHaveLength(processReads);
});
it("uses coordinator backoff for transport failures and clears unverified account archives", async () => {
  const f = await setup(); await f.connect(); let clock = now;
  const source = compose(f.launch, f.prefs, { connections: f.connections }).find(s => s.slot.provider === "grok")!;
  const c = new Coordinator(f.launch, f.prefs, [source], () => clock); coordinators.push(c);
  await c.refresh(true); expect(c.snapshot().archived.grok.windows[0].usedPercent).toBe(25);
  f.handler(async url => { if (url === endpoints.cursorIdentity) return '{"sub":"fixture-user"}'; throw new Unavailable("offline"); });
  await c.refresh(true); const calls = f.http.mock.calls.length;
  expect(c.snapshot().quotas.grok).toMatchObject({ status: "missing", code: "offline" });
  await c.refresh(true); expect(f.http).toHaveBeenCalledTimes(calls);
  clock += 60000; await c.refresh(true); expect(f.http.mock.calls.length).toBeGreaterThan(calls);
  clock += 120000; f.set(token("other")); await c.refresh(true); expect(c.snapshot().archived.grok).toBeUndefined();
  expect(c.diagnostics("fixture")).not.toMatch(/fixture-user|synthetic|OMIT|WorkosCursor/);
});
it("bounds fixed-endpoint cookie requests and sanitizes auth, redirects, network and response-limit failures", async () => {
  const cookie = cursorCredential(token(), now).cookie, calls: [unknown, RequestInit | undefined][] = [];
  const http = httpTransport(async (url, init) => { calls.push([url, init]); return new Response(paid); });
  await http(endpoints.cursorIdentity, "grok", cookie); await http(endpoints.cursorGrok, "grok", cookie);
  expect(calls[0][1]).toMatchObject({ redirect: "error", cache: "no-store", headers: { Cookie: cookie } });
  expect(calls[1][1]).toMatchObject({ method: "POST", body: "{}", headers: { Cookie: cookie, Origin: "https://cursor.com", "Content-Type": "application/json" } });
  expect(calls[0][1]!.headers).not.toHaveProperty("Authorization"); expect(calls[0][1]!.signal).toBeInstanceOf(AbortSignal);
  const missing = httpTransport(vi.fn(async () => { throw new Error("must not fetch"); }));
  await expect(missing(endpoints.cursorGrok, "grok")).rejects.toMatchObject({ code: "notSignedIn" });
  await expect(missing(endpoints.cursorGrok, "claude", cookie)).rejects.toMatchObject({ code: "notSignedIn" });
  for (const status of [301, 302, 307, 308, 401, 403, 429, 500]) {
    const fetcher = vi.fn(async () => new Response("OMIT", { status, headers: { Location: "https://example.invalid" } }));
    await expect(httpTransport(fetcher)(endpoints.cursorGrok, "grok", cookie)).rejects.toMatchObject({ code: status === 401 || status === 403 ? "notSignedIn" : "failed" }); expect(fetcher).toHaveBeenCalledTimes(1);
  }
  await expect(httpTransport(async () => { throw new Error("OMIT_RAW_ERROR"); })(endpoints.cursorIdentity, "grok", cookie)).rejects.toMatchObject({ code: "failed" });
  await expect(httpTransport(async () => { throw Object.assign(new Error("OMIT"), { cause: { code: "ENETUNREACH" } }); })(endpoints.cursorIdentity, "grok", cookie)).rejects.toMatchObject({ code: "offline" });
  const cancel = vi.fn();
  await expect(httpTransport(async () => new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(1048577)); }, cancel })))(endpoints.cursorGrok, "grok", cookie)).rejects.toMatchObject({ code: "failed" }); expect(cancel).toHaveBeenCalled();
  const controller = new AbortController(); controller.abort(); const untouched = vi.fn(async () => new Response(paid));
  await expect(httpTransport(untouched)(endpoints.cursorGrok, "grok", cookie, controller.signal)).rejects.toMatchObject({ code: "failed" }); expect(untouched).not.toHaveBeenCalled();
  vi.spyOn(AbortSignal, "timeout").mockImplementation(ms => { expect(ms).toBe(30000); return AbortSignal.abort(); });
  await expect(httpTransport(untouched)(endpoints.cursorIdentity, "grok", cookie)).rejects.toMatchObject({ code: "failed" }); expect(untouched).not.toHaveBeenCalled();
});
it("denies demo and isolated Codex/Claude profiles before Cursor reads", async () => {
  const f = await setup();
  for (const restricted of [{ demo: true }, { codexTest: true }, { claudeTest: true }]) {
    const c = new DesktopConnections({ ...f.launch, ...restricted }, f.prefs, "/synthetic/helper", () => {}, f.command, f.http);
    const consent = vi.fn(async () => true);
    await expect(c.connect("grok", async () => {}, consent)).rejects.toThrow(); await expect(c.quota("grok")).rejects.toMatchObject({ code: "notSignedIn" });
    expect(consent).not.toHaveBeenCalled(); expect(f.http).not.toHaveBeenCalled();
  }
});

it("keeps immutable SQLite bytes and sidecars unchanged even with a concurrent synthetic WAL writer", () => {
  const f = fixture();
  f.db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0"); f.set(token("uncheckpointed"));
  const before = snapshot(f.directory);
  const uri = new URL("file://" + f.path); uri.searchParams.set("immutable", "1"); uri.searchParams.set("mode", "ro");
  const reader = new DatabaseSync(uri.href, { readOnly: true, allowExtension: false });
  try {
    expect(reader.prepare("SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'").get()!.value).toBe(token());
    expect(() => reader.exec("CREATE TABLE forbidden (value)")).toThrow();
  } finally { reader.close(); }
  expect(snapshot(f.directory)).toEqual(before);
});
it.each(["before-bot", "during-bot"])("rejects a same-account store change %s", async stage => {
  const f = await setup(); await f.connect();
  f.handler(async url => {
    if (url === (stage === "before-bot" ? endpoints.cursorIdentity : endpoints.cursorGrok)) f.set(token(undefined, now / 1000 + 7200));
    return url === endpoints.cursorIdentity ? '{"sub":"fixture-user"}' : paid;
  });
  await expect(f.connections.quota("grok")).rejects.toMatchObject({ code: "notSignedIn" });
  if (stage === "before-bot") expect(f.http.mock.calls.map(c => c[0])).toEqual([endpoints.cursorIdentity]);
});
it("rejects expired credentials before HTTP and expiry during a saved Cursor request", async () => {
  const f = await setup(); await f.connect(); f.set(token(undefined, now / 1000 + 60));
  await expect(f.connections.quota("grok")).rejects.toMatchObject({ code: "notSignedIn" }); expect(f.http).not.toHaveBeenCalled();
  f.set(); let clock = now;
  const c = new DesktopConnections(f.launch, f.prefs, "/synthetic/helper", () => {}, f.command, f.http, () => clock);
  f.handler(async url => { if (url === endpoints.cursorIdentity) return '{"sub":"fixture-user"}'; clock += 3600000; return paid; });
  await expect(c.quota("grok")).rejects.toMatchObject({ code: "notSignedIn" });
});

it("keeps Grok disabled when saving disconnect fails and returns only a fixed message", async () => {
  const f = await setup(); await f.connect();
  vi.spyOn(f.prefs, "set").mockRejectedValueOnce(new Error("OMIT_RAW_ERROR"));
  await expect(f.connections.disconnect("grok")).rejects.toThrow("Could not disconnect Grok Bot Desktop");
  expect(f.connections.enabled("grok")).toBe(false); expect(f.prefs.values.desktopGrokIdentity).toBe("off");
});
