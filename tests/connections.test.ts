import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test";
import { accessSync, chmodSync, constants, existsSync, mkdtempSync, mkdirSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createCipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { DatabaseSync } from "node:sqlite";
import { DesktopConnections, connectCodex, codexLoginURL } from "../src/main/connections";
import { desktopCredential, desktopQuota, readDesktopCredential } from "../src/main/providers/claude-desktop";
import { Unavailable } from "../src/domain/models";
import { Preferences } from "../src/main/preferences";
import { compose } from "../src/main/composition";
import { launchConfiguration } from "../src/main/launch";
import { endpoints, httpTransport, type Command, type HTTP } from "../src/main/providers/transport";
import * as transport from "../src/main/providers/transport";
import { parseRequest, projectSettings } from "../src/main/ipc";

const { roots } = vi.hoisted(() => ({ roots: [] as string[] }));
vi.mock("node:fs", async importOriginal => {
  const actual = await importOriginal<typeof import("node:fs")>();
  return { ...actual, accessSync: vi.fn<typeof actual.accessSync>((path, mode) => {
    if (typeof path !== "string" || !roots.some(root => path.startsWith(root + "/"))) throw new Error("Non-fixture executable discovery");
    return actual.accessSync(path, mode);
  }) };
});
vi.mock("node:child_process", async importOriginal => {
  const actual = await importOriginal<typeof import("node:child_process")>();
  return { ...actual, spawn: vi.fn((...args: Parameters<typeof actual.spawn>) => {
    if (!roots.some(root => args[0].startsWith(root + "/"))) throw new Error("Non-fixture provider process");
    return actual.spawn(...args);
  }) };
});
const temp = () => { const root = mkdtempSync(join(tmpdir(), "meterusage-connection-fixture-")); roots.push(root); return root; };
const realHTTPTransport = httpTransport;
beforeEach(() => {
  vi.spyOn(transport, "runCommand").mockRejectedValue(new Error("Unexpected native command"));
  vi.spyOn(transport, "cliPath").mockImplementation((name, _home, env) => {
    const root = roots.find(root => env.PATH === root);
    if (!root || name !== "codex") throw new Error("Unexpected provider process");
    return join(root, name);
  });
  vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("Unexpected network request"); }));
  vi.spyOn(transport, "httpTransport").mockImplementation(fetcher => realHTTPTransport(fetcher ?? fetch));
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const now = Date.parse("2026-10-07T12:00:00Z"), account = "11111111-1111-1111-1111-111111111111", org = "22222222-2222-2222-2222-222222222222", client = "33333333-3333-3333-3333-333333333333";
const password = "synthetic-safe-storage-password";
function encrypt(raw: string | Buffer) {
  const cipher = createCipheriv("aes-128-cbc", pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1"), Buffer.alloc(16, 32));
  return Buffer.concat([Buffer.from("v10"), cipher.update(raw), cipher.final()]);
}
const cacheKey = (owner = account) => `acct:${owner}|${client}:${org}:https://api.anthropic.com:user:profile user:inference`;
function config(entries: Record<string, unknown>, owner = account) {
  return JSON.stringify({ lastKnownAccountUuid: owner, "oauth:tokenCacheV2": encrypt(JSON.stringify(entries)).toString("base64"), privateMetadata: "OMIT_PRIVATE_METADATA" });
}
const entry = (token = "synthetic-access-one", expiresAt = now + 3600000) => ({ token, expiresAt, refreshToken: "OMIT_REFRESH_TOKEN" });
function desktop(home: string, owner = account, token = "synthetic-access-one") {
  const root = join(home, "Library/Application Support/Claude"); mkdirSync(root, { recursive: true });
  writeFileSync(join(root, "config.json"), config({ [cacheKey(owner)]: entry(token) }, owner));
  const db = new DatabaseSync(join(root, "Cookies"));
  try {
    db.exec("CREATE TABLE IF NOT EXISTS cookies (name TEXT, host_key TEXT, value TEXT, encrypted_value BLOB, last_update_utc INTEGER); DELETE FROM cookies;");
    const host = ".claude.ai", plain = Buffer.concat([createHash("sha256").update(host).digest(), Buffer.from(org)]);
    db.prepare("INSERT INTO cookies VALUES (?, ?, ?, ?, ?)").run("lastActiveOrg", host, "", encrypt(plain), 1);
  } finally { db.close(); }
}
async function prefs(home = temp(), demo = false) {
  const launch = launchConfiguration(demo ? ["--demo"] : [], {}, home);
  const preferences = await Preferences.load(launch, async () => "");
  return { launch, preferences };
}
function fakeCodex(root: string, failure: boolean | "wait" = false, logoutFailure: boolean | "wait" = false, reset = false) {
  const binary = join(root, "codex");
  writeFileSync(binary, `#!${process.execPath}\nconst fs = require('node:fs'), path = require('node:path'), rl = require('node:readline').createInterface({input:process.stdin});
if (JSON.stringify(process.argv.slice(-3)) !== JSON.stringify(['app-server','--listen','stdio://'])) process.exit(64);
const send = m => process.stdout.write(JSON.stringify(m)+'\\n');
rl.on('line', line => { const r = JSON.parse(line);
fs.appendFileSync(path.join(process.env.CODEX_HOME,'requests'), r.method+'\\n');
if (r.method==='initialize') send({id:r.id, result:{}});
if (r.method==='config/read') send({id:r.id,result:{config:{cli_auth_credentials_store:'keyring'}}});
if (r.method==='account/login/start') {
${failure === true ? "send({id:r.id,error:{code:-1,message:'OMIT_RAW_AUTH_ERROR'}});" : (failure === "wait" ? "" : "send({method:'account/login/completed',params:{loginId:'fixture-login',success:true}});") + "send({id:r.id,result:{type:'chatgpt',loginId:'fixture-login',authUrl:'https://auth.openai.com/authorize?state=fixture'}});"}
}

if (r.method==='account/rateLimits/read') send({id:r.id,result:{rateLimits:{primary:{usedPercent:25,windowDurationMins:300}}, ${reset ? "rateLimitResetCredits:{availableCount:1,credits:[{id:'fixture-credit',title:'Full reset',status:'available'}]}" : ""}}});
if (r.method==='account/rateLimitResetCredit/consume') { fs.writeFileSync(path.join(process.env.CODEX_HOME,'reset-request'),JSON.stringify(r.params)); send({id:r.id,result:{outcome:'reset'}}); }
if (r.method==='account/logout') { ${logoutFailure === "wait" ? "" : `send(${logoutFailure ? "{id:r.id,error:{code:-1}}" : "{id:r.id,result:{}}"});`} }
});\n`);
  chmodSync(binary, 0o755); return binary;
}
function savedPreferences(): Command {
  const stored = new Map<string, { type: string; value: string }>();
  return async (_binary, args) => {
    const [operation, , key, type, value] = args;
    if (operation === "write") { stored.set(key, { type: type === "-bool" ? "boolean" : "string", value }); return ""; }
    const saved = stored.get(key); if (!saved) throw new Error("Absent fixture preference");
    return operation === "read-type" ? saved.type : saved.value;
  };
}

it("allows only fixed provider connection requests and approved HTTPS login hosts", () => {
  for (const provider of ["codex", "claude", "antigravity", "grok"]) expect(parseRequest({ action: "connect", provider })).toEqual({ action: "connect", provider });
  for (const raw of [{ action: "connect", provider: "claude", path: "/tmp" }, { action: "connect", provider: "other" }, { action: "setPreference", key: "desktopClaudeIdentity", value: "off" }]) expect(() => parseRequest(raw)).toThrow();
  expect(codexLoginURL("https://auth.openai.com/authorize?state=fixture")).toContain("auth.openai.com");
  for (const raw of ["http://auth.openai.com", "https://auth.openai.com.evil.invalid", "https://user@chatgpt.com", "https://chatgpt.com:444", "file:///tmp"]) expect(() => codexLoginURL(raw)).toThrow();
});

it("disables a cancelled Codex login even when logout fails and retains only its cleanup profile", async () => {
  const root = temp(); fakeCodex(root, "wait", true);
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let opened!: () => void; const ready = new Promise<void>(resolve => { opened = resolve; });
  const pending = connections.connect("codex", async () => { opened(); }); await ready;
  const id = preferences.values.desktopCodexCleanup || preferences.values.desktopCodexConnection;
  connections.cancel("codex"); await expect(pending).rejects.toThrow("Could not clear");
  expect(connections.enabled("codex")).toBe(false);
  expect(preferences.values.desktopCodexConnection).toBe("off");
  expect(preferences.values.desktopCodexCleanup).toBe(id);
  expect(connections.state.find(s => s.provider === "codex")?.status).toBe("failed");
  await expect(connections.quota("codex")).rejects.toMatchObject({ code: "notSignedIn" });
  await expect(connections.connect("codex", async () => {})).rejects.toThrow("Could not clear");
});

it("disables a connected Codex account before failed disconnect cleanup", async () => {
  const root = temp(); fakeCodex(root, false, true);
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  await connections.connect("codex", async () => {});
  const id = preferences.values.desktopCodexConnection;
  await expect(connections.disconnect("codex")).rejects.toThrow("Could not disconnect");
  expect(connections.enabled("codex")).toBe(false);
  expect(preferences.values.desktopCodexConnection).toBe("off");
  expect(preferences.values.desktopCodexCleanup).toBe(id);
  expect(connections.state.find(s => s.provider === "codex")?.status).toBe("failed");
  await expect(connections.quota("codex")).rejects.toMatchObject({ code: "notSignedIn" });
});

it("publishes CLI versus account choice without exposing saved identities", async () => {
  const { launch, preferences } = await prefs();
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  expect(connections.state).toEqual([
    { provider: "codex", status: "disconnected", source: "cli", localAvailable: true },
    { provider: "claude", status: "disconnected", source: "cli", localAvailable: true },
    { provider: "antigravity", status: "disconnected", source: "cli", localAvailable: true },
    { provider: "grok", status: "disconnected", source: "cli", localAvailable: true },
  ]);
  preferences.values.desktopCodexConnection = "off"; preferences.values.desktopClaudeIdentity = "a".repeat(64);
  expect(connections.state.map(s => s.source)).toEqual(["account", "account", "cli", "cli"]);
  expect(JSON.stringify(connections.state)).not.toContain("a".repeat(64));
});

it.each(["connected", "off", "failed"])("switches %s Codex to CLI, rebuilds sources and persists the choice", async initial => {
  const root = temp(); fakeCodex(root, false, initial === "failed");
  const launch = launchConfiguration([], { PATH: root }, root), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  if (initial === "off") await connections.disconnect("codex");
  else await connections.connect("codex", async () => {});
  const profile = String(preferences.values.desktopCodexConnection);
  if (initial === "failed") {
    await expect(connections.disconnect("codex")).rejects.toThrow("Could not disconnect Codex");
    fakeCodex(root);
  }
  expect(connections.state.find(s => s.provider === "codex")).toMatchObject({ source: "account", status: initial === "off" ? "disconnected" : initial });
  const old = compose(launch, preferences, { connections }).find(s => s.slot.provider === "codex")!;
  expect(old.accountBound).toBe(true); expect(old.activity).toBeUndefined();
  await preferences.set("showProviderCodex", false);
  await connections.useLocal("codex");
  expect(preferences.values).toMatchObject({ desktopCodexConnection: "", desktopCodexCleanup: "", showProviderCodex: true });
  expect(connections.state.find(s => s.provider === "codex")).toEqual({ provider: "codex", status: "disconnected", source: "cli", localAvailable: true });
  await expect(old.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  const local = compose(launch, preferences, { connections }).find(s => s.slot.provider === "codex")!;
  expect(local.accountBound).toBeUndefined(); expect(local.accountActivity).toBeUndefined(); expect(local.activity).toBeTypeOf("function");
  const restored = await Preferences.load(launch, command), restart = new DesktopConnections(launch, restored, "/not-a-helper", () => {});
  expect(restored.values).toMatchObject({ desktopCodexConnection: "", desktopCodexCleanup: "", showProviderCodex: true });
  expect(restart.state.find(s => s.provider === "codex")?.source).toBe("cli");
  expect(compose(launch, restored, { connections: restart }).find(s => s.slot.provider === "codex")!.activity).toBeTypeOf("function");
  const processes = vi.mocked(spawn).mock.calls.length;
  await connections.useLocal("codex"); expect(vi.mocked(spawn)).toHaveBeenCalledTimes(processes);
  if (initial !== "off") expect(readFileSync(join(launch.data, "connections/codex", profile, "requests"), "utf8").match(/account\/logout/g)).toHaveLength(initial === "failed" ? 2 : 1);
});

it.each(["connected", "off", "failed"])("switches %s Claude to CLI without reading or modifying Desktop auth", async initial => {
  const home = temp(), launch = launchConfiguration([], {}, home), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  desktop(home);
  const root = join(home, "Library/Application Support/Claude"), before = ["config.json", "Cookies"].map(name => readFileSync(join(root, name)));
  const helper = vi.fn<Command>(async () => password), http = vi.fn<HTTP>(async () => '{"five_hour":{"utilization":25}}');
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, helper, http, () => now);
  if (initial === "off") await connections.disconnect("claude");
  else if (initial === "failed") {
    await preferences.set("desktopClaudeIdentity", "off");
    helper.mockRejectedValueOnce(new Error("OMIT_PRIVATE_AUTH"));
    await expect(connections.connect("claude", async () => {}, async () => true)).rejects.toThrow("Could not access Claude Desktop");
  } else await connections.connect("claude", async () => {}, async () => true);
  expect(connections.state.find(s => s.provider === "claude")).toMatchObject({ source: "account", status: initial === "off" ? "disconnected" : initial });
  const old = compose(launch, preferences, { connections }).find(s => s.slot.provider === "claude")!;
  const helperCalls = helper.mock.calls.length, httpCalls = http.mock.calls.length;
  await preferences.set("showProviderClaude", false); await connections.useLocal("claude");
  expect(preferences.values).toMatchObject({ desktopClaudeIdentity: "", showProviderClaude: true });
  await expect(old.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  expect(helper).toHaveBeenCalledTimes(helperCalls); expect(http).toHaveBeenCalledTimes(httpCalls);
  const local = compose(launch, preferences, { connections }).find(s => s.slot.provider === "claude")!;
  expect(local.accountBound).toBeUndefined(); expect(local.activity).toBeTypeOf("function"); expect(local.plan).toBeTypeOf("function");
  const restored = await Preferences.load(launch, command), restart = new DesktopConnections(launch, restored, "/synthetic/helper", () => {});
  expect(restored.values).toMatchObject({ desktopClaudeIdentity: "", showProviderClaude: true });
  expect(restart.state.find(s => s.provider === "claude")?.source).toBe("cli");
  for (const [i, name] of ["config.json", "Cookies"].entries()) expect(readFileSync(join(root, name))).toEqual(before[i]);
  expect(JSON.stringify(connections.state)).not.toMatch(/synthetic-access|11111111|22222222|OMIT/);
});

it("keeps failed CLI switch cleanup fail-closed across reconstruction", async () => {
  const root = temp(); fakeCodex(root, false, true);
  const launch = launchConfiguration([], { PATH: root }, root), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  await connections.connect("codex", async () => {}); const profile = preferences.values.desktopCodexConnection;
  await expect(connections.useLocal("codex")).rejects.toThrow("Could not disconnect Codex");
  expect(preferences.values).toMatchObject({ desktopCodexConnection: "off", desktopCodexCleanup: profile });
  expect(connections.state.find(s => s.provider === "codex")).toMatchObject({ source: "account", status: "failed" });
  const restored = await Preferences.load(launch, command), restart = new DesktopConnections(launch, restored, "/not-a-helper", () => {});
  expect(restart.enabled("codex")).toBe(false);
  const source = compose(launch, restored, { connections: restart }).find(s => s.slot.provider === "codex")!;
  expect(source.activity).toBeUndefined(); await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
});

it.each(["cleanup-marker", "disable", "cleanup-clear", "visibility", "selection"])("keeps a failed %s preference write in account mode", async stage => {
  const root = temp(); fakeCodex(root);
  const launch = launchConfiguration([], { PATH: root }, root), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  await preferences.set("desktopCodexConnection", client); await preferences.set("showProviderCodex", false);
  const set = preferences.set.bind(preferences);
  vi.spyOn(preferences, "set").mockImplementation((key, value) => {
    if (stage === "cleanup-marker" && key === "desktopCodexCleanup" && value === client || stage === "disable" && key === "desktopCodexConnection" && value === "off" || stage === "cleanup-clear" && key === "desktopCodexCleanup" && value === "" || stage === "visibility" && key === "showProviderCodex" || stage === "selection" && key === "desktopCodexConnection" && value === "") return Promise.reject(new Error("OMIT_PRIVATE_PREF_ERROR"));
    return set(key, value);
  });
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  await expect(connections.useLocal("codex")).rejects.toThrow("Could not disconnect Codex");
  expect(preferences.values.desktopCodexConnection).toBe("off");
  expect(connections.state.find(s => s.provider === "codex")).toMatchObject({ source: "account", status: "failed" });
  if (stage !== "cleanup-marker") {
    const restored = await Preferences.load(launch, command), restart = new DesktopConnections(launch, restored, "/not-a-helper", () => {});
    expect(restart.enabled("codex")).toBe(false); expect(restart.state.find(s => s.provider === "codex")?.source).toBe("account");
  }
});

it.each(["complete", "cancel", "stop"])("holds the mutation lock through CLI cleanup and handles %s", async outcome => {
  const root = temp(); fakeCodex(root);
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, savedPreferences());
  await preferences.set("desktopCodexConnection", client);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let finishCleanup!: (raw: string) => void;
  const rpc = vi.spyOn(transport, "codexRPC").mockImplementation(async () => new Promise(resolve => { finishCleanup = resolve; }));
  const pending = connections.useLocal("codex");
  await vi.waitFor(() => expect(rpc).toHaveBeenCalledOnce());
  expect(rpc.mock.calls[0][1].env!.CODEX_HOME).toBe(join(launch.data, "connections/codex", client));
  expect(rpc.mock.calls[0][4]).toBe("logout");
  expect(preferences.values).toMatchObject({ desktopCodexConnection: "off", desktopCodexCleanup: client });
  expect(connections.state.find(s => s.provider === "codex")).toMatchObject({ source: "account", status: "connecting" });
  await expect(connections.useLocal("codex")).rejects.toThrow("Connection unavailable");
  await expect(connections.disconnect("codex")).rejects.toThrow("Connection unavailable");
  await expect(connections.connect("codex", async () => {})).rejects.toThrow("Connection already active");
  let stopped: Promise<void> | undefined;
  if (outcome === "cancel") connections.cancel("codex");
  if (outcome === "stop") stopped = connections.stop();
  finishCleanup('{"result":{}}');
  if (outcome === "complete") { await pending; expect(preferences.values.desktopCodexConnection).toBe(""); }
  else { await expect(pending).rejects.toThrow("Could not disconnect Codex"); expect(preferences.values.desktopCodexConnection).toBe("off"); }
  await stopped;
  expect(preferences.values.desktopCodexCleanup).toBe(""); expect(rpc).toHaveBeenCalledOnce();
});

it("rolls back CLI selection if stop arrives during the final preference save", async () => {
  const { launch, preferences } = await prefs(); preferences.values.desktopClaudeIdentity = "off";
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  const set = preferences.set.bind(preferences);
  let release!: () => void; const saving = new Promise<void>(resolve => { release = resolve; });
  vi.spyOn(preferences, "set").mockImplementation(async (key, value) => { await set(key, value); if (key === "desktopClaudeIdentity" && value === "") await saving; });
  const pending = connections.useLocal("claude");
  await vi.waitFor(() => expect(preferences.values.desktopClaudeIdentity).toBe(""));
  const stopped = connections.stop(); release();
  await expect(pending).rejects.toThrow("Could not disconnect Claude Desktop"); await stopped;
  expect(preferences.values.desktopClaudeIdentity).toBe("off");
});

it("enables only existing Grok local collection without auth or cleanup", async () => {
  const { launch, preferences } = await prefs(); preferences.values.showProviderGrok = false;
  preferences.values.desktopCodexCleanup = client;
  const before = structuredClone(preferences.values), command = vi.fn<Command>(async () => { throw new Error("Forbidden helper"); }), http = vi.fn<HTTP>(async () => { throw new Error("Forbidden HTTP"); });
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {}, command, http);
  const processes = vi.mocked(spawn).mock.calls.length;
  await connections.useLocal("grok"); await connections.useLocal("grok");
  expect(preferences.values).toEqual({ ...before, showProviderGrok: true });
  expect(connections.state.find(s => s.provider === "grok")).toEqual({ provider: "grok", status: "disconnected", source: "cli", localAvailable: true });
  expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled(); expect(spawn).toHaveBeenCalledTimes(processes);
});

