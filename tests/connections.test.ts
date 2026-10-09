import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test";
import { accessSync, chmodSync, constants, mkdtempSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
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
import { endpoints, httpTransport, type Command } from "../src/main/providers/transport";
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
function fakeCodex(root: string, failure: boolean | "wait" = false, logoutFailure: boolean | "wait" = false) {
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

if (r.method==='account/rateLimits/read') send({id:r.id,result:{rateLimits:{primary:{usedPercent:25,windowDurationMins:300}}}});
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
  for (const provider of ["codex", "claude", "grok"]) expect(parseRequest({ action: "connect", provider })).toEqual({ action: "connect", provider });
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

it.each(["disconnect", "replace"])("does not reread Claude credentials after %s during an allowance request", async action => {
  const { launch, preferences } = await prefs(); desktop(launch.home);
  await preferences.set("desktopClaudeIdentity", desktopCredential(config({ [cacheKey()]: entry() }), org, password, now).identity);
  let release!: (raw: string) => void, started!: () => void, reads = 0;
  const response = new Promise<string>(resolve => { release = resolve; });
  const ready = new Promise<void>(resolve => { started = resolve; });
  const connections = new DesktopConnections(launch, preferences, "/synthetic/helper", () => {}, async () => { reads++; return password; }, async () => { started(); return response; }, () => now);
  const pending = connections.quota("claude"); await ready;
  expect(reads).toBe(1);
  if (action === "disconnect") await connections.disconnect("claude");
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
it("blocks demo and unavailable Grok access and never falls back after a configured disconnect", async () => {
  const { launch, preferences } = await prefs(undefined, true);
  const connections = new DesktopConnections(launch, preferences, "/not-a-helper", () => {}, async () => { throw new Error("must not read"); });
  await expect(connections.connect("claude", async () => {})).rejects.toThrow("demo mode");
  await expect(connections.disconnect("codex")).rejects.toThrow("demo mode");
  const live = await prefs(), real = new DesktopConnections(live.launch, live.preferences, "/not-a-helper", () => {});
  await expect(real.connect("grok", async () => {})).rejects.toThrow("unavailable");
  await real.disconnect("codex");
  const source = compose(live.launch, live.preferences, { connections: real }).find(s => s.slot.provider === "codex")!;
  expect(source.activity).toBeUndefined(); expect(source.consumeReset).toBeUndefined();
  await expect(source.quota!()).rejects.toThrow("Not signed in");
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
