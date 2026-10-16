import { afterEach, expect, it, vi } from "vite-plus/test";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { type ClientRequest, type IncomingMessage, type RequestOptions } from "node:http";
import { userInfo } from "node:os";
import { readAntigravityDesktop, antigravityDesktopQuota, antigravityIdentity, discoverAntigravity, antigravityRPC, type AntigravityEndpoint, type AntigravityRPC } from "../src/main/providers/antigravity-desktop";
import { type Command } from "../src/main/providers/transport";
import { Preferences } from "../src/main/preferences";
import { DesktopConnections } from "../src/main/connections";
import { compose } from "../src/main/composition";
import { Coordinator } from "../src/main/coordinator";
import { projectSettings, parseRequest } from "../src/main/ipc";
import type { Launch } from "../src/main/launch";
import { mkdtempSync, rmSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const now = Date.parse("2026-10-16T00:00:00Z"), reset = "2026-10-16T05:00:00Z";
const path = "/Applications/Antigravity.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm";
const csrf = "fixture-csrf-secret", email = "synthetic@example.invalid";
const status = (account = email) => JSON.stringify({ userStatus: { email: account, userTier: { name: "Pro" }, cascadeModelConfigData: { clientModelConfigs: [{ label: "Legacy model", quotaInfo: { remainingFraction: 0.25, resetTime: reset } }] } }, privateField: "SKIP-ME" });
const summary = (bucket: Record<string, unknown> = {}) => JSON.stringify({ response: { groups: [{ displayName: "Models", buckets: [{ bucketId: "model-session", displayName: "Session", remainingFraction: 0.8, resetTime: reset, ...bucket }] }] }, privateField: "SKIP-ME" });
const endpoint: AntigravityEndpoint = { pid: 123, port: 4321, scheme: "https:", csrf };
const roots: string[] = [];
afterEach(() => { vi.useRealTimers(); vi.restoreAllMocks(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function fixture() {
  const f = { processes: `123 ${userInfo().uid} ${path}\n`, commandLine: `${path} --csrf_token=${csrf} --extension_server_port 4321`, listeners: "p123\nn127.0.0.1:4321\n", status: status(), summary: summary(), saved: new Map<string, string>() };
  const command = vi.fn<Command>(async (binary, args, options) => {
    options?.signal?.throwIfAborted();
    if (binary === "/usr/bin/defaults") {
      const [action, , key, , value] = args;
      if (action === "write") { f.saved.set(key, value); return ""; }
      if (!f.saved.has(key)) throw new Error("Absent synthetic preference");
      return action === "read-type" ? "string" : f.saved.get(key)!;
    }
    expect(options?.timeoutMs).toBe(3000); expect(options?.maxBytes).toBeLessThanOrEqual(1048576);
    if (binary === "/bin/ps" && args[0] === "-axo") return f.processes;
    if (binary === "/bin/ps" && args[0] === "-ww") { expect(args).toEqual(["-ww", "-p", "123", "-o", "command="]); return f.commandLine; }
    if (binary === "/usr/sbin/lsof") { expect(args).toEqual(["-nP", "-a", "-p", "123", "-iTCP", "-sTCP:LISTEN", "-Fpn"]); return f.listeners; }
    throw new Error("Forbidden non-fixture command");
  });
  const rpc = vi.fn<AntigravityRPC>(async (_endpoint, method, signal) => { signal.throwIfAborted(); return method === "GetUserStatus" ? f.status : f.summary; });
  return { f, command, rpc };
}
function sendFixture(code = 200, chunks: string[] = [summary()], headers: Record<string, string> = {}, stall = false) {
  const requests: { options: RequestOptions; body: string }[] = [], destroyed = vi.fn();
  const send = (options: RequestOptions, callback: (response: IncomingMessage) => void) => {
    const request = new EventEmitter() as ClientRequest;
    request.destroy = (() => { destroyed(); return request; }) as typeof request.destroy;
    request.end = ((body: string) => {
      requests.push({ options, body });
      if (!stall) queueMicrotask(() => {
        const response = new PassThrough() as unknown as IncomingMessage;
        response.statusCode = code; response.headers = headers;
        callback(response);
        for (const chunk of chunks) response.push(Buffer.from(chunk));
        response.push(null);
      });
      return request;
    }) as typeof request.end;
    return request;
  };
  return { send, requests, destroyed };
}
async function connectionFixture() {
  const f = fixture(), home = mkdtempSync(join(tmpdir(), "meterusage-agy-fixture-")); roots.push(home);
  const launch: Launch = { home, data: join(home, "app-data"), env: {}, demo: false, candidate: true };
  const prefs = await Preferences.load(launch, f.command);
  const connections = new DesktopConnections(launch, prefs, "/fixture/no-helper", () => {}, f.command, async () => { throw new Error("Forbidden provider HTTP"); }, () => now, f.rpc);
  return { ...f, home, launch, prefs, connections };
}

it("discovers only one same-user desktop executable, then its arguments and owned loopback listener", async () => {
  const { f, command } = fixture();
  f.processes += `999 ${userInfo().uid} /Applications/Other.app/Contents/private\n998 ${userInfo().uid + 1} ${path}\n`;
  expect(await discoverAntigravity(command)).toMatchObject({ pid: 123, csrf, ports: [4321] });
  expect(command.mock.calls).toHaveLength(3);
  expect(command.mock.calls.some(([, args]) => args.includes("999") || args.includes("998"))).toBe(false);
});
it.each(["none", "multiple", "other-user", "cli", "suffix-spoof"])("rejects %s executable discovery without reading process arguments", async kind => {
  const { f, command } = fixture();
  f.processes = kind === "none" ? "" : kind === "multiple" ? f.processes + `124 ${userInfo().uid} ${path}\n` : kind === "other-user" ? `123 ${userInfo().uid + 1} ${path}` : kind === "cli" ? `123 ${userInfo().uid} /opt/bin/agy` : `123 ${userInfo().uid} ${path.replace("/Antigravity.app/", "/NotAntigravity.app/")}`;
  await expect(discoverAntigravity(command)).rejects.toMatchObject({ code: "notSignedIn" });
  expect(command).toHaveBeenCalledTimes(1);
});
it.each(["missing-token", "duplicate-token", "wrong-process", "invalid-port", "no-listener", "wrong-owner", "wildcard", "remote"])("rejects %s discovery", async kind => {
  const { f, command, rpc } = fixture();
  if (kind === "missing-token") f.commandLine = path + " --extension_server_port 4321";
  if (kind === "duplicate-token") f.commandLine += " --csrf_token=other";
  if (kind === "wrong-process") f.commandLine = "/foreign/process --csrf_token=" + csrf;
  if (kind === "invalid-port") f.commandLine = f.commandLine.replace("4321", "70000");
  if (kind === "no-listener") f.listeners = "";
  if (kind === "wrong-owner") f.listeners = "p124\nn127.0.0.1:4321";
  if (kind === "wildcard") f.listeners = "p123\nn*:4321";
  if (kind === "remote") f.listeners = "p123\nn192.0.2.1:4321";
  await expect(readAntigravityDesktop(command, rpc, now)).rejects.toMatchObject({ code: "notSignedIn" });
  expect(rpc).not.toHaveBeenCalled();
});
it("reads modern quota between matching identities, retaining only projected allowance and an opaque hash", async () => {
  const { command, rpc } = fixture(), result = await readAntigravityDesktop(command, rpc, now);
  expect(result.identity).toMatch(/^[a-f0-9]{64}$/);
  expect(result.quota).toMatchObject({ provider: "antigravity", planType: "Pro", capturedAt: now });
  expect(result.quota.windows[0].usedPercent).toBeCloseTo(20);
  expect(result.quota.windows[0]).toMatchObject({ label: "Models · Session", resetsAt: Date.parse(reset) });
  expect(rpc.mock.calls.map(c => c[1])).toEqual(["GetUserStatus", "RetrieveUserQuotaSummary", "GetUserStatus"]);
  expect(JSON.stringify(result)).not.toMatch(/SKIP-ME|fixture-csrf|synthetic@/);
  expect(antigravityIdentity(status(email.toUpperCase()))).toBe(result.identity);
});
it.each(["root", "summary", "response", "oneof", "nested", "zero"])("parses the established %s summary shape", shape => {
  const data = JSON.parse(summary()), groups = data.response.groups;
  if (shape === "oneof") { delete groups[0].buckets[0].remainingFraction; groups[0].buckets[0].remaining = { case: "remainingFraction", value: 0.6 }; }
  if (shape === "nested") { delete groups[0].buckets[0].remainingFraction; groups[0].buckets[0].remaining = { remainingFraction: 0.6 }; }
  if (shape === "zero") groups[0].buckets[0].remainingFraction = 0;
  const raw = JSON.stringify(shape === "root" ? { groups } : shape === "summary" ? { summary: { groups } } : data);
  const q = antigravityDesktopQuota(raw, status(), now);
  expect(q.windows[0].usedPercent).toBeCloseTo(shape === "zero" ? 100 : ["nested", "oneof"].includes(shape) ? 40 : 20);
});
it.each([undefined, null, -0.1, 1.1, "0.5", Number.NaN])("keeps a missing or invalid fraction (%s) unavailable in modern and legacy quota", fraction => {
  expect(() => antigravityDesktopQuota(summary({ remainingFraction: fraction }), status(), now)).toThrow("No usage yet");
  const legacy = JSON.parse(status()); legacy.userStatus.cascadeModelConfigData.clientModelConfigs[0].quotaInfo.remainingFraction = fraction;
  expect(() => antigravityDesktopQuota("", JSON.stringify(legacy), now, true)).toThrow("No usage yet");
});
it.each(["{}", '{"response":{"groups":[]}}', '{"summary":{}}', '{"response":{},"groups":[{}]}', '{"code":7}', "malformed"])("does not fall back to legacy quota for modern response %s", async raw => {
  const { f, command, rpc } = fixture(); f.summary = raw;
  await expect(readAntigravityDesktop(command, rpc, now)).rejects.toMatchObject({ code: expect.stringMatching(/noData|notSignedIn/) });
  expect(rpc.mock.calls.map(c => c[1])).toEqual(["GetUserStatus", "RetrieveUserQuotaSummary"]);
});
it.each([{ disabled: true }, { resetTime: "bad" }, { resetTime: "2026-10-15T00:00:00Z" }, { bucketId: undefined }])("keeps disabled, expired or unidentified quota unavailable: %j", bucket => {
  expect(() => antigravityDesktopQuota(summary(bucket), status(), now)).toThrow("No usage yet");
});
it("uses legacy quota only for an explicitly unsupported modern RPC, without inventing weekly allowance", async () => {
  const { command, rpc } = fixture();
  const legacy: AntigravityRPC = async (e, method, signal) => method === "RetrieveUserQuotaSummary" ? antigravityRPC(e, method, signal, sendFixture(404).send) : rpc(e, method, signal);
  const result = await readAntigravityDesktop(command, legacy, now);
  expect(result.quota.windows).toEqual([{ label: "Legacy model", usedPercent: 75, resetsAt: Date.parse(reset) }]);
  expect(result.quota.windows.some(w => /weekly/i.test(w.label))).toBe(false);
});
it.each(["before", "after", "missing", "rejected-status", "closure", "port-owner", "csrf-change"])("rejects %s identity/ownership changes", async change => {
  const { f, command, rpc } = fixture(); let reads = 0;
  rpc.mockImplementation(async (_e, method) => {
    if (method === "GetUserStatus") {
      reads++;
      if (change === "before" || change === "after" && reads > 1) return status("other@example.invalid");
      if (change === "missing") return '{"userStatus":{}}';
      if (change === "rejected-status") return '{"code":16,"userStatus":{"email":"synthetic@example.invalid"}}';
      return f.status;
    }
    if (change === "closure") f.processes = "";
    if (change === "port-owner") f.listeners = "p124\nn127.0.0.1:4321";
    if (change === "csrf-change") f.commandLine = f.commandLine.replace(csrf, "changed-token");
    return f.summary;
  });
  await expect(readAntigravityDesktop(command, rpc, now, undefined, antigravityIdentity(status()))).rejects.toBeInstanceOf(Error);
  if (["before", "missing", "rejected-status"].includes(change)) expect(rpc.mock.calls.map(c => c[1])).toEqual(["GetUserStatus"]);
});
it("prefers HTTPS and allows HTTP only on the declared PID-owned extension port with its token", async () => {
  const { f, command, rpc } = fixture();
  f.listeners += "n127.0.0.1:5432\n"; f.commandLine += " --extension_server_csrf_token=extension-secret";
  rpc.mockImplementation(async (e, method) => { if (e.scheme === "https:") throw new Error("Synthetic TLS failure"); return method === "GetUserStatus" ? f.status : f.summary; });
  await readAntigravityDesktop(command, rpc, now);
  expect(rpc.mock.calls.slice(0, 3).map(c => [c[0].scheme, c[0].port])).toEqual([["https:", 4321], ["https:", 5432], ["http:", 4321]]);
  expect(rpc.mock.calls[2][0].csrf).toBe("extension-secret");
  f.commandLine = f.commandLine.replace("port 4321", "port 6000"); rpc.mockClear();
  await expect(readAntigravityDesktop(command, rpc, now)).rejects.toMatchObject({ code: "notSignedIn" });
  expect(rpc.mock.calls.every(c => c[0].scheme === "https:")).toBe(true);
});
it("sanitizes process and transport exceptions", async () => {
  const { command, rpc } = fixture();
  rpc.mockRejectedValue(new Error(email + csrf));
  await expect(readAntigravityDesktop(command, rpc, now)).rejects.toThrow("Not signed in to Antigravity Desktop");
  command.mockRejectedValue(new Error(email + csrf));
  await expect(readAntigravityDesktop(command, rpc, now)).rejects.toThrow("Not signed in to Antigravity Desktop");
});

it("sends only the fixed loopback RPC body, path, headers and request-local TLS exception", async () => {
  const f = sendFixture();
  await antigravityRPC(endpoint, "RetrieveUserQuotaSummary", new AbortController().signal, f.send);
  expect(f.requests).toHaveLength(1);
  expect(f.requests[0]).toMatchObject({ options: { hostname: "127.0.0.1", protocol: "https:", port: 4321, path: "/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary", method: "POST", agent: false, rejectUnauthorized: false, headers: { "X-Codeium-Csrf-Token": csrf, "Connect-Protocol-Version": "1" } }, body: '{"forceRefresh":true}' });
});
it.each([301, 302, 307, 308, 401, 429, 500])("rejects HTTP %s without following Location or retaining raw errors", async code => {
  const f = sendFixture(code, [email + csrf], { location: "https://provider.invalid/steal" });
  await expect(antigravityRPC(endpoint, "RetrieveUserQuotaSummary", new AbortController().signal, f.send)).rejects.toThrow("No usage yet");
  expect(f.requests).toHaveLength(1); expect(f.destroyed).toHaveBeenCalled();
});
it.each(["stream", "length"])("bounds response %s bytes", async kind => {
  const f = sendFixture(200, kind === "stream" ? ["a".repeat(700000), "a".repeat(400000)] : [], kind === "length" ? { "content-length": "1048577" } : {});
  await expect(antigravityRPC(endpoint, "GetUserStatus", new AbortController().signal, f.send)).rejects.toThrow("No usage yet");
  expect(f.destroyed).toHaveBeenCalled();
});
it.each(["timeout", "abort"])("bounds transport %s and destroys the request", async kind => {
  vi.useFakeTimers(); const f = sendFixture(200, [], {}, true), controller = new AbortController();
  const pending = antigravityRPC(endpoint, "GetUserStatus", controller.signal, f.send);
  const result = expect(pending).rejects.toThrow("No usage yet");
  if (kind === "timeout") await vi.advanceTimersByTimeAsync(3000); else controller.abort();
  await result; expect(f.destroyed).toHaveBeenCalled();
});
it("refuses undeclared HTTP, invalid methods/ports/tokens and pre-cancellation before sending", async () => {
  const f = sendFixture();
  for (const e of [{ ...endpoint, scheme: "http:" as const }, { ...endpoint, port: 70000 }, { ...endpoint, csrf: "bad\r\nheader" }]) await expect(antigravityRPC(e, "GetUserStatus", new AbortController().signal, f.send)).rejects.toThrow();
  await expect(antigravityRPC(endpoint, "Other" as "GetUserStatus", new AbortController().signal, f.send)).rejects.toThrow();
  await expect(antigravityRPC(endpoint, "GetUserStatus", AbortSignal.abort(), f.send)).rejects.toThrow();
  expect(f.requests).toHaveLength(0);
});

it("connects through the existing controls, persists only an opaque identity and keeps local history detached", async () => {
  const { launch, home, prefs, connections, f, command } = await connectionFixture();
  expect(connections.state.find(c => c.provider === "antigravity")).toMatchObject({ source: "cli", status: "disconnected" });
  const open = vi.fn(async () => {});
  await connections.connect("antigravity", open);
  const identity = prefs.values.desktopAntigravityIdentity;
  expect(identity).toBe(antigravityIdentity(status())); expect(open).not.toHaveBeenCalled();
  expect(connections.state.find(c => c.provider === "antigravity")).toMatchObject({ source: "account", status: "connected" });
  const source = compose(launch, prefs, { connections }).find(s => s.slot.provider === "antigravity")!;
  expect(source.accountBound).toBe(true); expect(source).not.toHaveProperty("activity"); expect(source).not.toHaveProperty("usage"); expect(source).not.toHaveProperty("plan");
  await expect(source.quota!()).resolves.toMatchObject({ provider: "antigravity" });
  const published = JSON.stringify({ state: connections.state, settings: projectSettings(prefs.values, [], home) });
  expect(published).not.toContain(String(identity)); expect(published).not.toContain("desktopAntigravityIdentity");
  expect(JSON.stringify([...f.saved])).not.toMatch(/fixture-csrf|synthetic@|SKIP-ME/);
  expect(readdirSync(home)).toEqual([]);
  const restored = await Preferences.load(launch, command); expect(restored.values.desktopAntigravityIdentity).toBe(identity);
  await connections.disconnect("antigravity");
  expect(prefs.values.desktopAntigravityIdentity).toBe("off");
  await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
  expect(compose(launch, prefs, { connections }).find(s => s.slot.provider === "antigravity")).not.toHaveProperty("usage");
  await connections.useLocal("antigravity"); expect(prefs.values.desktopAntigravityIdentity).toBe("");
  expect(compose(launch, prefs, { connections }).find(s => s.slot.provider === "antigravity")).toHaveProperty("usage");
});
it.each(["identity", "visibility", "rollback"])("fails closed and hides raw preference errors on %s save failure", async stage => {
  const { prefs, connections } = await connectionFixture(), save = prefs.set.bind(prefs);
  vi.spyOn(prefs, "set").mockImplementation(async (key, value) => {
    if (stage === "identity" && key === "desktopAntigravityIdentity" || stage !== "identity" && key === "showProviderAntigravity" || stage === "rollback" && key === "desktopAntigravityIdentity" && value === "off") throw new Error(email + csrf);
    return save(key, value);
  });
  await expect(connections.connect("antigravity", async () => {})).rejects.toThrow("Open one Antigravity Desktop account");
  expect(connections.enabled("antigravity")).toBe(false);
  expect(prefs.values.desktopAntigravityIdentity).toBe(stage === "identity" ? "" : "off");
});
it.each(["cancel", "stop"])("rejects a late connect result after %s", async action => {
  const { connections, prefs, rpc, f } = await connectionFixture();
  let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; });
  rpc.mockImplementation(async (_e, method) => { if (method === "RetrieveUserQuotaSummary") { await gate; return f.summary; } return f.status; });
  const pending = connections.connect("antigravity", async () => {}), result = expect(pending).rejects.toThrow("Open one Antigravity Desktop account");
  await vi.waitFor(() => expect(rpc.mock.calls.some(c => c[1] === "RetrieveUserQuotaSummary")).toBe(true));
  if (action === "cancel") connections.cancel("antigravity"); else void connections.stop();
  release(); await result;
  expect(connections.enabled("antigravity")).toBe(false); expect(prefs.values.desktopAntigravityIdentity).toBe("");
  expect(rpc.mock.calls.map(c => c[1])).toEqual(["GetUserStatus", "RetrieveUserQuotaSummary"]);
});
it("cancels quota on disconnect and rejects old results even after reconnecting the same identity", async () => {
  const { connections, prefs, rpc, f } = await connectionFixture(); await connections.connect("antigravity", async () => {});
  let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; });
  rpc.mockImplementationOnce(async () => f.status).mockImplementationOnce(async () => { await gate; return f.summary; });
  const pending = connections.quota("antigravity"), result = expect(pending).rejects.toThrow();
  await vi.waitFor(() => expect(rpc).toHaveBeenCalledTimes(5));
  const oldSignal = rpc.mock.calls[4][2];
  await connections.disconnect("antigravity"); expect(oldSignal.aborted).toBe(true);
  await connections.connect("antigravity", async () => {});
  release(); await result; expect(connections.enabled("antigravity")).toBe(true);
  expect(prefs.values.desktopAntigravityIdentity).toBe(antigravityIdentity(status()));
});
it("clears account allowance/archive after empty quota or changed identity and keeps private fields out of diagnostics", async () => {
  const { launch, prefs, connections, f } = await connectionFixture(); await connections.connect("antigravity", async () => {});
  const source = compose(launch, prefs, { connections }).find(s => s.slot.provider === "antigravity")!;
  const coordinator = new Coordinator(launch, prefs, [source], () => now);
  await coordinator.refresh(); expect(coordinator.snapshot().quotas.antigravity.status).toBe("value");
  const archive = join(launch.data, "quota-archive.json"), saved = readFileSync(archive, "utf8");
  expect(JSON.parse(saved)).toHaveLength(1); expect(saved).not.toMatch(/fixture-csrf|synthetic@|SKIP-ME/);
  f.summary = '{"response":{"groups":[]}}'; await coordinator.refresh();
  expect(coordinator.snapshot().quotas.antigravity).toMatchObject({ status: "missing", code: "noData" });
  expect(coordinator.snapshot().archived.antigravity).toBeUndefined();
  f.summary = summary(); await coordinator.refresh();
  f.status = status("other@example.invalid"); await coordinator.refresh();
  expect(coordinator.snapshot().quotas.antigravity).toMatchObject({ status: "missing", code: "notSignedIn" });
  expect(coordinator.snapshot().archived.antigravity).toBeUndefined();
  expect(coordinator.diagnostics("fixture")).not.toMatch(/fixture-csrf|synthetic@|other@|desktopAntigravityIdentity/);
  expect(JSON.parse(readFileSync(archive, "utf8"))).toEqual([]);
  coordinator.stop();
});
it("denies demo and other-provider isolated profiles before discovery or RPC", async () => {
  for (const mode of ["demo", "codexTest", "claudeTest"] as const) {
    const { launch, prefs, command, rpc } = await connectionFixture(); launch[mode] = true; prefs.values.desktopAntigravityIdentity = antigravityIdentity(status());
    const connections = new DesktopConnections(launch, prefs, "/fixture/helper", () => {}, command, async () => "", () => now, rpc);
    const calls = command.mock.calls.length;
    await expect(connections.connect("antigravity", async () => {})).rejects.toThrow();
    await expect(connections.quota("antigravity")).rejects.toThrow();
    expect(command).toHaveBeenCalledTimes(calls); expect(rpc).not.toHaveBeenCalled();
  }
});
it("allows only the fixed connection actions and refuses renderer preference/endpoint injection", () => {
  for (const action of ["connect", "disconnect", "connectionCancel", "connectionLocal"]) expect(parseRequest({ action, provider: "antigravity" })).toEqual({ action, provider: "antigravity" });
  for (const request of [{ action: "setPreference", key: "desktopAntigravityIdentity", value: "off" }, { action: "connect", provider: "antigravity", port: 1234 }, { action: "connect", provider: "antigravity", token: csrf }]) expect(() => parseRequest(request)).toThrow();
});