it.each(["demo", "codex-test", "claude-test", "stopped"])("denies CLI selection for every provider in %s mode", async mode => {
  const home = temp(), launch = launchConfiguration(mode === "demo" ? ["--demo"] : mode === "stopped" ? [] : [mode === "codex-test" ? "--codex-test-profile" : "--claude-test-profile", temp()], {}, home);
  const preferences = await Preferences.load(launch, savedPreferences()), before = structuredClone(preferences.values);
  const command = vi.fn<Command>(async () => { throw new Error("Forbidden helper"); }), http = vi.fn<HTTP>(async () => { throw new Error("Forbidden HTTP"); });
  const changed = vi.fn(), connections = new DesktopConnections(launch, preferences, "/not-a-helper", changed, command, http);
  if (mode === "stopped") await connections.stop();
  else expect(connections.state.every(s => !s.localAvailable)).toBe(true);
  const processes = vi.mocked(spawn).mock.calls.length;
  for (const provider of ["codex", "claude", "grok"] as const) await expect(connections.useLocal(provider)).rejects.toThrow();
  expect(preferences.values).toEqual(before); expect(changed).not.toHaveBeenCalled();
  expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled(); expect(spawn).toHaveBeenCalledTimes(processes);
});

it("identifies Grok when local selection cannot be saved", async () => {
  const { launch, preferences } = await prefs();
  vi.spyOn(preferences, "set").mockRejectedValueOnce(new Error("Private storage error"));
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  await expect(connections.useLocal("grok")).rejects.toThrow("Could not select Grok CLI");
});

