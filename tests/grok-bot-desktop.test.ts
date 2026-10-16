import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test";
import { createCipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, renameSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { grokBotCredential, grokBotQuota, grokBotTransport, readGrokBotCredential, type GrokBotRPC } from "../src/main/providers/grok-bot-desktop";
import { Unavailable } from "../src/domain/models";
import { DesktopConnections } from "../src/main/connections";
import { Preferences } from "../src/main/preferences";
import { selectJSON } from "../src/main/select-json";
import { projectSettings } from "../src/main/ipc";
import { compose } from "../src/main/composition";
import type { Command } from "../src/main/providers/transport";
const now = Date.parse("2026-10-16T12:00:00Z"), roots: string[] = [];
const password = "fixture-safe-storage", subject = "auth0|fixture-bot-account";
const hash = (s: string) => createHash("sha256").update(s).digest("hex");
const scope = hash(subject);
const token = (sub = subject, exp = now / 1000 + 3600) => `${Buffer.from('{"alg":"fixture"}').toString("base64url")}.${Buffer.from(JSON.stringify({ sub, exp, secret: "SKIP-JWT" })).toString("base64url")}.synthetic`;
const paid = JSON.stringify({ usagePercent: 25, includedLimitZero: false, nextResetTimestampUtc: "2026-10-20T12:00:00Z", secret: "SKIP-RESPONSE" });
function encrypted(value: string, account = scope, key = password) {
  const cipher = createCipheriv("aes-128-cbc", pbkdf2Sync(key, "saltysalt", 1003, 16, "sha1"), Buffer.alloc(16, 32));
  return `scoped:v1:${account}:${Buffer.concat([Buffer.from("v10"), cipher.update(value), cipher.final()]).toString("base64")}`;
}
function store(values: Record<string, unknown> = {}, active: unknown = scope) {
  return JSON.stringify({ version: 1, "cursor-accounts": JSON.stringify({ active, accounts: { [scope]: { "cursor-access-token": encrypted(token()), "cursor-refresh-token": "SKIP-REFRESH", ...values }, [hash("other")]: { "cursor-access-token": "SKIP-OTHER" } } }), "unknown": "SKIP-ROOT" });
}
function fixture() {
  const home = mkdtempSync(join(tmpdir(), "meterusage-bot-fixture-")); roots.push(home);
  const directory = join(home, "Library/Application Support/Grok Bot"); mkdirSync(directory, { recursive: true });
  const path = join(directory, "sand-secrets.json"); writeFileSync(path, store());
  return { home, directory, path };
}
async function setup() {
  const f = fixture(), saved = new Map<string, string>();
  const command = vi.fn<Command>(async (binary, args, options) => {
    options?.signal?.throwIfAborted();
    if (binary === "/fixture/helper") { expect(args[0]).toBe("--grok-bot"); expect(options?.maxBytes).toBe(4096); return password; }
    if (binary !== "/usr/bin/defaults") throw new Error("Forbidden command");
    if (args[0] === "write") { saved.set(args[2], args[4]); return ""; }
    if (!saved.has(args[2])) throw new Error("Absent synthetic preference");
    return args[0] === "read-type" ? args[2] === "showProviderGrok" ? "boolean" : "string" : saved.get(args[2])!;
  });
  const launch = { home: f.home, data: join(f.home, "app-data"), env: {}, demo: false, candidate: true };
  const prefs = await Preferences.load(launch, command);
  let handler: GrokBotRPC = async () => paid;
  const rpc = vi.fn<GrokBotRPC>((...args) => handler(...args));
  const connections = new DesktopConnections(launch, prefs, "/fixture/helper", () => {}, command, async () => { throw new Error("Forbidden legacy HTTP"); }, () => now, undefined, rpc);
  const connect = () => connections.connect("grok", async () => { throw new Error("Forbidden browser"); }, async () => true);
  return { ...f, launch, prefs, connections, command, rpc, connect, saved, handler: (h: GrokBotRPC) => { handler = h; } };
}
beforeEach(() => vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("Forbidden live network"); })));
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); vi.unstubAllGlobals(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
it("decrypts only active scoped token/team and hashes full subject and team", () => {
  const values = grokBotCredential(store(), password, now);
  expect(values.token).toBe(token()); expect(values.identity).toMatch(/^[a-f\d]{64}$/); expect(values.team).toBeUndefined();
  const team = grokBotCredential(store({ "cursor-selected-team-id": encrypted("0") }), password, now);
  expect(team.team).toBe("0"); expect(team.identity).not.toBe(values.identity);
  const parsed: string[] = [], parse = JSON.parse;
  vi.spyOn(JSON, "parse").mockImplementation((...args) => { parsed.push(args[0]); return parse(...args); });
  grokBotCredential(store(), password, now);
  expect(parsed).not.toContain('"SKIP-REFRESH"'); expect(parsed).not.toContain('"SKIP-OTHER"'); expect(parsed).not.toContain('"SKIP-ROOT"'); expect(parsed).not.toContain('"SKIP-JWT"');
  expect(JSON.stringify({ identity: values.identity })).not.toContain(subject);
});
it.each(["legacy", "plaintext", "scope", "version", "cipher", "wrong-key", "subject", "expired", "missing", "null-active", "team-invalid", "team-scope"])('rejects %s credential ambiguity', kind => {
  let raw = store(), key = password;
  if (kind === "legacy") raw = store({ "cursor-access-token": encrypted(token()).split(":").at(-1) });
  if (kind === "plaintext") raw = store({ "cursor-access-token": "plaintext:v1:" + token() });
  if (kind === "scope") raw = store({ "cursor-access-token": encrypted(token(), hash("other")) });
  if (kind === "version") raw = raw.replace('"version":1', '"version":2');
  if (kind === "cipher") raw = store({ "cursor-access-token": `scoped:v1:${scope}:${Buffer.from("v11unsupported").toString("base64")}` });
  if (kind === "wrong-key") key = "wrong fixture";
  if (kind === "subject") raw = store({ "cursor-access-token": encrypted(token("fixture-bot-account")) });
  if (kind === "expired") raw = store({ "cursor-access-token": encrypted(token(subject, now / 1000 + 60)) });
  if (kind === "missing") raw = store({ "cursor-access-token": null });
  if (kind === "null-active") raw = store({}, null);
  if (kind === "team-invalid") raw = store({ "cursor-selected-team-id": encrypted("9007199254740992") });
  if (kind === "team-scope") raw = store({ "cursor-selected-team-id": encrypted("1", hash("other")) });
  expect(() => grokBotCredential(raw, key, now)).toThrow("Not signed in");
});
it("rejects duplicate keys including escaped and unselected keys without changing scanner defaults", () => {
  const raws = ['{"version":1,"version":1}', '{"version":1,"\\u0076ersion":1}', '{"skip":{"a":1,"a":2}}'];
  for (const raw of raws) expect(() => selectJSON(raw, { version: true }, undefined, true)).toThrow();
  expect(selectJSON('{"version":1,"version":2}', { version: true })).toEqual({ version: 2 });
  const accounts = JSON.stringify({ active: scope, accounts: { [scope]: { "cursor-access-token": encrypted(token()) } } }).replace('"active":', '"active":null,"active":');
  expect(() => grokBotCredential(JSON.stringify({ version: 1, "cursor-accounts": accounts }), password, now)).toThrow();
  for (const raw of ["{", "[]", store().slice(0, -1), " ".repeat(4 * 1048576 + 1)]) expect(() => grokBotCredential(raw, password, now)).toThrow();
});
it("reads bounded stable files and fixed Keychain mode without changing store bytes", async () => {
  const f = await setup(), before = readFileSync(f.path), names = readdirSync(f.directory), guard = vi.fn();
  const c = await readGrokBotCredential(f.home, "/fixture/helper", f.command, now, true, new AbortController().signal, guard);
  expect(c.identity).toBe(grokBotCredential(store(), password, now).identity); expect(readFileSync(f.path)).toEqual(before); expect(readdirSync(f.directory)).toEqual(names);
  expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper").map(c => c[1])).toEqual([["--grok-bot", "--allow-ui"]]);
});
it.each(["symlink", "parent-symlink", "replace", "helper-fail", "helper-rotated", "cancel-helper"])('rejects %s before exposing credentials', async kind => {
  const f = fixture(), controller = new AbortController();
  if (kind === "symlink") { renameSync(f.path, f.path + ".old"); symlinkSync(f.path + ".old", f.path); }
  if (kind === "parent-symlink") { renameSync(f.directory, f.directory + ".old"); symlinkSync(f.directory + ".old", f.directory); }
  const command = vi.fn<Command>(async () => {
    if (kind === "replace") { writeFileSync(f.path + ".new", store()); renameSync(f.path + ".new", f.path); }
    if (kind === "helper-fail") throw new Error("SKIP-ERROR");
    if (kind === "cancel-helper") controller.abort();
    return kind === "helper-rotated" ? "rotated" : password;
  });
  await expect(readGrokBotCredential(f.home, "helper", command, now, false, controller.signal, () => {})).rejects.toMatchObject({ code: "notSignedIn" });
  if (kind.includes("symlink")) expect(command).not.toHaveBeenCalled();
});
it("keeps measured zero, trial expiry and reported reset distinct without invented cadence", () => {
  const q = grokBotQuota(paid, now); expect(q.windows[0]).toEqual({ label: "Grok Bot Desktop", usedPercent: 25, resetsAt: Date.parse("2026-10-20T12:00:00Z") }); expect(JSON.stringify(q)).not.toContain("SKIP");
  expect(grokBotQuota('{"usagePercent":0,"hasNonZeroIncludedLimit":true}', now).windows[0].usedPercent).toBe(0);
  const trial = grokBotQuota('{"usagePercent":100,"includedLimitZero":true,"sandTrialExpiresAt":"2026-10-17T12:00:00Z","nextResetTimestampUtc":"2026-10-20T12:00:00Z"}', now).windows[0];
  expect(trial.label).toContain("Trial"); expect(trial.resetsAt).toBeUndefined(); expect(trial.windowDurationMins).toBeUndefined();
  for (const value of [{}, { usagePercent: 0 }, { usagePercent: 0, usesPooledEnterpriseAllowance: true, includedLimitZero: false }, { usagePercent: 0, includedLimitZero: true, hasNonZeroIncludedLimit: true }, { usagePercent: 0, includedLimitZero: true, sandTrialExpiresAt: "2026-10-16T12:00:00Z" }, { usagePercent: 101, includedLimitZero: false }, { usagePercent: -1, includedLimitZero: false }, { usagePercent: 0, includedLimitZero: false, nextResetTimestampUtc: "bad" }]) expect(() => grokBotQuota(JSON.stringify(value), now)).toThrow("No usage yet");
});
it("requests only the fixed Connect read with own headers and bounded sanitized failures", async () => {
  const fetcher = vi.fn(async () => new Response(paid)), signal = new AbortController().signal;
  expect(await grokBotTransport(fetcher)(token(), "2", signal)).toBe(paid);
  expect(fetcher.mock.calls[0]).toEqual(["https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus", expect.objectContaining({ method: "POST", body: "{}", redirect: "error", cache: "no-store", headers: { "Content-Type": "application/json", "Connect-Protocol-Version": "1", "User-Agent": "MeterUsage/0.2.41", Authorization: `Bearer ${token()}`, "x-cursor-team-id": "2" } })]);
  for (const status of [301, 302, 307, 308, 401, 403, 429, 500]) await expect(grokBotTransport(async () => new Response("SKIP", { status }))(token(), undefined, signal)).rejects.toMatchObject({ code: [401, 403].includes(status) ? "notSignedIn" : "failed" });
  const cancel = vi.fn();
  await expect(grokBotTransport(async () => new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(1048577)); }, cancel })))(token(), undefined, signal)).rejects.toThrow(); expect(cancel).toHaveBeenCalled();
  await expect(grokBotTransport(async () => new Response("", { headers: { "content-length": "1048577" } }))(token(), undefined, signal)).rejects.toThrow();
  const untouched = vi.fn(async () => new Response(paid));
  await expect(grokBotTransport(untouched)(token(), undefined, AbortSignal.abort())).rejects.toThrow(); expect(untouched).not.toHaveBeenCalled();
  await expect(grokBotTransport(untouched)(token(), "1\r\nHeader", signal)).rejects.toThrow(); expect(untouched).not.toHaveBeenCalled();
  vi.spyOn(AbortSignal, "timeout").mockImplementation(ms => { expect(ms).toBe(30000); return AbortSignal.abort(); });
  await expect(grokBotTransport(untouched)(token(), undefined, signal)).rejects.toThrow(); expect(untouched).not.toHaveBeenCalled();
});
it("requires explicit consent and persists only opaque Bot identity/source after verified allowance", async () => {
  const f = await setup(); expect(await f.connections.connect("grok", async () => {})).toBe(false); expect(await f.connections.connect("grok", async () => {}, async () => false)).toBe(false);
  expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper")).toHaveLength(0); expect(f.rpc).not.toHaveBeenCalled();
  expect(await f.connect()).toBe(true); expect(f.prefs.values.desktopGrokSource).toBe("bot"); expect(f.connections.enabled("grok")).toBe(true); expect(f.connections.state.find(c => c.provider === "grok")).toMatchObject({ source: "account", accountMethod: "bot" });
  expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper").map(c => c[1])).toEqual([["--grok-bot", "--allow-ui"], ["--grok-bot"]]);
  const source = compose(f.launch, f.prefs, { connections: f.connections }).find(s => s.slot.provider === "grok")!;
  expect(Object.keys(source).sort()).toEqual(["accountBound", "quota", "slot"]); expect((await source.quota!()).windows[0].usedPercent).toBe(25);
  for (const serialized of [JSON.stringify(projectSettings(f.prefs.values, [], f.home)), JSON.stringify([...f.saved]), JSON.stringify(f.connections.state)]) expect(serialized).not.toMatch(/fixture|SKIP|Bearer|scoped:|safe-storage/);
  expect(JSON.stringify(projectSettings(f.prefs.values, [], f.home))).not.toContain(f.prefs.values.desktopGrokIdentity as string);
  const reloaded = await Preferences.load(f.launch, f.command); expect(reloaded.values.desktopGrokSource).toBe("bot");
  await f.connections.disconnect("grok"); await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  await f.connections.useLocal("grok"); expect(f.prefs.values.desktopGrokIdentity).toBe("");
});
it.each(["team", "account", "same-account-store", "remove", "cancel", "disconnect", "local", "stop"])('rejects late Bot connect after %s without revoked private rereads', async action => {
  const f = await setup(); let release!: (raw: string) => void, ready!: () => void; const waiting = new Promise<void>(r => { ready = r; });
  f.handler(async () => new Promise<string>(r => { release = r; ready(); }));
  const connecting = f.connect(), failure = expect(connecting).rejects.toThrow("Could not connect Grok Bot Desktop"); await waiting;
  let cleanup: Promise<unknown> | undefined;
  if (action === "team") writeFileSync(f.path, store({ "cursor-selected-team-id": encrypted("1") }));
  if (action === "account") writeFileSync(f.path, store({}, hash("other")));
  if (action === "remove") rmSync(f.path);
  if (action === "same-account-store") writeFileSync(f.path, store({ "cursor-access-token": encrypted(token(subject, now / 1000 + 7200)) }));
  if (action === "cancel") f.connections.cancel("grok");
  if (action === "disconnect") cleanup = f.connections.disconnect("grok");
  if (action === "local") cleanup = f.connections.useLocal("grok");
  if (action === "stop") cleanup = f.connections.stop();
  const reads = f.command.mock.calls.filter(c => c[0] === "/fixture/helper").length;
  release(paid); await failure; await cleanup;
  if (["cancel", "disconnect", "local", "stop"].includes(action)) expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper")).toHaveLength(reads);
  expect(f.connections.enabled("grok")).toBe(false); expect(f.prefs.values.desktopGrokIdentity).not.toMatch(/^[a-f\d]{64}$/);
});
it.each(["disconnect", "local", "abort", "team", "reconnect", "stop"])('rejects stale Bot quota after %s', async action => {
  const f = await setup(); await f.connect(); let release!: (raw: string) => void, ready!: () => void; const waiting = new Promise<void>(r => { ready = r; });
  f.handler(async () => new Promise<string>(r => { release = r; ready(); }));
  const controller = new AbortController(), reading = f.connections.quota("grok", controller.signal), failure = expect(reading).rejects.toThrow(); await waiting;
  if (action === "disconnect" || action === "reconnect") await f.connections.disconnect("grok");
  if (action === "local") await f.connections.useLocal("grok");
  if (action === "abort") controller.abort();
  if (action === "stop") await f.connections.stop();
  if (action === "reconnect") { f.handler(async () => paid); await f.connect(); }
  if (action === "team") writeFileSync(f.path, store({ "cursor-selected-team-id": encrypted("1") }));
  const reads = f.command.mock.calls.filter(c => c[0] === "/fixture/helper").length; release(paid); await failure;
  if (action !== "team") expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper")).toHaveLength(reads);
});
it.each(["desktopGrokSource", "desktopGrokIdentity", "showProviderGrok", "cancel-save"])('rolls back %s failure and source metadata without leaving consent enabled', async stage => {
  const f = await setup(), original = f.prefs.set.bind(f.prefs); let failed = false;
  vi.spyOn(f.prefs, "set").mockImplementation(async (key, value) => {
    if (key === stage && !failed) { failed = true; throw new Error("SKIP-RAW-ERROR"); }
    await original(key, value); if (stage === "cancel-save" && key === "desktopGrokIdentity" && value !== "off") f.connections.cancel("grok");
  });
  await expect(f.connect()).rejects.toThrow("Could not connect Grok Bot Desktop"); expect(f.connections.enabled("grok")).toBe(false); expect(f.prefs.values.desktopGrokSource).toBe("cursor");
});
it("checks guard before every private read, and cancellation during helper prevents publication", async () => {
  const f = fixture(), controller = new AbortController(), guard = vi.fn(() => { throw new Error("Revoked consent"); }), command = vi.fn<Command>(async () => password);
  await expect(readGrokBotCredential(f.home, "helper", command, now, false, controller.signal, guard)).rejects.toThrow(); expect(command).not.toHaveBeenCalled();
  const c = await setup(); c.command.mockImplementation(async binary => { if (binary === "/fixture/helper") { c.connections.cancel("grok"); return password; } throw new Error("Absent preference"); });
  await expect(c.connect()).rejects.toThrow(); expect(c.rpc).not.toHaveBeenCalled();
});
it("preserves Claude's default fixed helper pair and denies restricted profiles before Bot reads", async () => {
  const source = readFileSync(new URL("../Scripts/electron/desktop-keychain.swift", import.meta.url), "utf8");
  expect(source).toContain('grok ? "Grok Bot Safe Storage" : "Claude Safe Storage"'); expect(source).toContain('grok ? "Grok Bot" : "Claude Key"'); expect(source).not.toContain("SecItemAdd");
  const f = await setup();
  for (const restricted of [{ demo: true }, { codexTest: true }, { claudeTest: true }]) {
    const c = new DesktopConnections({ ...f.launch, ...restricted }, f.prefs, "/fixture/helper", () => {}, f.command, undefined, () => now, undefined, f.rpc);
    const consent = vi.fn(async () => true); await expect(c.connect("grok", async () => {}, consent)).rejects.toThrow(); expect(consent).not.toHaveBeenCalled();
  }
  expect(f.rpc).not.toHaveBeenCalled(); expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper")).toHaveLength(0);
});

