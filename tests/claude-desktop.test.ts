import { afterEach, beforeEach, expect, it, vi } from "vite-plus/test";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createCipheriv, createHash, pbkdf2Sync } from "node:crypto";
import { desktopCredential, readDesktopCredential, verifyDesktopAccount, claudeIdentity, desktopCookieSQL, desktopSchemaSQL } from "../src/main/providers/claude-desktop";
import { desktopHTTP } from "../src/main/native-http";
import type { session } from "electron";
import { DesktopConnections } from "../src/main/connections";
import { Preferences } from "../src/main/preferences";
import { launchConfiguration } from "../src/main/launch";
import { compose } from "../src/main/composition";
import { Coordinator } from "../src/main/coordinator";
import { saveArchive } from "../src/main/history";
import { primary, quota, window, Unavailable } from "../src/domain/models";
import { ClaudeBrowserVerification, httpTransport, endpoints, claudeUsageURL, type Command, type HTTP, type Endpoint } from "../src/main/providers/transport";
import * as transport from "../src/main/providers/transport";

const account = "11111111-1111-1111-1111-111111111111", org = "22222222-2222-2222-2222-222222222222", other = "33333333-3333-3333-3333-333333333333";
const now = Date.parse("2026-10-20T12:00:00Z"), password = "synthetic-password", identity = claudeIdentity(account, org);
const config = JSON.stringify({ lastKnownAccountUuid: account, "oauth:tokenCacheV2": "OMIT_UNRELATED_OAUTH" });
const bootstrap = (owner = account, organizations = [org]) => JSON.stringify({ account: { uuid: owner, memberships: organizations.map(uuid => ({ organization: { uuid } })), private: "OMIT" } });
function row(name = "sessionKey", value = "synthetic-session", host = ".claude.ai") {
  const cipher = createCipheriv("aes-128-cbc", pbkdf2Sync(password, "saltysalt", 1003, 16, "sha1"), Buffer.alloc(16, 32));
  const plain = Buffer.concat([createHash("sha256").update(host).digest(), Buffer.from(value)]);
  return { name, host_key: host, path: "/", is_secure: 1, is_httponly: name === "sessionKey" ? 1 : 0, expires_utc: String((BigInt(now) + 11644473600000n) * 1000n + 3600000000n), encrypted_value: Buffer.concat([Buffer.from("v10"), cipher.update(plain), cipher.final()]).toString("hex") };
}
const rows = () => [row(), row("lastActiveOrg", org)];
const store = (cookies = rows(), version = "24") => ({ version: JSON.stringify([{ version }]), cookies: JSON.stringify(cookies) });
const credential = () => desktopCredential(config, [store()], password, now);
const roots: string[] = [];
beforeEach(() => {
  vi.spyOn(transport, "runCommand").mockRejectedValue(new Error("Unexpected native command"));
  vi.stubGlobal("fetch", vi.fn(async () => { throw new Error("Unexpected live request"); }));
});
afterEach(() => { vi.restoreAllMocks(); vi.unstubAllGlobals(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
async function fixture(isolated = false) {
  const home = mkdtempSync(join(tmpdir(), "meterusage-claude-synthetic-")); roots.push(home);
  const root = join(home, "Library/Application Support/Claude"); mkdirSync(root, { recursive: true });
  writeFileSync(join(root, "config.json"), config); writeFileSync(join(root, "Cookies"), "SYNTHETIC_NOT_SQLITE");
  const launch = launchConfiguration(isolated ? ["--claude-test-profile", join(home, "test-profile")] : [], {}, home);
  const prefs = await Preferences.load(launch, async () => "");
  let cookies = rows();
  const command = vi.fn<Command>(async (binary, args, options) => {
    options?.signal?.throwIfAborted();
    if (binary === "/synthetic/helper") { expect([[], ["--allow-ui"]]).toContainEqual(args); return password; }
    expect(binary).toBe("/usr/bin/sandbox-exec");
    expect(args).toEqual(["-p", `(version 1)(allow default)(deny file-write* (subpath ${JSON.stringify(root)}))`, "/usr/bin/sqlite3", "-init", "/dev/null", "-batch", "-readonly", "-json", join(root, "Cookies"), expect.stringMatching(/^(SELECT CAST|SELECT host_key)/)]);
    expect(options).toMatchObject({ timeoutMs: 5000, maxBytes: args.at(-1) === desktopSchemaSQL ? 1024 : 2 * 1048576 });
    return args.at(-1) === desktopSchemaSQL ? store().version : JSON.stringify(cookies);
  });
  const http = vi.fn<HTTP>(async (url, provider, cookie) => {
    expect(provider).toBe("claude"); expect(cookie).toBe("sessionKey=synthetic-session");
    if (url === endpoints.claudeBootstrap) return bootstrap();
    expect(url).toBe(claudeUsageURL(org)); return '{"five_hour":{"utilization":25}}';
  });
  const connections = new DesktopConnections(launch, prefs, "/synthetic/helper", () => {}, command, http, () => now);
  return { home, root, launch, prefs, command, http, connections, cookies: (next: ReturnType<typeof rows>) => { cookies = next; } };
}
it("ignores distinct OAuth entries and deduplicates only identical session/organization cookies", () => {
  const raw = config.replace('"OMIT_UNRELATED_OAUTH"', '{"first":{"token":"OMIT_ONE"},"second":{"token":"OMIT_TWO"}}');
  expect(desktopCredential(raw, [store(), store()], password, now)).toEqual(credential());
  expect(credential()).toMatchObject({ identity, cookie: "sessionKey=synthetic-session", account, organization: org });
  for (const conflict of [row("sessionKey", "different"), row("lastActiveOrg", other)]) expect(() => desktopCredential(config, [store([...rows(), conflict])], password, now)).toThrow();
});
it.each(["schema", "encrypted-version", "digest", "password", "expired", "expiry-number", "expiry-overflow", "root", "secure", "http-only", "host", "name", "missing", "rows", "files"])("rejects unsupported cookie selection: %s", failure => {
  let cookies = rows(), stores = [store()], secret = password;
  if (failure === "schema") stores = [store(cookies, "23")];
  else if (failure === "files") stores = [store(), store(), store()];
  else {
    if (failure === "encrypted-version") cookies[0].encrypted_value = "763131" + cookies[0].encrypted_value.slice(6);
    if (failure === "digest") cookies[0].host_key = "claude.ai";
    if (failure === "password") secret = "wrong";
    if (failure === "expired") cookies[0].expires_utc = String((BigInt(now + 120000) + 11644473600000n) * 1000n);
    if (failure === "expiry-number") cookies[0].expires_utc = 1e20 as unknown as string;
    if (failure === "expiry-overflow") cookies[0].expires_utc = "999999999999999999999999";
    if (failure === "root") cookies[0].path = "/other";
    if (failure === "secure") cookies[0].is_secure = 0;
    if (failure === "http-only") cookies[0].is_httponly = 0;
    if (failure === "host") cookies[0].host_key = "evil.invalid";
    if (failure === "name") cookies[0].name = "other";
    if (failure === "missing") cookies = [];
    if (failure === "rows") cookies = Array(33).fill(cookies[0]);
    stores = [store(cookies)];
  }
  expect(() => desktopCredential(config, stores, secret, now)).toThrow("Not signed in");
});
it("compares Chromium expiry exactly as BigInt", () => {
  const bound = (BigInt(now + 120000) + 11644473600000n) * 1000n;
  const cookies = rows(); cookies[0].expires_utc = String(bound + 1n);
  expect(desktopCredential(config, [store(cookies)], password, now).identity).toBe(identity);
});
it.each([JSON.stringify({ uuid: account, memberships: [{ organization: { uuid: org } }] }), bootstrap(other), bootstrap(account, []), bootstrap(account, [org, org]), bootstrap(account, [other]), '{"account":{"uuid":"invalid"}}', '{"account":{"uuid":"x","uuid":"y"}}'])("rejects an unverified bootstrap schema or membership", raw => {
  expect(() => verifyDesktopAccount(raw, credential())).toThrow("Not signed in");
});
it("accepts only the captured account and a unique intended nested membership", () => {
  expect(() => verifyDesktopAccount(bootstrap(account, [other, org]), credential())).not.toThrow();
});
it("uses fixed sandboxed readonly SQL and fails closed without native execution", async () => {
  const f = await fixture();
  expect((await readDesktopCredential(f.home, password, now, undefined, f.command)).identity).toBe(identity);
  expect(f.command.mock.calls.map(([, args]) => args.at(-1))).toEqual([desktopSchemaSQL, desktopCookieSQL]);
  const failure = vi.fn<Command>(async () => { throw new Error("OMIT_PRIVATE_SQLITE_ERROR"); });
  await expect(readDesktopCredential(f.home, password, now, undefined, failure)).rejects.toMatchObject({ code: "notSignedIn" });
  const aborted = new AbortController(); aborted.abort();
  await expect(readDesktopCredential(f.home, password, now, undefined, failure, aborted.signal)).rejects.toMatchObject({ code: "notSignedIn" });
  expect(failure).toHaveBeenCalledTimes(1);
});
it.each([undefined, "a".repeat(64), "off"])("blocks old or absent consent before sensitive reads: %s", marker => fixture().then(async f => {
  f.prefs.values.desktopClaudeIdentity = marker ?? "";
  expect(f.connections.enabled("claude")).toBe(false);
  await expect(f.connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
  expect(f.command).not.toHaveBeenCalled(); expect(f.http).not.toHaveBeenCalled();
}));
it("denies missing/new consent and cancellation before any sensitive call", async () => {
  const f = await fixture();
  expect(await f.connections.connect("claude", async () => {})).toBe(false);
  expect(await f.connections.connect("claude", async () => {}, async () => false)).toBe(false);
  await expect(f.connections.connect("claude", async () => {}, async () => { f.connections.cancel("claude"); return true; })).rejects.toThrow();
  expect(f.command).not.toHaveBeenCalled(); expect(f.http).not.toHaveBeenCalled(); expect(f.prefs.values.desktopClaudeIdentity).toBe("");
});
it.each(["Connect", "background"])("uses one Keychain read and two fresh local reads per %s attempt", async attempt => {
  const f = await fixture(), original = f.command.getMockImplementation()!;
  let helperReads = 0;
  f.command.mockImplementation(async (binary, args, options) => {
    if (binary === "/synthetic/helper" && ++helperReads > 1) throw new Error("Synthetic helper allows only one read");
    return original(binary, args, options);
  });
  if (attempt === "Connect") expect(await f.connections.connect("claude", async () => {}, async () => true)).toBe(true);
  else {
    f.prefs.values.desktopClaudeIdentity = identity;
    expect((await f.connections.quota("claude")).windows[0].usedPercent).toBe(25);
  }
  const helperCalls = f.command.mock.calls.filter(([binary]) => binary === "/synthetic/helper");
  expect(helperCalls).toHaveLength(1);
  expect(helperCalls[0]).toEqual(["/synthetic/helper", attempt === "Connect" ? ["--allow-ui"] : [], { signal: expect.any(AbortSignal), timeoutMs: attempt === "Connect" ? 60000 : 5000, maxBytes: 4096 }]);
  expect(f.command.mock.calls.filter(([binary]) => binary === "/usr/bin/sandbox-exec").map(([, args]) => args.at(-1))).toEqual([desktopSchemaSQL, desktopCookieSQL, desktopSchemaSQL, desktopCookieSQL]);
  expect(f.http.mock.calls.map(([url]) => url)).toEqual([endpoints.claudeBootstrap, claudeUsageURL(org), endpoints.claudeBootstrap]);
});
it("shares Connect/background verification, detaches CLI data, and reloads only tagged consent", async () => {
  const f = await fixture(true), before = ["config.json", "Cookies"].map(name => readFileSync(join(f.root, name)));
  expect(await f.connections.connect("claude", async () => {}, async () => true)).toBe(true);
  expect(f.prefs.values.desktopClaudeIdentity).toBe(identity);
  expect(f.command.mock.calls.filter(([binary]) => binary === "/synthetic/helper").map(([, args]) => args)).toEqual([["--allow-ui"]]);
  const restored = await Preferences.load(f.launch, async () => "");
  const restart = new DesktopConnections(f.launch, restored, "/synthetic/helper", () => {}, f.command, f.http, () => now);
  const [source] = compose(f.launch, restored, { connections: restart });
  expect(source.accountBound).toBe(true); expect(source.activity).toBeUndefined(); expect(source.plan).toBeUndefined();
  expect((await source.quota!()).windows[0].usedPercent).toBe(25);
  expect(f.command.mock.calls.filter(([binary]) => binary === "/synthetic/helper").map(([, args]) => args)).toEqual([["--allow-ui"], []]);
  expect(f.http.mock.calls.map(([url]) => url)).toEqual(Array(2).fill([endpoints.claudeBootstrap, claudeUsageURL(org), endpoints.claudeBootstrap]).flat());
  await restart.disconnect("claude"); await expect(source.quota!()).rejects.toThrow();
  expect((await Preferences.load(f.launch, async () => "")).values.desktopClaudeIdentity).toBe("off");
  for (const [i, name] of ["config.json", "Cookies"].entries()) expect(readFileSync(join(f.root, name))).toEqual(before[i]);
  expect(readFileSync(join(f.launch.data, "preferences.json"), "utf8")).not.toMatch(/synthetic-password|synthetic-session|11111111|22222222|OMIT/);
});
it.each(["account", "org", "session", "server-account", "server-membership"])("rejects changed %s before publishing quota", async change => {
  const f = await fixture(); f.prefs.values.desktopClaudeIdentity = identity;
  f.http.mockImplementation(async url => {
    if (url === endpoints.claudeBootstrap) return bootstrap();
    if (change === "account") writeFileSync(join(f.root, "config.json"), config.replace(account, other));
    if (change === "org") f.cookies([row(), row("lastActiveOrg", other)]);
    if (change === "session") f.cookies([row("sessionKey", "rotated"), row("lastActiveOrg", org)]);
    if (change === "server-account") f.http.mockResolvedValue(bootstrap(other));
    if (change === "server-membership") f.http.mockResolvedValue(bootstrap(account, [other]));
    return '{"five_hour":{"utilization":25}}';
  });
  await expect(f.connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
});
it.each(["disconnect", "local", "replace", "cancel"])("rejects a late %s result without rereading private stores", async action => {
  const f = await fixture(); f.prefs.values.desktopClaudeIdentity = identity;
  let release!: (raw: string) => void, started!: () => void;
  const wait = new Promise<string>(resolve => { release = resolve; }), ready = new Promise<void>(resolve => { started = resolve; });
  f.http.mockImplementation(async url => { if (url === endpoints.claudeBootstrap) return bootstrap(); started(); return wait; });
  const controller = new AbortController(), pending = f.connections.quota("claude", controller.signal); await ready;
  const reads = f.command.mock.calls.length;
  if (action === "disconnect") await f.connections.disconnect("claude");
  if (action === "local") await f.connections.useLocal("claude");
  if (action === "replace") f.prefs.values.desktopClaudeIdentity = claudeIdentity(other, org);
  if (action === "cancel") controller.abort();
  release('{"five_hour":{"utilization":25}}'); await expect(pending).rejects.toThrow();
  expect(f.command).toHaveBeenCalledTimes(reads);
});
it.each(["identity-save", "visibility-save", "rollback-save", "save-cancel"])("preserves failed Connect CLI choice and visibility after %s", async failure => {
  const f = await fixture(); f.prefs.values.showProviderClaude = false;
  const set = f.prefs.set.bind(f.prefs);
  vi.spyOn(f.prefs, "set").mockImplementation(async (key, value) => {
    if (key === "desktopClaudeIdentity" && value === identity && failure === "identity-save" || key === "showProviderClaude" && value === true && ["visibility-save", "rollback-save"].includes(failure) || key === "desktopClaudeIdentity" && value === "" && failure === "rollback-save") throw new Error("OMIT_PREF_FAILURE");
    await set(key, value);
    if (key === "showProviderClaude" && value === true && failure === "save-cancel") f.connections.cancel("claude");
  });
  await expect(f.connections.connect("claude", async () => {}, async () => true)).rejects.toThrow();
  expect(f.prefs.values.desktopClaudeIdentity).toBe(""); expect(f.prefs.values.showProviderClaude).toBe(false);
  expect(f.connections.state.find(s => s.provider === "claude")?.source).toBe("cli");
  expect(compose(f.launch, f.prefs, { connections: f.connections }).find(s => s.slot.provider === "claude")!.activity).toBeTypeOf("function");
});
it("verifies unchanged local and remote identity after an offline usage failure", async () => {
  const f = await fixture(); f.prefs.values.desktopClaudeIdentity = identity;
  f.http.mockImplementation(async url => { if (url === endpoints.claudeBootstrap) return bootstrap(); throw new Unavailable("offline"); });
  await expect(f.connections.quota("claude")).rejects.toMatchObject({ code: "offline" });
  expect(f.command.mock.calls.filter(([binary]) => binary === "/synthetic/helper")).toHaveLength(1);
  expect(f.command.mock.calls.filter(([binary]) => binary === "/usr/bin/sandbox-exec").map(([, args]) => args.at(-1))).toEqual([desktopSchemaSQL, desktopCookieSQL, desktopSchemaSQL, desktopCookieSQL]);
  expect(f.http.mock.calls.map(([url]) => url)).toEqual([endpoints.claudeBootstrap, claudeUsageURL(org), endpoints.claudeBootstrap]);
});
it("reports a usage failure accurately when final identity verification succeeds", async () => {
  const f = await fixture();
  f.http.mockImplementation(async url => { if (url === endpoints.claudeBootstrap) return bootstrap(); throw new Error("synthetic usage service failure"); });
  await expect(f.connections.connect("claude", async () => {}, async () => true)).rejects.toThrow("Could not read Claude account allowance. Try connecting again later.");
  expect(f.http.mock.calls.map(([url]) => url)).toEqual([endpoints.claudeBootstrap, claudeUsageURL(org), endpoints.claudeBootstrap]);
  expect(f.prefs.values.desktopClaudeIdentity).toBe("");
});
const challengeMessage = "Claude requires browser verification for account allowance. Open Claude usage to view it in your browser. Your current source is unchanged.";
it.each(["bootstrap", "usage", "final-bootstrap"])("reports an explicit %s challenge through Connect and preserves the selected source", async stage => {
  const f = await fixture();
  await f.prefs.set("showProviderClaude", false);
  const before = structuredClone(f.prefs.values), writes = vi.spyOn(f.prefs, "set");
  const files = ["config.json", "Cookies"].map(name => readFileSync(join(f.root, name)));
  let bootstraps = 0;
  const fetcher = vi.fn<typeof fetch>(async url => {
    const bootstrapRequest = url === endpoints.claudeBootstrap;
    if (bootstrapRequest) bootstraps++;
    if (stage === "usage" && !bootstrapRequest || stage === "bootstrap" && bootstrapRequest || stage === "final-bootstrap" && bootstraps === 2)
      return new Response("<html>SYNTHETIC_CHALLENGE_BODY</html>", { status: 403, headers: { "cf-mitigated": "challenge" } });
    return new Response(bootstrapRequest ? bootstrap() : '{"five_hour":{"utilization":25}}');
  });
  const connections = new DesktopConnections(f.launch, f.prefs, "/synthetic/helper", () => {}, f.command, httpTransport(fetcher), () => now);
  const open = vi.fn(async () => {});
  await expect(connections.connect("claude", open, async () => true)).rejects.toThrow(challengeMessage);
  expect(fetcher.mock.calls.map(([url]) => url)).toEqual(stage === "bootstrap" ? [endpoints.claudeBootstrap] : [endpoints.claudeBootstrap, claudeUsageURL(org), endpoints.claudeBootstrap]);
  expect(f.command.mock.calls.filter(([binary]) => binary === "/synthetic/helper")).toHaveLength(1);
  expect(f.command.mock.calls.filter(([binary]) => binary === "/usr/bin/sandbox-exec").map(([, args]) => args.at(-1))).toEqual([desktopSchemaSQL, desktopCookieSQL, desktopSchemaSQL, desktopCookieSQL]);
  expect(f.prefs.values).toEqual(before); expect(writes).not.toHaveBeenCalled();
  expect(connections.state.find(s => s.provider === "claude")).toMatchObject({ source: "cli", status: "failed" });
  expect(connections.enabled("claude")).toBe(false);
  expect(compose(f.launch, f.prefs, { connections }).find(s => s.slot.provider === "claude")!.activity).toBeTypeOf("function");
  for (const [i, name] of ["config.json", "Cookies"].entries()) expect(readFileSync(join(f.root, name))).toEqual(files[i]);
  expect(open).not.toHaveBeenCalled();
});
it.each(["bootstrap", "usage"])("keeps ordinary %s 403 errors and source selection unchanged", async stage => {
  const f = await fixture(), before = structuredClone(f.prefs.values);
  const fetcher = vi.fn<typeof fetch>(async url => new Response(stage === "usage" && url === endpoints.claudeBootstrap ? bootstrap() : "SYNTHETIC_FORBIDDEN", { status: stage === "usage" && url === endpoints.claudeBootstrap ? 200 : 403 }));
  const connections = new DesktopConnections(f.launch, f.prefs, "/synthetic/helper", () => {}, f.command, httpTransport(fetcher), () => now);
  await expect(connections.connect("claude", async () => {}, async () => true)).rejects.toThrow("Could not read Claude account allowance. Try connecting again later.");
  expect(f.prefs.values).toEqual(before); expect(connections.enabled("claude")).toBe(false);
});
it("discards old consent quota and keeps account quota outside CLI history", async () => {
  const f = await fixture(); f.prefs.values.desktopClaudeIdentity = "a".repeat(64); f.prefs.values.showProviderClaude = true;
  mkdirSync(f.launch.data, { recursive: true });
  saveArchive(join(f.launch.data, "quota-archive.json"), [{ slot: primary("claude"), quota: quota("claude", [window("5-hour", 90)], now) }]);
  const sources = compose(f.launch, f.prefs, { connections: f.connections, http: async () => '{"components":[]}' }).filter(s => s.slot.provider === "claude");
  expect(sources[0].status).toBeUndefined();
  const c = new Coordinator(f.launch, f.prefs, sources, () => now);
  expect(c.snapshot().archived.claude.windows[0].usedPercent).toBe(90);
  try { await c.refresh(); expect(c.snapshot().archived.claude).toBeUndefined(); expect(c.snapshot().activities.claude).toBeUndefined(); expect(c.history.records("claude")).toEqual([]); }
  finally { c.stop(); }
  expect(f.command).not.toHaveBeenCalled(); expect(f.http).not.toHaveBeenCalled();
});
it("sends Cookie only to fixed bootstrap and UUID-bound usage with bounded transport", async () => {
  const fetcher = vi.fn<typeof fetch>(async () => new Response('{}'));
  const http = httpTransport(fetcher);
  await http(endpoints.claudeBootstrap, "claude", credential().cookie);
  await http(claudeUsageURL(org), "claude", credential().cookie);
  for (const [, init] of fetcher.mock.calls) {
    expect(init).toMatchObject({ redirect: "error", cache: "no-store", headers: { Cookie: credential().cookie, "User-Agent": "meterusage/0.2.41" } });
    expect(init!.headers).not.toHaveProperty("Authorization"); expect(init!.headers).not.toHaveProperty("anthropic-beta");
    expect(init!.signal).toBeInstanceOf(AbortSignal);
  }
  for (const url of ["https://claude.ai/api/account", "https://claude.ai/api/organizations/not-uuid/usage", "https://evil.invalid/api/bootstrap", endpoints.openRouterKey]) await expect(http(url as Endpoint, "claude", credential().cookie)).rejects.toThrow();
  await expect(http(endpoints.claudeBootstrap, "grok", credential().cookie)).rejects.toThrow();
  await expect(http(endpoints.claudeBootstrap, "claude", "Bearer synthetic")).rejects.toThrow();
  expect(fetcher).toHaveBeenCalledTimes(2);
});
it.each(["overflow", "redirect", "unauthorized", "cancel"])("rejects transport %s with fixed failures", async failure => {
  const controller = new AbortController();
  const fetcher = vi.fn<typeof fetch>(async () => {
    if (failure === "redirect") throw new TypeError("OMIT_REDIRECT");
    if (failure === "cancel") { controller.abort(); return new Response('{}'); }
    return failure === "unauthorized" ? new Response('{}', { status: 401 }) : new Response("x".repeat(1048577));
  });
  await expect(httpTransport(fetcher)(endpoints.claudeBootstrap, "claude", credential().cookie, controller.signal)).rejects.toThrow();
});

it("rejects a local session change during the final bootstrap response", async () => {
  const f = await fixture(); f.prefs.values.desktopClaudeIdentity = identity;
  let bootstraps = 0;
  f.http.mockImplementation(async url => {
    if (url === endpoints.claudeBootstrap) {
      if (++bootstraps === 2) f.cookies([row("sessionKey", "rotated"), row("lastActiveOrg", org)]);
      return bootstrap();
    }
    return '{"five_hour":{"utilization":25}}';
  });
  await expect(f.connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
});
it("never requests usage when the initial bootstrap reports a different account", async () => {
  const f = await fixture(); f.prefs.values.desktopClaudeIdentity = identity;
  f.http.mockResolvedValue(bootstrap(other));
  await expect(f.connections.quota("claude")).rejects.toMatchObject({ code: "notSignedIn" });
  expect(f.http.mock.calls.map(([url]) => url)).toEqual([endpoints.claudeBootstrap]);
});
it("does not read cookies when cancelled during the helper or publish a disconnected pending Connect", async () => {
  const f = await fixture(), original = f.command.getMockImplementation()!;
  f.command.mockImplementation(async (binary, args, options) => {
    if (binary === "/synthetic/helper") { f.connections.cancel("claude"); return password; }
    return original(binary, args, options);
  });
  await expect(f.connections.connect("claude", async () => {}, async () => true)).rejects.toThrow();
  expect(f.command).toHaveBeenCalledTimes(1); expect(f.http).not.toHaveBeenCalled();
  f.command.mockImplementation(original);
  let release!: (raw: string) => void, started!: () => void;
  const wait = new Promise<string>(resolve => { release = resolve; }), ready = new Promise<void>(resolve => { started = resolve; });
  f.http.mockImplementation(async url => { if (url === endpoints.claudeBootstrap) return bootstrap(); started(); return wait; });
  const connecting = f.connections.connect("claude", async () => {}, async () => true).catch(error => error);
  await ready; const reads = f.command.mock.calls.length;
  const disconnecting = f.connections.disconnect("claude");
  release('{"five_hour":{"utilization":25}}');
  expect(await connecting).toBeInstanceOf(Error); await disconnecting;
  expect(f.prefs.values.desktopClaudeIdentity).toBe("off"); expect(f.command).toHaveBeenCalledTimes(reads);
});

it.each([
  { url: endpoints.claudeBootstrap, provider: "claude", status: 403, header: "challenge", challenge: true, code: "notSignedIn" },
  { url: claudeUsageURL(org), provider: "claude", status: 403, header: "challenge", challenge: true, code: "notSignedIn" },
  { url: endpoints.claudeBootstrap, provider: "claude", status: 403, header: "other", challenge: false, code: "notSignedIn" },
  { url: endpoints.claudeBootstrap, provider: "claude", status: 403, header: "Challenge", challenge: false, code: "notSignedIn" },
  { url: endpoints.claudeBootstrap, provider: "claude", status: 401, header: "challenge", challenge: false, code: "notSignedIn" },
  { url: endpoints.claudeBootstrap, provider: "claude", status: 500, header: "challenge", challenge: false, code: "failed" },
  { url: endpoints.openRouterKey, provider: "openRouter", status: 403, header: "challenge", challenge: false, code: "failed" },
  { url: endpoints.openRouterActivity, provider: "openRouter", status: 403, header: "challenge", challenge: false, code: "dataNotFound" },
  { url: endpoints.grok, provider: "grok", status: 403, header: "challenge", challenge: false, code: "failed" },
] as const)("classifies only explicit Claude challenge responses ($provider $status $header)", async ({ url, provider, status, header, challenge, code }) => {
  const response = new Response("SYNTHETIC_PRIVATE_ERROR_BODY", { status, headers: { "cf-mitigated": header } });
  const reader = vi.spyOn(response.body!, "getReader");
  const fetcher = vi.fn<typeof fetch>(async () => response);
  const error = await httpTransport(fetcher)(url, provider, provider === "claude" ? credential().cookie : "synthetic-key").catch(error => error);
  expect(error).toBeInstanceOf(Unavailable); expect(error.code).toBe(code);
  expect(error instanceof ClaudeBrowserVerification).toBe(challenge);
  expect(error.message).not.toContain("SYNTHETIC_PRIVATE_ERROR_BODY");
  expect(reader).not.toHaveBeenCalled(); expect(fetcher).toHaveBeenCalledTimes(1);
});
it.each(["cancel", "session-change"])("keeps %s safeguards after a challenge", async action => {
  const f = await fixture();
  const fetcher = vi.fn<typeof fetch>(async url => {
    if (url === endpoints.claudeBootstrap) return new Response(bootstrap());
    if (action === "cancel") connections.cancel("claude");
    else f.cookies([row("sessionKey", "rotated"), row("lastActiveOrg", org)]);
    return new Response("SYNTHETIC_CHALLENGE", { status: 403, headers: { "cf-mitigated": "challenge" } });
  });
  const connections = new DesktopConnections(f.launch, f.prefs, "/synthetic/helper", () => {}, f.command, httpTransport(fetcher), () => now);
  await expect(connections.connect("claude", async () => {}, async () => true)).rejects.toThrow(action === "cancel" ? "Open Claude Desktop and sign in, then try connecting again" : "Could not verify the same Claude Desktop account and session after the allowance request. Try connecting again.");
  expect(fetcher).toHaveBeenCalledTimes(action === "cancel" ? 2 : 3);
  expect(f.command).toHaveBeenCalledTimes(action === "cancel" ? 3 : 5);
  expect(f.prefs.values.desktopClaudeIdentity).toBe(""); expect(connections.enabled("claude")).toBe(false);
});

it.each([false, true])("uses native HTTP for consented Connect and selected-source polling (isolated=%s)", async isolated => {
  const f = await fixture(isolated);
  const fetcher = vi.fn<typeof fetch>(async (url, options) => {
    expect(options).toMatchObject({ credentials: "omit", redirect: "error", cache: "no-store", headers: { Cookie: "sessionKey=synthetic-session", "User-Agent": "meterusage/0.2.41", Accept: "application/json" } });
    expect(options!.signal).toBeInstanceOf(AbortSignal);
    return new Response(url === endpoints.claudeBootstrap ? bootstrap() : '{"five_hour":{"utilization":25}}');
  });
  const sessions = { fromPartition: vi.fn(() => ({ isPersistent: () => false, storagePath: null, fetch: fetcher })) };
  const http = desktopHTTP(f.launch, sessions as unknown as Pick<typeof session, "fromPartition">);
  const c = new DesktopConnections(f.launch, f.prefs, "/synthetic/helper", () => {}, f.command, http, () => now);
  try {
    expect(await c.connect("claude", async () => {}, async () => false)).toBe(false);
    expect(fetcher).not.toHaveBeenCalled(); expect(f.command).not.toHaveBeenCalled();
    expect(await c.connect("claude", async () => {}, async () => true)).toBe(true);
    const source = compose(f.launch, f.prefs, { connections: c, http }).find(s => s.slot.provider === "claude")!;
    expect(source.accountBound).toBe(true);
    expect((await source.quota!()).windows[0].usedPercent).toBe(25);
    expect(fetcher.mock.calls.map(([url]) => url)).toEqual(Array(2).fill([endpoints.claudeBootstrap, claudeUsageURL(org), endpoints.claudeBootstrap]).flat());
    expect(sessions.fromPartition).toHaveBeenCalledOnce();
    expect(fetch).not.toHaveBeenCalled();
  } finally { await c.stop(); }
});