it.each(["cancel", "stop"] as const)("restores Grok collection after %s during its selection save", async outcome => {
  const command = savedPreferences(), launch = launchConfiguration([], {}, temp());
  const preferences = await Preferences.load(launch, command);
  await preferences.set("showProviderGrok", false);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  const set = preferences.set.bind(preferences);
  let release!: () => void; const saving = new Promise<void>(resolve => { release = resolve; });
  vi.spyOn(preferences, "set").mockImplementation(async (key, value) => { await set(key, value); if (key === "showProviderGrok" && value === true) await saving; });
  const pending = connections.useLocal("grok");
  await vi.waitFor(() => expect(preferences.values.showProviderGrok).toBe(true));
  const stopped = outcome === "stop" ? connections.stop() : undefined;
  if (outcome === "cancel") connections.cancel("grok");
  release(); await expect(pending).rejects.toThrow("Could not select Grok CLI"); await stopped;
  expect(preferences.enabled("grok")).toBe(false);
  expect((await Preferences.load(launch, command)).enabled("grok")).toBe(false);
});

it("keeps Grok collection disabled in memory if cancelled selection rollback cannot save", async () => {
  const { launch, preferences } = await prefs(); preferences.values.showProviderGrok = false;
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  const set = preferences.set.bind(preferences);
  vi.spyOn(preferences, "set").mockImplementation(async (key, value) => {
    if (key === "showProviderGrok" && value === false) throw new Error("Private rollback error");
    await set(key, value); if (key === "showProviderGrok") connections.cancel("grok");
  });
  await expect(connections.useLocal("grok")).rejects.toThrow("Could not select Grok CLI");
  expect(preferences.enabled("grok")).toBe(false);
});