it.each(["identity", "visibility"])("rolls back cancellation during the %s preference write", async stage => {
  const { connections, prefs } = await connectionFixture(), save = prefs.set.bind(prefs);
  let release!: () => void; const gate = new Promise<void>(resolve => { release = resolve; });
  let saving = false;
  vi.spyOn(prefs, "set").mockImplementation(async (key, value) => {
    await save(key, value);
    if (stage === "identity" && key === "desktopAntigravityIdentity" && value !== "off" || stage === "visibility" && key === "showProviderAntigravity") { saving = true; await gate; }
  });
  const pending = connections.connect("antigravity", async () => {}), result = expect(pending).rejects.toThrow("Open one Antigravity Desktop account");
  await vi.waitFor(() => expect(saving).toBe(true));
  await expect(connections.connect("antigravity", async () => {})).rejects.toThrow("already active");
  await expect(connections.disconnect("antigravity")).rejects.toThrow("unavailable");
  connections.cancel("antigravity"); release(); await result;
  expect(prefs.values.desktopAntigravityIdentity).toBe("off"); expect(connections.enabled("antigravity")).toBe(false);
});
it("rejects a source captured for a previous account after reconnecting another account", async () => {
  const { connections, prefs, f, launch, rpc } = await connectionFixture();
  await connections.connect("antigravity", async () => {});
  const oldSource = compose(launch, prefs, { connections }).find(s => s.slot.provider === "antigravity")!;
  await connections.disconnect("antigravity"); f.status = status("second@example.invalid");
  await connections.connect("antigravity", async () => {});
  const calls = rpc.mock.calls.length;
  await expect(oldSource.quota!()).rejects.toMatchObject({ code: "notSignedIn" }); expect(rpc).toHaveBeenCalledTimes(calls);
  await expect(connections.quota("antigravity")).resolves.toMatchObject({ provider: "antigravity" });
});