it("rejects oversized files and a swapped inode before helper access", async () => {
  const f = fixture(), command = vi.fn<Command>(async () => password), signal = new AbortController().signal;
  writeFileSync(f.path, " ".repeat(4 * 1048576 + 1));
  await expect(readGrokBotCredential(f.home, "helper", command, now, false, signal, () => {})).rejects.toThrow(); expect(command).not.toHaveBeenCalled();
  writeFileSync(f.path, store()); writeFileSync(f.path + ".other", store({ "cursor-selected-team-id": encrypted("1") }));
  let checks = 0;
  await expect(readGrokBotCredential(f.home, "helper", command, now, false, signal, () => {
    if (++checks === 2) { renameSync(f.path, f.path + ".original"); renameSync(f.path + ".other", f.path); }
  })).rejects.toThrow(); expect(command).not.toHaveBeenCalled();
});
it("rejects JWT expiry overflow and invalid calendar resets", () => {
  expect(() => grokBotCredential(store({ "cursor-access-token": encrypted(token(subject, 1e308)) }), password, now)).toThrow();
  expect(() => grokBotQuota('{"usagePercent":0,"includedLimitZero":false,"nextResetTimestampUtc":"2027-02-30T12:00:00Z"}', now)).toThrow();
});
it("rejects Bot expiry before HTTP and expiry during allowance", async () => {
  const f = await setup(); writeFileSync(f.path, store({ "cursor-access-token": encrypted(token(subject, now / 1000 + 60)) }));
  await expect(f.connect()).rejects.toThrow(); expect(f.rpc).not.toHaveBeenCalled();
  writeFileSync(f.path, store()); let clock = now;
  const c = new DesktopConnections(f.launch, f.prefs, "/fixture/helper", () => {}, f.command, undefined, () => clock, undefined, async () => { clock += 3600000; return paid; });
  await expect(c.connect("grok", async () => {}, async () => true)).rejects.toThrow(); expect(c.enabled("grok")).toBe(false);
});
it("rechecks identity on transport failure and clears account allowance after a team switch", async () => {
  const f = await setup(); await f.connect(); f.rpc.mockClear();
  f.handler(async () => { throw new Unavailable("offline"); });
  const before = f.command.mock.calls.filter(c => c[0] === "/fixture/helper").length;
  await expect(f.connections.quota("grok")).rejects.toMatchObject({ code: "offline" });
  expect(f.command.mock.calls.filter(c => c[0] === "/fixture/helper")).toHaveLength(before + 2);
  writeFileSync(f.path, store({ "cursor-selected-team-id": encrypted("1") })); f.rpc.mockClear();
  await expect(f.connections.quota("grok")).rejects.toMatchObject({ code: "notSignedIn" }); expect(f.rpc).not.toHaveBeenCalled();
});

it("does not save a Bot connection when quota is unavailable", async () => {
  const f = await setup(); f.handler(async () => "{}");
  await expect(f.connect()).rejects.toThrow("Could not connect Grok Bot Desktop");
  expect(f.connections.enabled("grok")).toBe(false); expect(f.prefs.values.desktopGrokIdentity).toBe(""); expect(f.prefs.values.desktopGrokSource).toBe("cursor");
});