it("waits past the helper deadline for a queued Grok rollback before completing stop", async () => {
  const stored = savedPreferences(), launch = launchConfiguration([], {}, temp());
  let releaseSelection!: () => void, releaseQueued!: () => void, queuedStarted!: () => void, selectionStarted!: () => void;
  const selecting = new Promise<void>(resolve => { selectionStarted = resolve; });
  const selection = new Promise<void>(resolve => { releaseSelection = resolve; });
  const queued = new Promise<void>(resolve => { releaseQueued = resolve; });
  const ready = new Promise<void>(resolve => { queuedStarted = resolve; });
  const command: Command = async (binary, args, options) => {
    if (args[0] === "write" && args[2] === "showProviderGrok" && args[4] === "true") { selectionStarted(); await selection; }
    if (args[0] === "write" && args[2] === "menuBarCompactEnabled") { queuedStarted(); await queued; }
    return stored(binary, args, options);
  };
  const preferences = await Preferences.load(launch, command);
  await preferences.set("showProviderGrok", false);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  const local = connections.useLocal("grok").catch(e => e);
  await selecting;
  const other = preferences.set("menuBarCompactEnabled", false);
  let finished = false; const stopped = connections.stop(1).then(() => { finished = true; });
  releaseSelection(); await ready;
  try {
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(preferences.values.showProviderGrok).toBe(true);
    expect(finished).toBe(false);
  } finally { releaseQueued(); await other; await local; await stopped; }
  expect((await local).message).toBe("Could not select Grok CLI");
  expect(preferences.enabled("grok")).toBe(false);
  expect((await Preferences.load(launch, command)).enabled("grok")).toBe(false);
});

it("recovers retained Codex cleanup on explicit sign-in retry before enabling collection", async () => {
  const root = temp(); fakeCodex(root, "wait", true);
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let opened!: () => void; const ready = new Promise<void>(resolve => { opened = resolve; });
  const cancelled = connections.connect("codex", async () => { opened(); }); await ready;
  const oldID = String(preferences.values.desktopCodexCleanup);
  connections.cancel("codex"); await expect(cancelled).rejects.toThrow("Could not clear");
  fakeCodex(root);
  const rpc = transport.codexRPC, cleanupProfiles: string[] = [];
  vi.spyOn(transport, "codexRPC").mockImplementation(async (binary, options, creditID, configuration, operation) => {
    expect(operation).toBe("logout"); cleanupProfiles.push(options.env!.CODEX_HOME!);
    expect(connections.enabled("codex")).toBe(false);
    expect(preferences.values.desktopCodexConnection).toBe("off");
    expect(preferences.values.desktopCodexCleanup).toBe(oldID);
    await expect(connections.quota("codex")).rejects.toMatchObject({ code: "notSignedIn" });
    const raw = await rpc(binary, options, creditID, configuration, operation);
    expect(connections.enabled("codex")).toBe(false);
    return raw;
  });
  let newLoginOpened = false;
  await expect(connections.connect("codex", async () => { newLoginOpened = true; })).resolves.toBe(true);
  expect(cleanupProfiles).toEqual([join(launch.data, "connections/codex", oldID)]);
  expect(readFileSync(join(cleanupProfiles[0], "requests"), "utf8").match(/account\/logout/g)).toHaveLength(2);
  expect(newLoginOpened).toBe(true);
  expect(preferences.values.desktopCodexCleanup).toBe("");
  expect(preferences.values.desktopCodexConnection).not.toBe(oldID);
  expect(connections.enabled("codex")).toBe(true);
});

it("persists an unfinished login only for cleanup and never enables polling after a crash", async () => {
  const root = temp(); fakeCodex(root, "wait");
  const launch = launchConfiguration([], { PATH: root }, root), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let opened!: () => void; const ready = new Promise<void>(resolve => { opened = resolve; });
  const pending = connections.connect("codex", async () => { opened(); }); await ready;
  try {
    const restored = await Preferences.load(launch, command);
    const restart = new DesktopConnections(launch, restored, "/not-a-helper", () => {});
    expect(restored.values.desktopCodexCleanup).toMatch(/^[a-f\d-]{36}$/);
    expect(restored.values.desktopCodexConnection).toBe("off");
    expect(restart.enabled("codex")).toBe(false);
    await expect(restart.quota("codex")).rejects.toMatchObject({ code: "notSignedIn" });
  } finally { connections.cancel("codex"); await expect(pending).rejects.toThrow(); }
});

it("recovers only the persisted owned profile on startup without enabling collection", async () => {
  const root = temp(); fakeCodex(root);
  const launch = launchConfiguration([], { PATH: root }, root), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  // Simulate a crash between committing the active profile and clearing cleanup.
  await preferences.set("desktopCodexCleanup", client); await preferences.set("desktopCodexConnection", client);
  const restored = await Preferences.load(launch, command);
  const connections = new DesktopConnections(launch, restored, "/not-a-helper", () => {});
  expect(connections.enabled("codex")).toBe(false);
  await connections.recover();
  const saved = await Preferences.load(launch, command);
  expect(saved.values.desktopCodexCleanup).toBe(""); expect(saved.values.desktopCodexConnection).toBe("off");
  expect(connections.enabled("codex")).toBe(false);
  expect(readFileSync(join(launch.data, "connections/codex", client, "requests"), "utf8")).toBe("initialize\ninitialized\nconfig/read\naccount/logout\n");
});

it("retains failed startup cleanup across restarts while collection stays disabled", async () => {
  const root = temp(); fakeCodex(root, false, true);
  const launch = launchConfiguration([], { PATH: root }, root), command = savedPreferences(), preferences = await Preferences.load(launch, command);
  await preferences.set("desktopCodexCleanup", client); await preferences.set("desktopCodexConnection", client);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  await expect(connections.recover()).rejects.toThrow("Could not clear");
  const saved = await Preferences.load(launch, command);
  expect(saved.values.desktopCodexCleanup).toBe(client); expect(saved.values.desktopCodexConnection).toBe("off");
  expect(connections.enabled("codex")).toBe(false);
  expect(connections.state.find(s => s.provider === "codex")?.status).toBe("failed");
});

it("waits for cancelled login cleanup on stop without logging out established connections", async () => {
  const root = temp(); fakeCodex(root, "wait");
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let opened!: () => void; const ready = new Promise<void>(resolve => { opened = resolve; });
  const pending = connections.connect("codex", async () => { opened(); }).catch(() => false); await ready;
  const id = String(preferences.values.desktopCodexCleanup);
  await connections.stop();
  expect(preferences.values.desktopCodexCleanup).toBe(""); expect(preferences.values.desktopCodexConnection).toBe("off");
  expect(readFileSync(join(launch.data, "connections/codex", id, "requests"), "utf8")).toContain("account/logout");
  expect(await pending).toBe(false);
  const connectedRoot = temp(); fakeCodex(connectedRoot);
  const connectedLaunch = launchConfiguration([], { PATH: connectedRoot }, connectedRoot), connectedPrefs = await Preferences.load(connectedLaunch, async () => "");
  const established = new DesktopConnections(connectedLaunch, connectedPrefs, "/not-a-helper", () => {});
  await established.connect("codex", async () => {});
  const connectedID = String(connectedPrefs.values.desktopCodexConnection);
  await established.stop();
  expect(connectedPrefs.values.desktopCodexConnection).toBe(connectedID);
  expect(readFileSync(join(connectedLaunch.data, "connections/codex", connectedID, "requests"), "utf8")).not.toContain("account/logout");
});