it("applies the full-read deadline through discovery and pending RPCs", async () => {
  const { command, rpc } = fixture(), deadline = new AbortController();
  const timeout = vi.spyOn(AbortSignal, "timeout").mockReturnValue(deadline.signal);
  rpc.mockImplementation(async (_e, _method, signal) => new Promise((_resolve, reject) => signal.addEventListener("abort", () => reject(new Error(csrf)), { once: true })));
  const pending = readAntigravityDesktop(command, rpc, now), result = expect(pending).rejects.toThrow("Not signed in to Antigravity Desktop");
  await vi.waitFor(() => expect(rpc).toHaveBeenCalledTimes(1));
  deadline.abort(); await result;
  expect(timeout).toHaveBeenCalledWith(15000);
});
it("rejects a malformed disabled flag instead of publishing its fraction", () => {
  expect(() => antigravityDesktopQuota(summary({ disabled: "true" }), status(), now)).toThrow("No usage yet");
});

it("reuses display guards for provider labels and plan text before renderer/archive publication", () => {
  const raw = JSON.parse(summary()), identity = JSON.parse(status());
  raw.response.groups[0].displayName = email;
  raw.response.groups[0].buckets[0].displayName = "Bearer synthetic-token";
  identity.userStatus.userTier.name = email;
  const q = antigravityDesktopQuota(JSON.stringify(raw), JSON.stringify(identity), now);
  expect(q.windows[0].label).toBe("model-session"); expect(q.planType).toBeUndefined();
  expect(JSON.stringify(q)).not.toMatch(/synthetic@|Bearer/);
});

