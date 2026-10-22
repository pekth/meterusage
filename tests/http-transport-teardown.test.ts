import { afterEach, expect, it, vi } from "vite-plus/test";
import { Unavailable } from "../src/domain/models";
import { ClaudeBrowserVerification, endpoints, httpTransport, type Endpoint } from "../src/main/providers/transport";

// Synthetic adapter: cancelling its body leaves the request open; only abort closes it.
function fixture(bytes = 1048577, status = 200, cleanupError?: Error) {
  let signal: AbortSignal, requestOpen = true;
  const events: string[] = [];
  const cancel = vi.fn(async () => { events.push("cancel"); if (cleanupError) throw cleanupError; });
  const response = new Response(new ReadableStream<Uint8Array>({ start(c) { c.enqueue(new Uint8Array(bytes)); }, cancel }), { status });
  const fetcher = vi.fn<typeof fetch>(async (_url, init) => {
    signal = init!.signal!;
    signal.addEventListener("abort", () => { requestOpen = false; events.push("abort"); }, { once: true });
    return response;
  });
  return { fetcher, response, events, cancel, get signal() { return signal; }, get requestOpen() { return requestOpen; } };
}
afterEach(() => { vi.restoreAllMocks(); });

it("aborts overflow before awaiting reader cancellation", async () => {
  const f = fixture();
  let release!: () => void, started!: () => void;
  const cancellation = new Promise<void>(resolve => { release = resolve; });
  const cancelling = new Promise<void>(resolve => { started = resolve; });
  f.cancel.mockImplementation(async () => { f.events.push("cancel"); started(); await cancellation; });
  const pending = httpTransport(f.fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic").catch(error => error);
  await cancelling;
  try { expect(f.requestOpen).toBe(false); expect(f.signal.aborted).toBe(true); expect(f.events).toEqual(["abort", "cancel"]); }
  finally { release(); await pending; }
  expect(await pending).toMatchObject({ code: "failed" });
});

it.each([401, 403, 500])("aborts a rejected %s response before body cancellation", async status => {
  const f = fixture(1, status);
  await expect(httpTransport(f.fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic")).rejects.toMatchObject({ code: status === 500 ? "failed" : "notSignedIn" });
  expect(f.requestOpen).toBe(false); expect(f.events).toEqual(["abort", "cancel"]); expect(f.cancel).toHaveBeenCalledOnce();
});

it("preserves the explicit challenge when body cleanup rejects", async () => {
  const f = fixture(1, 403, new Error("SYNTHETIC_CLEANUP")); f.response.headers.set("cf-mitigated", "challenge");
  await expect(httpTransport(f.fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic")).rejects.toBeInstanceOf(ClaudeBrowserVerification);
  expect(f.events).toEqual(["abort", "cancel"]);
});

it("preserves overflow failure when reader cleanup rejects with another Unavailable", async () => {
  const f = fixture(1048577, 200, new Unavailable("dataNotFound", "synthetic cleanup"));
  await expect(httpTransport(f.fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic")).rejects.toMatchObject({ code: "failed" });
  expect(f.requestOpen).toBe(false); expect(f.events).toEqual(["abort", "cancel"]);
});

it("preserves the original Unavailable object if a read and its cleanup both fail", async () => {
  const f = fixture(1, 200, new Error("SYNTHETIC_CLEANUP")), original = new Unavailable("notSignedIn", "Claude Desktop");
  const reader = f.response.body!.getReader();
  vi.spyOn(reader, "read").mockRejectedValue(original); vi.spyOn(f.response.body!, "getReader").mockReturnValue(reader);
  await expect(httpTransport(f.fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic")).rejects.toBe(original);
  expect(f.events).toEqual(["abort", "cancel"]);
});

it.each(["caller", "deadline"])("retains %s abort during an outstanding body read", async cause => {
  const controller = new AbortController(), timeout = vi.spyOn(AbortSignal, "timeout");
  if (cause === "deadline") timeout.mockReturnValue(controller.signal);
  let signal!: AbortSignal, reading!: () => void;
  const started = new Promise<void>(resolve => { reading = resolve; });
  const fetcher = vi.fn<typeof fetch>(async (_url, init) => {
    signal = init!.signal!;
    return new Response(new ReadableStream({ start(c) { signal.addEventListener("abort", () => c.error(new Error("SYNTHETIC_ABORT")), { once: true }); }, pull() { reading(); } }));
  });
  const pending = httpTransport(fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic", cause === "caller" ? controller.signal : undefined);
  const rejected = expect(pending).rejects.toMatchObject({ code: "failed" });
  await started; controller.abort(); await rejected;
  expect(signal.aborted).toBe(true); expect(timeout).toHaveBeenCalledWith(30000);
});

const routes = [
  { url: endpoints.claudeBootstrap, provider: "claude", key: "sessionKey=synthetic", limit: 1048576 },
  { url: endpoints.cursorGrok, provider: "grok", key: "WorkosCursorSessionToken=synthetic%3A%3Aa.b.c", limit: 1048576 },
  { url: endpoints.openRouterKey, provider: "openRouter", key: "synthetic", limit: 16 * 1048576 },
] as const;
it.each(routes)("keeps the exact $provider byte limit and successful requests un-aborted", async ({ url, provider, key, limit }) => {
  const payload = "x".repeat(limit), timeout = vi.spyOn(AbortSignal, "timeout");
  let signal!: AbortSignal;
  const fetcher = vi.fn<typeof fetch>(async (_url, init) => { signal = init!.signal!; return new Response(payload); });
  expect(await httpTransport(fetcher)(url, provider, key)).toBe(payload);
  expect(signal.aborted).toBe(false); expect(timeout).toHaveBeenCalledWith(30000);
  expect(fetcher.mock.calls[0][1]).toMatchObject({ redirect: "error", cache: "no-store", headers: { Accept: "application/json", "User-Agent": "meterusage/0.2.41" } });
});
it.each(routes)("aborts $provider at one byte over its existing limit", async ({ url, provider, key, limit }) => {
  const f = fixture(limit + 1);
  await expect(httpTransport(f.fetcher)(url, provider, key)).rejects.toMatchObject({ code: "failed" });
  expect(f.events).toEqual(["abort", "cancel"]); expect(f.requestOpen).toBe(false);
});

it("does not fetch for a pre-aborted caller or an escaped endpoint", async () => {
  const controller = new AbortController(); controller.abort(); const f = fixture();
  await expect(httpTransport(f.fetcher)(endpoints.claudeBootstrap, "claude", "sessionKey=synthetic", controller.signal)).rejects.toThrow();
  await expect(httpTransport(f.fetcher)("https://example.invalid" as Endpoint, "claude", "sessionKey=synthetic")).rejects.toThrow();
  expect(f.fetcher).not.toHaveBeenCalled();
});