it("bounds stop and retains cleanup when a logout helper does not answer", async () => {
  const root = temp(); fakeCodex(root, "wait", "wait");
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let opened!: () => void; const ready = new Promise<void>(resolve => { opened = resolve; });
  const pending = connections.connect("codex", async () => { opened(); }).catch(() => false); await ready;
  const id = preferences.values.desktopCodexCleanup, started = performance.now();
  await connections.stop(100);
  expect(performance.now() - started).toBeLessThan(1500);
  expect(preferences.values.desktopCodexConnection).toBe("off"); expect(preferences.values.desktopCodexCleanup).toBe(id);
  expect(await pending).toBe(false);
});
it("completes out-of-order official login notifications and polls only account allowance", async () => {
  const root = temp(), opened: string[] = [], binary = fakeCodex(root);
  const raw = await connectCodex(binary, { CODEX_HOME: root }, async url => { opened.push(url); });
  expect(JSON.parse(raw).result.rateLimits.primary.usedPercent).toBe(25);
  expect(opened).toEqual(["https://auth.openai.com/authorize?state=fixture"]);
  expect(readFileSync(join(root, "requests"), "utf8")).toBe("initialize\ninitialized\nconfig/read\naccount/login/start\naccount/rateLimits/read\n");
});
it("sanitizes helper failures and cancels without starting a process", async () => {
  const root = temp(), binary = fakeCodex(root, true);
  await expect(connectCodex(binary, { CODEX_HOME: root }, async () => {})).rejects.toThrow("Codex sign-in unavailable");
  const aborted = new AbortController(); aborted.abort();
  await expect(connectCodex("/not-a-helper", {}, async () => {}, aborted.signal)).rejects.toThrow("cancelled");
});
it("selects only current account/org access tokens and rejects stale, ambiguous and deleted entries", () => {
  const credential = desktopCredential(config({ [cacheKey()]: entry() }), org, password, now);
  expect(credential.token).toBe("synthetic-access-one"); expect(credential.identity).toMatch(/^[a-f\d]{64}$/);
  expect(JSON.stringify(credential)).not.toContain("OMIT");
  for (const entries of [{ [cacheKey()]: entry("expired", now) }, { [cacheKey()]: null }, { [cacheKey("44444444-4444-4444-4444-444444444444")]: entry() }, { [cacheKey()]: entry(), [cacheKey().replace(client, "55555555-5555-5555-5555-555555555555")]: entry("second") }]) {
    expect(() => desktopCredential(config(entries), org, password, now)).toThrow();
  }
  expect(() => desktopCredential(config({ [cacheKey()]: entry() }), "other-org", password, now)).toThrow();
  expect(() => desktopCredential(config({ [cacheKey()]: entry() }), org, "wrong-password", now)).toThrow();
});
it("normalizes local Claude file, SQLite, decryption, JSON and helper failures to notSignedIn", async () => {
  const home = temp();
  await expect(readDesktopCredential(home, password, now)).rejects.toMatchObject({ code: "notSignedIn" });
  for (const raw of ["{", config({ [cacheKey()]: entry() }).replace(/oauth:tokenCacheV2/, "unused")]) {
    expect(() => desktopCredential(raw, org, password, now)).toThrow("Not signed in");
  }
  expect(() => desktopCredential(config({ [cacheKey()]: entry() }), org, "wrong-password", now)).toThrow("Not signed in");
  desktop(home);
  writeFileSync(join(home, "Library/Application Support/Claude/Cookies"), "invalid synthetic sqlite");
  await expect(readDesktopCredential(home, password, now)).rejects.toMatchObject({ code: "notSignedIn" });
  const { launch, preferences } = await prefs(); desktop(launch.home);
  await preferences.set("desktopClaudeIdentity", desktopCredential(config({ [cacheKey()]: entry() }), org, password, now).identity);
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, async () => { throw new Error("OMIT_PRIVATE_HELPER_ERROR"); }, async () => { throw new Error("must not request"); }, () => now);
  await expect(connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
});

it.each(["disconnect", "replace", "local"])("does not reread Claude credentials after %s during an allowance request", async action => {
  const { launch, preferences } = await prefs(); desktop(launch.home);
  await preferences.set("desktopClaudeIdentity", desktopCredential(config({ [cacheKey()]: entry() }), org, password, now).identity);
  let release!: (raw: string) => void, started!: () => void, reads = 0;
  const response = new Promise<string>(resolve => { release = resolve; });
  const ready = new Promise<void>(resolve => { started = resolve; });
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, async () => { reads++; return password; }, async () => { started(); return response; }, () => now);
  const pending = connections.quota("claude"); await ready;
  expect(reads).toBe(1);
  if (action === "disconnect") await connections.disconnect("claude");
  else if (action === "local") await connections.useLocal("claude");
  else await preferences.set("desktopClaudeIdentity", "a".repeat(64));
  release('{"five_hour":{"utilization":25}}');
  await expect(pending).rejects.toMatchObject({ code: "notSignedIn" });
  expect(reads).toBe(1);
});