it("settles queued Antigravity consent rollback before shutdown returns", async () => {
  const { f, command, launch, prefs, connections } = await connectionFixture();
  const write = command.getMockImplementation()!;
  let started!: () => void, release!: () => void;
  const ready = new Promise<void>(resolve => { started = resolve; });
  const queued = new Promise<void>(resolve => { release = resolve; });
  command.mockImplementation(async (binary, args, options) => {
    if (binary === "/usr/bin/defaults" && args[0] === "write" && args[2] === "menuBarCompactEnabled") { started(); await queued; }
    return write(binary, args, options);
  });
  const set = prefs.set.bind(prefs);
  let other!: Promise<void>;
  vi.spyOn(prefs, "set").mockImplementation(async (key, value) => {
    const saved = set(key, value);
    if (key === "desktopAntigravityIdentity" && value !== "off") other = set("menuBarCompactEnabled", false);
    return saved;
  });
  const connecting = connections.connect("antigravity", async () => {}).catch(error => error);
  await ready;
  let stopped = false;
  const stopping = connections.stop(1).then(() => { stopped = true; });
  try {
    await new Promise(resolve => setTimeout(resolve, 20));
    expect(stopped).toBe(false);
  } finally { release(); await other; await connecting; await stopping; }
  expect((await connecting).message).toBe("Open one Antigravity Desktop account and sign in, then try connecting again");
  expect(f.saved.get("desktopAntigravityIdentity")).toBe("off");
  expect((await Preferences.load(launch, command)).values.desktopAntigravityIdentity).toBe("off");
});
