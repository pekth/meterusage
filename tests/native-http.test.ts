import { expect, it, vi, afterEach } from "vite-plus/test";
import type { session } from "electron";
import { desktopHTTP } from "../src/main/native-http";
import { endpoints, claudeUsageURL, type Endpoint } from "../src/main/providers/transport";
import type { Launch } from "../src/main/launch";

const launch = { demo: false, codexTest: false } as Launch;
function fixture(persistent = false, storagePath: string | null = null) {
  const native = vi.fn<typeof fetch>(async () => Response.json({}));
  const fromPartition = vi.fn(() => ({ isPersistent: () => persistent, storagePath, fetch: native }));
  return { native, fromPartition, sessions: { fromPartition } as unknown as Pick<typeof session, "fromPartition"> };
}
afterEach(() => { vi.unstubAllGlobals(); vi.restoreAllMocks(); });
it("uses unique nonempty in-memory sessions and refuses persistent or disk-backed sessions", () => {
  const f = fixture(); desktopHTTP(launch, f.sessions); desktopHTTP(launch, f.sessions);
  const partitions = f.fromPartition.mock.calls.map(call => (call as unknown as [string])[0]);
  expect(new Set(partitions).size).toBe(2);
  expect(partitions.every(p => p.startsWith("meterusage-claude-") && !p.startsWith("persist:"))).toBe(true);
  for (const f of [fixture(true), fixture(false, "/synthetic/disk")]) expect(() => desktopHTTP(launch, f.sessions)).toThrow("not isolated");
});
it.each(["demo", "codexTest"] as const)("does not create or request a native session in %s", flag => {
  const f = fixture(); desktopHTTP({ ...launch, [flag]: true }, f.sessions);
  expect(f.fromPartition).not.toHaveBeenCalled(); expect(f.native).not.toHaveBeenCalled();
});
it("keeps other endpoints on Node and rejects allowlist escapes before either fetch", async () => {
  const f = fixture(), node = vi.fn<typeof fetch>(async () => Response.json({})); vi.stubGlobal("fetch", node);
  const http = desktopHTTP(launch, f.sessions), cookie = "sessionKey=synthetic";
  for (const url of [endpoints.claudeBootstrap, claudeUsageURL("22222222-2222-2222-2222-222222222222")]) await http(url, "claude", cookie);
  for (const url of Object.values(endpoints).filter(u => u !== endpoints.claudeBootstrap && u !== endpoints.cursorGrok && u !== endpoints.cursorIdentity)) await http(url, "claude", "synthetic-key");
  expect(f.native).toHaveBeenCalledTimes(2); expect(node).toHaveBeenCalledTimes(7);
  for (const url of ["http://claude.ai/api/bootstrap", "https://claude.ai:443/api/bootstrap", "https://claude.ai/api/bootstrap?x=1", "https://claude.ai/api/bootstrap/", "https://user@claude.ai/api/bootstrap", "https://claude.ai.evil.invalid/api/bootstrap", "https://claude.ai/api/organizations/no/usage", "http://127.0.0.1:1234/", endpoints.openRouterKey]) await expect(http(url as Endpoint, "claude", cookie)).rejects.toThrow();
  await expect(http(endpoints.claudeBootstrap, "grok", cookie)).rejects.toThrow();
  expect(f.native).toHaveBeenCalledTimes(2); expect(node).toHaveBeenCalledTimes(7);
  expect(node.mock.calls.every(([, init]) => init!.credentials === undefined)).toBe(true);
});
it.each(["status", "challenge", "overflow", "abort-after-headers"])("tears down native response bodies on %s", async failure => {
  const f = fixture(), controller = new AbortController(), cancel = vi.fn();
  f.native.mockImplementation(async () => {
    if (failure === "abort-after-headers") controller.abort();
    return new Response(new ReadableStream({ start(c) { c.enqueue(new Uint8Array(failure === "overflow" ? 1048577 : 1)); }, cancel }), { status: failure === "status" || failure === "challenge" ? 403 : 200, headers: failure === "challenge" ? { "cf-mitigated": "challenge" } : {} });
  });
  await expect(desktopHTTP(launch, f.sessions)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic", controller.signal)).rejects.toThrow();
  expect(cancel).toHaveBeenCalledOnce();
});
it("keeps the production deadline and caller cancellation on native requests", async () => {
  const timeout = vi.spyOn(AbortSignal, "timeout"), f = fixture(), controller = new AbortController();
  f.native.mockImplementation(async (_url, init) => new Promise((_resolve, reject) => init!.signal!.addEventListener("abort", () => reject(new Error("private")), { once: true })));
  const pending = desktopHTTP(launch, f.sessions)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic", controller.signal);
  expect(timeout).toHaveBeenCalledWith(30000); controller.abort(); await expect(pending).rejects.toThrow();
  const before = f.native.mock.calls.length;
  await expect(desktopHTTP(launch, f.sessions)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic", controller.signal)).rejects.toThrow();
  expect(f.native).toHaveBeenCalledTimes(before);
});