it("verifies the current Claude identity after HTTP failure and permits fallback only for that verified account", async () => {
  const { launch, preferences } = await prefs(); desktop(launch.home);
  await preferences.set("desktopClaudeIdentity", desktopCredential(config({ [cacheKey()]: entry() }), org, password, now).identity);
  let switchAccount = false, denyHelper = false, reads = 0;
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, async () => {
    reads++; if (denyHelper) throw new Error("OMIT_PRIVATE_HELPER_ERROR"); return password;
  }, async () => {
    if (switchAccount) desktop(launch.home, "66666666-6666-6666-6666-666666666666");
    throw new Unavailable("offline");
  }, () => now);
  await expect(connections.quota("claude")).rejects.toMatchObject({ code: "offline" });
  expect(reads).toBe(2);
  switchAccount = true;
  await expect(connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
  desktop(launch.home); switchAccount = false;
  const revoked = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, async () => {
    if (denyHelper) throw new Error("OMIT_PRIVATE_HELPER_ERROR"); return password;
  }, async () => { denyHelper = true; throw new Unavailable("failed", "Claude"); }, () => now);
  await expect(revoked.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
});
it.each([
  ["keychain", "Could not access Claude Desktop through macOS Keychain. Check the access prompt, then try connecting again."],
  ["cache", "Could not read Claude Desktop's account configuration."],
  ["cookies", "Could not read Claude Desktop's active organization cookie."],
  ["cookie-hash", "Could not read Claude Desktop's active organization cookie."],
  ["decrypt", "Could not decrypt Claude Desktop's sign-in cache with its Keychain entry."],
  ["selection", "Claude Desktop's cache has no current allowance token for the active account and organization."],
  ["expired", "Claude Desktop's cache has no current allowance token for the active account and organization."],
  ["ambiguous", "Claude Desktop's cache has multiple matching allowance tokens. MeterUsage cannot safely choose one."],
  ["request", "Could not read Claude account allowance. Try connecting again later."],
  ["response", "Could not read Claude account allowance. Try connecting again later."],
  ["identity", "Could not verify the same Claude Desktop account after the allowance request. Try connecting again."],
  ["identity-keychain", "Could not verify the same Claude Desktop account after the allowance request. Try connecting again."],
  ["identity-cache", "Could not verify the same Claude Desktop account after the allowance request. Try connecting again."],
  ["save-identity", "Could not save the Claude Desktop connection preferences. Try connecting again."],
  ["save-visibility", "Could not save the Claude Desktop connection preferences. Try connecting again."],
  ["save-rollback", "Could not save the Claude Desktop connection preferences. Try connecting again."],
])("reports only the fixed Claude Connect stage message for %s", async (failure, message) => {
  const home = temp(), launch = launchConfiguration([], {}, home); desktop(home);
  const privateError = `OMIT_PRIVATE_EXCEPTION response=OMIT_PRIVATE_RESPONSE token=synthetic-access-one account=${account} org=${org} path=${home}`;
  const preferences = await Preferences.load(launch, async (_binary, args) => {
    if (args[0] === "write" && (failure === "save-identity" && args[2] === "desktopClaudeIdentity" || ["save-visibility", "save-rollback"].includes(failure) && args[2] === "showProviderClaude" || failure === "save-rollback" && args[2] === "desktopClaudeIdentity" && args[4] === "off")) throw new Error(privateError);
    return "";
  });
  const root = join(home, "Library/Application Support/Claude");
  if (failure === "cache") writeFileSync(join(root, "config.json"), privateError);
  if (failure === "cookies") writeFileSync(join(root, "Cookies"), privateError);
  if (failure === "cookie-hash") {
    const db = new DatabaseSync(join(root, "Cookies"));
    try { db.prepare("UPDATE cookies SET encrypted_value = ?").run(encrypt(Buffer.concat([Buffer.alloc(32), Buffer.from(org)]))); }
    finally { db.close(); }
  }
  if (failure === "decrypt") writeFileSync(join(root, "config.json"), JSON.stringify({ lastKnownAccountUuid: account, "oauth:tokenCacheV2": Buffer.from("v10invalid").toString("base64") }));
  if (failure === "selection") writeFileSync(join(root, "config.json"), config({ [cacheKey().replace(" user:inference", "")]: entry() }));
  if (failure === "expired") writeFileSync(join(root, "config.json"), config({ [cacheKey()]: entry("synthetic-expired", now) }));
  if (failure === "ambiguous") writeFileSync(join(root, "config.json"), config({ [cacheKey()]: entry(), [cacheKey().replace(client, "55555555-5555-5555-5555-555555555555")]: entry("synthetic-second") }));
  const command = vi.fn<Command>(async (_binary, args) => {
    if (failure === "keychain" || failure === "identity-keychain" && args.length === 0) throw new Error(privateError);
    return password;
  });
  const http = vi.fn<HTTP>(async () => {
    if (failure === "request") throw new Error(privateError);
    if (failure === "response") return JSON.stringify({ five_hour: { utilization: privateError }, privateResponse: privateError });
    if (failure === "identity") desktop(home, "66666666-6666-6666-6666-666666666666");
    if (failure === "identity-cache") writeFileSync(join(root, "config.json"), privateError);
    return '{"five_hour":{"utilization":25}}';
  });
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, command, http, () => now);
  const error = await connections.connect("claude", async () => {}, async () => true).catch(error => error);
  expect(error).toBeInstanceOf(Error); expect(error.message).toBe(message);
  expect(error.message).not.toMatch(/OMIT|synthetic-access|11111111|22222222/); expect(error.message).not.toContain(home);
  expect(connections.enabled("claude")).toBe(false);
  expect(connections.state.find(s => s.provider === "claude")?.status).toBe("failed");
  expect(preferences.values.desktopClaudeIdentity).toBe(["save-visibility", "save-rollback"].includes(failure) ? "off" : "");
  const beforeRequest = ["keychain", "cache", "cookies", "cookie-hash", "decrypt", "selection", "expired", "ambiguous"].includes(failure);
  expect(command.mock.calls.map(([, args]) => args)).toEqual(beforeRequest || ["request", "response"].includes(failure) ? [["--allow-ui"]] : [["--allow-ui"], []]);
  expect(http).toHaveBeenCalledTimes(beforeRequest ? 0 : 1);
  expect(JSON.stringify(connections.state)).not.toMatch(/OMIT|synthetic-access|11111111|22222222/);
  expect(JSON.stringify(projectSettings(preferences.values, [], home))).not.toContain("desktopClaudeIdentity");
});
it.each(["consent", "keychain", "request", "identity", "save"])("keeps Claude Connect cancellation fail-closed during %s", async stage => {
  const home = temp(), launch = launchConfiguration([], {}, home); desktop(home);
  const preferences = await Preferences.load(launch, async (_binary, args) => {
    if (stage === "save" && args[0] === "write" && args[2] === "showProviderClaude") connections.cancel("claude");
    return "";
  });
  const command = vi.fn<Command>(async (_binary, args, options) => {
    if (stage === "keychain" && args.length || stage === "identity" && !args.length) connections.cancel("claude");
    options?.signal?.throwIfAborted(); return password;
  });
  const http = vi.fn<HTTP>(async () => { if (stage === "request") connections.cancel("claude"); return '{"five_hour":{"utilization":25}}'; });
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, command, http, () => now);
  await expect(connections.connect("claude", async () => {}, async () => {
    if (stage === "consent") connections.cancel("claude"); return true;
  })).rejects.toThrow("Open Claude Desktop and sign in, then try connecting again");
  expect(connections.enabled("claude")).toBe(false);
  expect(preferences.values.desktopClaudeIdentity).toBe(stage === "save" ? "off" : "");
  if (stage === "consent") expect(command).not.toHaveBeenCalled();
  if (["consent", "keychain"].includes(stage)) expect(http).not.toHaveBeenCalled();
});
it("connects Claude with consent, refreshes rotated access tokens, rejects account switches and disconnects without desktop writes", async () => {
  const { launch, preferences } = await prefs(); desktop(launch.home);
  const calls: string[][] = [], tokens: string[] = [], urls: string[] = [];
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, async (_binary, args) => { calls.push(args); return password; }, async (url, _provider, token) => { urls.push(url); tokens.push(token!); return '{"five_hour":{"utilization":25}}'; }, () => now);
  expect(await connections.connect("claude", async () => {}, async () => false)).toBe(false); expect(calls).toEqual([]);
  expect(await connections.connect("claude", async () => {}, async () => true)).toBe(true);
  expect(calls).toEqual([["--allow-ui"], []]);
  const source = compose(launch, preferences, { connections }).find(s => s.slot.provider === "claude")!;
  expect(source.activity).toBeUndefined(); expect(source.plan).toBeUndefined();
  expect((await source.quota!()).windows[0].usedPercent).toBe(25);
  desktop(launch.home, account, "synthetic-access-two"); await source.quota!(); expect(tokens.at(-1)).toBe("synthetic-access-two");
  desktop(launch.home, "66666666-6666-6666-6666-666666666666");
  await expect(source.quota!()).rejects.toThrow("Not signed in");
  const before = readFileSync(join(launch.home, "Library/Application Support/Claude/config.json"), "utf8");
  await connections.disconnect("claude"); expect(preferences.values.desktopClaudeIdentity).toBe("off");
  expect(readFileSync(join(launch.home, "Library/Application Support/Claude/config.json"), "utf8")).toBe(before);
  expect(urls.every(url => url === endpoints.claudeAllowance)).toBe(true);
  expect(JSON.stringify(connections.state)).not.toMatch(/synthetic-access|11111111|OMIT/);
  expect(JSON.stringify(projectSettings(preferences.values, [], launch.home))).not.toContain(String(preferences.values.desktopClaudeIdentity));
});
it("requires an explicit consent callback before Claude access", async () => {
  const { launch, preferences } = await prefs(); desktop(launch.home);
  const command = vi.fn<Command>(async () => password), http = vi.fn(async () => '{"five_hour":{"utilization":25}}');
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, command, http, () => now);
  expect(await connections.connect("claude", async () => {})).toBe(false);
  expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled();
  expect(connections.enabled("claude")).toBe(false); expect(preferences.values.desktopClaudeIdentity).toBe("");
});
it("blocks demo and unconsented Grok access and never falls back after a configured disconnect", async () => {
  const { launch, preferences } = await prefs(undefined, true);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {}, async () => { throw new Error("must not read"); });
  await expect(connections.connect("claude", async () => {})).rejects.toThrow("demo mode");
  await expect(connections.disconnect("codex")).rejects.toThrow("demo mode");
  const live = await prefs(), real = new DesktopConnections(live.launch, live.preferences, "/not-a-helper", () => {});
  expect(await real.connect("grok", async () => {})).toBe(false);
  await real.disconnect("codex");
  const source = compose(live.launch, live.preferences, { connections: real }).find(s => s.slot.provider === "codex")!;
  expect(source.activity).toBeUndefined(); expect(source.consumeReset).toBeUndefined();
  await expect(source.quota!()).rejects.toThrow("Not signed in");
});
it("denies non-Codex connections and quota in a live test profile even with persisted identity", async () => {
  const processes = vi.mocked(spawn).mock.calls.length;
  const home = realpathSync(temp()), profile = realpathSync(temp()), launch = launchConfiguration(["--codex-test-profile", profile], {}, home);
  const command = vi.fn<Command>(async () => { throw new Error("Forbidden helper/defaults"); });
  const http = vi.fn(async () => { throw new Error("Forbidden HTTP"); });
  const preferences = await Preferences.load(launch, command);
  preferences.values.desktopClaudeIdentity = "a".repeat(64);
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, command, http);
  const consent = vi.fn(async () => true), open = vi.fn(async () => {});
  expect(connections.enabled("claude")).toBe(false);
  expect(connections.state).toEqual([{ provider: "codex", status: "disconnected", source: "account", localAvailable: false }, { provider: "claude", status: "unsupported", source: "account", localAvailable: false }, { provider: "antigravity", status: "unsupported", source: "cli", localAvailable: false }, { provider: "grok", status: "unsupported", source: "account", localAvailable: false }]);
  for (const provider of ["claude", "antigravity", "grok"] as const) {
    await expect(connections.connect(provider, open, consent)).rejects.toThrow("unavailable");
    await expect(connections.quota(provider)).rejects.toMatchObject({ code: "notSignedIn" });
    await expect(connections.disconnect(provider)).rejects.toThrow("unavailable");
  }
  await expect(connections.quota("codex")).rejects.toMatchObject({ code: "notSignedIn" });
  expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled(); expect(consent).not.toHaveBeenCalled(); expect(open).not.toHaveBeenCalled(); expect(spawn).toHaveBeenCalledTimes(processes);
});
it("denies non-Claude connections, quota and cleanup in a Claude test profile", async () => {
  const processes = vi.mocked(spawn).mock.calls.length;
  const home = realpathSync(temp()), profile = realpathSync(temp()), launch = launchConfiguration(["--claude-test-profile", profile], {}, home);
  const command = vi.fn<Command>(async () => { throw new Error("Forbidden helper/defaults"); });
  const http = vi.fn(async () => { throw new Error("Forbidden HTTP"); });
  const preferences = await Preferences.load(launch, command);
  preferences.values.desktopCodexConnection = client; preferences.values.desktopCodexCleanup = client;
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, command, http);
  const consent = vi.fn(async () => true), open = vi.fn(async () => {});
  expect(connections.enabled("codex")).toBe(false);
  expect(connections.state).toEqual([{ provider: "codex", status: "unsupported", source: "account", localAvailable: false }, { provider: "claude", status: "disconnected", source: "account", localAvailable: false }, { provider: "antigravity", status: "unsupported", source: "cli", localAvailable: false }, { provider: "grok", status: "unsupported", source: "account", localAvailable: false }]);
  for (const provider of ["codex", "antigravity", "grok"] as const) {
    await expect(connections.connect(provider, open, consent)).rejects.toThrow("unavailable");
    await expect(connections.quota(provider)).rejects.toMatchObject({ code: "notSignedIn" });
    await expect(connections.disconnect(provider)).rejects.toThrow("unavailable");
  }
  await connections.recover();
  await expect(connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
  expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled(); expect(consent).not.toHaveBeenCalled(); expect(open).not.toHaveBeenCalled();
  expect(transport.cliPath).not.toHaveBeenCalled(); expect(spawn).toHaveBeenCalledTimes(processes);
});
it("connects, reloads and disconnects Claude through isolated preferences and read-only Desktop fixtures", async () => {
  const processes = vi.mocked(spawn).mock.calls.length;
  const home = realpathSync(temp()), profile = realpathSync(temp()), launch = launchConfiguration(["--claude-test-profile", profile], {}, home);
  desktop(home);
  const root = join(home, "Library/Application Support/Claude"), before = ["config.json", "Cookies"].map(name => readFileSync(join(root, name)));
  const command = vi.fn<Command>(async (binary, args) => { expect(binary).toBe("/synthetic/helper"); expect([[], ["--allow-ui"]]).toContainEqual(args); return password; });
  const http = vi.fn<HTTP>(async (url, provider, token) => {
    expect(url).toBe(endpoints.claudeAllowance); expect(provider).toBe("claude"); expect(token).toBe("synthetic-access-one");
    return '{"five_hour":{"utilization":25},"seven_day":{"utilization":0}}';
  });
  const preferences = await Preferences.load(launch, command);
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, command, http, () => now);
  expect(await connections.connect("claude", async () => {}, async () => false)).toBe(false);
  expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled();
  expect(await connections.connect("claude", async () => {}, async () => true)).toBe(true);
  expect(command.mock.calls.map(([, args]) => args)).toEqual([["--allow-ui"], []]);
  await connections.stop();
  const restored = await Preferences.load(launchConfiguration(["--claude-test-profile", profile], {}, home), command);
  const restart = new DesktopConnections(launch, restored, "/synthetic/helper", () => {}, command, http, () => now);
  expect(restart.enabled("claude")).toBe(true);
  const [source] = compose(launch, restored, { connections: restart });
  expect(Object.keys(source).sort()).toEqual(["accountBound", "quota", "slot"]);
  expect((await source.quota!()).windows.map(w => w.usedPercent)).toEqual([25, 0]);
  expect(command.mock.calls.slice(2).every(([, args]) => args.length === 0)).toBe(true);
  await restart.disconnect("claude");
  expect((await Preferences.load(launch, command)).values.desktopClaudeIdentity).toBe("off");
  await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  for (const [i, name] of ["config.json", "Cookies"].entries()) expect(readFileSync(join(root, name))).toEqual(before[i]);
  expect(existsSync(join(home, "Library/Application Support/MeterUsage"))).toBe(false);
  expect(readFileSync(join(profile, "preferences.json"), "utf8")).not.toMatch(/synthetic-access|11111111|22222222|OMIT/);
  expect(transport.cliPath).not.toHaveBeenCalled(); expect(spawn).toHaveBeenCalledTimes(processes);
});
it("connects, reloads and disconnects Codex through the isolated JSON test profile and OS home helper", async () => {
  const home = realpathSync(temp()), profile = realpathSync(temp()), resources = join(home, "Applications/Codex.app/Contents/Resources");
  mkdirSync(resources, { recursive: true }); const binary = fakeCodex(resources);
  const launch = launchConfiguration(["--codex-test-profile", profile], { OPENAI_API_KEY: "OMIT_INHERITED_API_KEY", CODEX_HOME: "/foreign/codex", HOME: "/foreign/home" }, home);
  const command = vi.fn<Command>(async () => { throw new Error("Forbidden installed defaults"); });
  const preferences = await Preferences.load(launch, command);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {}, command);
  expect(await connections.connect("codex", async () => {})).toBe(true);
  const options = vi.mocked(spawn).mock.calls.at(-1)![2]!;
  expect(vi.mocked(spawn).mock.calls.at(-1)![0]).toBe(binary);
  expect(options.env).toMatchObject({ HOME: home, CODEX_HOME: join(profile, "connections/codex", String(preferences.values.desktopCodexConnection)) });
  expect(options.env).not.toHaveProperty("OPENAI_API_KEY"); expect(options.env!.CODEX_HOME).not.toBe("/foreign/codex");
  const restored = await Preferences.load(launchConfiguration(["--codex-test-profile", profile], {}, home), command);
  const restart = new DesktopConnections(launch, restored, "/not-a-helper", () => {}, command);
  expect(restart.enabled("codex")).toBe(true);
  expect((await compose(launch, restored, { connections: restart })[0].quota!()).windows[0].usedPercent).toBe(25);
  await restart.disconnect("codex");
  expect((await Preferences.load(launch, command)).values.desktopCodexConnection).toBe("off");
  await expect(compose(launch, restored, { connections: restart })[0].quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  expect(command).not.toHaveBeenCalled(); expect(transport.cliPath).not.toHaveBeenCalled(); expect(existsSync(join(home, "Library"))).toBe(false);
});
it("keeps Codex helper authentication isolated and removes only its own login on disconnect", async () => {
  const root = temp(), binary = fakeCodex(root), launch = launchConfiguration([], { PATH: root, OPENAI_API_KEY: "OMIT_INHERITED_API_KEY" }, root);
  symlinkSync(process.execPath, join(root, "node"));
  writeFileSync(binary, readFileSync(binary, "utf8").replace(`#!${process.execPath}`, "#!/usr/bin/env node"));
  const preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  expect(await connections.connect("codex", async () => {})).toBe(true);
  const env = vi.mocked(spawn).mock.calls.at(-1)![2]!.env!;
  expect(env.PATH!.split(":")).toContain("/opt/homebrew/bin");
  expect(env.PATH!.split(":")).toContain(root);
  expect(env).not.toHaveProperty("OPENAI_API_KEY");
  const id = String(preferences.values.desktopCodexConnection), profile = join(launch.data, "connections/codex", id);
  expect((await connections.quota("codex")).windows[0].usedPercent).toBe(25);
  await connections.disconnect("codex"); expect(preferences.values.desktopCodexConnection).toBe("off");
  expect(readFileSync(join(profile, "requests"), "utf8")).toContain("account/logout");
  expect(binary).toBe(join(root, "codex"));
});
it("discovers a synthetic installed Codex app without permitting a real installed helper to execute", async () => {
  const root = temp(), resources = join(root, "Applications/Codex.app/Contents/Resources");
  mkdirSync(resources, { recursive: true }); const binary = fakeCodex(resources);
  const launch = launchConfiguration([], {}, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  expect(() => accessSync("/Applications/Codex.app/Contents/Resources/codex", constants.X_OK)).toThrow("Non-fixture");
  expect(() => spawn("/Applications/Codex.app/Contents/Resources/codex", [])).toThrow("Non-fixture");
  expect(await connections.connect("codex", async () => {})).toBe(true);
  expect(vi.mocked(spawn).mock.calls.at(-1)![0]).toBe(binary);
  expect(transport.cliPath).not.toHaveBeenCalled();
});
it("uses the MeterUsage identity and bounded HTTP without provider CLI impersonation", async () => {
  const calls: RequestInit[] = [];
  const http = httpTransport(async (_url, init) => { calls.push(init!); return new Response('{"five_hour":{"used_percentage":0}}'); });
  await http(endpoints.claudeAllowance, "claude", "synthetic-access");
  expect(calls[0].redirect).toBe("error"); expect(calls[0].headers).toMatchObject({ "User-Agent": "meterusage/0.2.41", "anthropic-beta": "oauth-2025-04-20" });
});
it("retains only numeric Claude allowance windows and preserves missing versus measured zero", () => {
  const q = desktopQuota('{"five_hour":{"utilization":0,"resets_at":"2026-10-07T13:00:00Z"},"seven_day":null,"metadata":"OMIT_METADATA"}', now);
  expect(q.windows).toHaveLength(1); expect(q.windows[0].usedPercent).toBe(0); expect(JSON.stringify(q)).not.toContain("OMIT");
  for (const raw of ['{}', '{"five_hour":{"utilization":-1}}', '{"five_hour":{"utilization":101}}', '{"five_hour":{"utilization":0,"resets_at":"wrong"}}']) expect(() => desktopQuota(raw, now)).toThrow();
});
it("rejects effective plaintext storage before login and cleans up an in-progress cancelled login", async () => {
  const deniedRoot = temp(), denied = fakeCodex(deniedRoot);
  writeFileSync(denied, readFileSync(denied, "utf8").replace("cli_auth_credentials_store:'keyring'", "cli_auth_credentials_store:'file'"));
  await expect(connectCodex(denied, { CODEX_HOME: deniedRoot }, async () => {})).rejects.toThrow("unavailable");
  expect(readFileSync(join(deniedRoot, "requests"), "utf8")).not.toContain("account/login/start");
  const root = temp(); fakeCodex(root, "wait");
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  let opened!: () => void; const ready = new Promise<void>(r => { opened = r; });
  const pending = connections.connect("codex", async () => { opened(); }); await ready;
  const id = String(preferences.values.desktopCodexCleanup);
  connections.cancel("codex"); await expect(pending).rejects.toThrow("try connecting again");
  expect(preferences.values.desktopCodexConnection).toBe("off");
  expect(readFileSync(join(launch.data, "connections/codex", id, "requests"), "utf8")).toContain("account/logout");
});

it("uses the existing reset RPC on a synthetic helper with keyring verification and one idempotency key", async () => {
  const root = temp(); fakeCodex(root, false, false, true);
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {});
  await connections.connect("codex", async () => {});
  const profile = String(preferences.values.desktopCodexConnection), path = join(launch.data, "connections/codex", profile);
  await expect(connections.consumeReset(profile, "fixture-credit")).resolves.toBe(true);
  const request = JSON.parse(readFileSync(join(path, "reset-request"), "utf8"));
  expect(Object.keys(request).sort()).toEqual(["creditId", "idempotencyKey"]);
  expect(request.creditId).toBe("fixture-credit"); expect(request.idempotencyKey).toMatch(/^[a-f\d-]{36}$/);
  expect(readFileSync(join(path, "requests"), "utf8").match(/account\/rateLimitResetCredit\/consume/g)).toHaveLength(1);
  expect(readFileSync(join(path, "requests"), "utf8")).toContain("config/read\naccount/rateLimitResetCredit/consume");
  rmSync(join(path, "reset-request"));
  const binary = join(root, "codex"); writeFileSync(binary, readFileSync(binary, "utf8").replace("cli_auth_credentials_store:'keyring'", "cli_auth_credentials_store:'file'"));
  await expect(connections.consumeReset(profile, "fixture-credit")).rejects.toThrow("Secure credential storage unavailable");
  expect(existsSync(join(path, "reset-request"))).toBe(false);
});


it("reads daily history for the captured managed profile and rejects late swaps, aborts and disconnects", async () => {
  const root = temp(); fakeCodex(root);
  const launch = launchConfiguration([], { PATH: root }, root), preferences = await Preferences.load(launch, async () => "");
  preferences.values.desktopCodexConnection = "11111111-1111-4111-8111-111111111111";
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {}, undefined, undefined, () => now);
  const profile = String(preferences.values.desktopCodexConnection), raw = '{"result":{"dailyUsageBuckets":[{"startDate":"2026-10-06","tokens":123}]}}';
  const rpc = vi.spyOn(transport, "codexRPC").mockResolvedValue(raw);
  expect(await connections.accountActivity(undefined, profile)).toEqual({ capturedAt: now, dailyUsageBuckets: [{ startDate: "2026-10-06", tokens: 123 }] });
  expect(rpc.mock.calls[0].slice(2)).toEqual([undefined, expect.arrayContaining(['cli_auth_credentials_store="keyring"', 'forced_login_method="chatgpt"']), "usage"]);
  expect(rpc.mock.calls[0][1].env?.CODEX_HOME).toBe(join(launch.data, "connections/codex", profile));
  for (const action of ["swap", "abort", "disconnect", "local"] as const) {
    preferences.values.desktopCodexConnection = profile;
    let finish!: (s: string) => void;
    rpc.mockImplementation(async (_binary, _options, _credit, _configuration, operation) => operation === "logout" ? '{"result":{}}' : new Promise(resolve => { finish = resolve; }));
    const controller = new AbortController(), reading = connections.accountActivity(controller.signal, profile);
    if (action === "swap") preferences.values.desktopCodexConnection = "22222222-2222-4222-8222-222222222222";
    if (action === "abort") controller.abort();
    if (action === "disconnect") await connections.disconnect("codex");
    if (action === "local") await connections.useLocal("codex");
    finish(raw); await expect(reading).rejects.toThrow();
  }
  const calls = rpc.mock.calls.length;
  await expect(connections.accountActivity()).rejects.toMatchObject({ code: "notSignedIn" });
  expect(rpc).toHaveBeenCalledTimes(calls);
});
