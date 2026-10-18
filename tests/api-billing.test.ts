import { afterEach, describe, expect, it, vi } from "vite-plus/test";
import { appendFileSync, chmodSync, fstatSync, linkSync, lstatSync, mkdtempSync, readFileSync, readdirSync, readSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { type ApiBillingProvider, type ApiBillingSnapshot } from "../src/domain/api-billing";
import { apiBillingPath, collectApiBilling, parseApiBillingSnapshot, readApiBilling, writeApiBilling } from "../src/main/providers/api-billing";
import { runApiUsageHelper } from "../src/main/api-usage-helper";

const now = Date.parse("2026-10-16T12:00:00Z"), start = Date.parse("2026-10-01T00:00:00Z"), day = 86400000;
const roots: string[] = [];
vi.mock("node:fs", async original => { const fs = await original<typeof import("node:fs")>(); return { ...fs, readSync: vi.fn(fs.readSync), fstatSync: vi.fn(fs.fstatSync) }; });
const temp = () => { const root = realpathSync(mkdtempSync(join(tmpdir(), "meterusage-api-fixture-"))); roots.push(root); return root; };
afterEach(() => { vi.useRealTimers(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const snapshot = (provider: ApiBillingProvider = "openai"): ApiBillingSnapshot => ({ schema: 1, provider, capturedAt: now, monthStart: start, periodEnd: now, currency: "USD", daily: [{ start, end: start + day, amountUSD: 1.25 }] });
const bucket = (provider: ApiBillingProvider, at = start, value: number | string = provider === "openai" ? 1.25 : "125.00") => provider === "openai"
  ? { start_time: at / 1000, end_time: (at + day) / 1000, results: [{ amount: { value, currency: "usd" }, project_id: "PRIVATE_PROJECT", api_key_id: "PRIVATE_KEY_ID" }] }
  : { starting_at: new Date(at).toISOString(), ending_at: new Date(at + day).toISOString(), results: [{ amount: value, currency: "USD", workspace_id: "PRIVATE_WORKSPACE", description: "PRIVATE_DESCRIPTION" }] };
const response = (provider: ApiBillingProvider) => ({ data: [bucket(provider)], has_more: false, next_page: null, organization_id: "PRIVATE_ORGANIZATION" });
const jsonResponse = (value: unknown, status = 200) => new Response(JSON.stringify(value), { status });

describe("API billing snapshot privacy and filesystem boundary", () => {
  it.each(["openai", "anthropic"] as const)("writes and reads an owner-only identifier-free %s snapshot without advancing capture time", provider => {
    const home = temp(), value = snapshot(provider);
    writeApiBilling(home, { ...value, organization_id: "PRIVATE_ORG", daily: [{ ...value.daily[0], workspace_id: "PRIVATE_WORKSPACE" }] } as unknown as ApiBillingSnapshot);
    const file = apiBillingPath(home, provider), raw = readFileSync(file, "utf8");
    expect(raw).not.toContain("PRIVATE");
    if (process.platform !== "win32") { expect(lstatSync(file).mode & 0o777).toBe(0o600); expect(lstatSync(dirname(file)).mode & 0o777).toBe(0o700); }
    expect(readApiBilling(home, provider, now + 60000)).toEqual({ status: "value", value, stale: false });
    expect(readApiBilling(home, provider, now + day)).toEqual({ status: "value", value, stale: true });
    expect(readdirSync(dirname(file))).toEqual([`${provider}.json`]);
  });
  it("marks the prior UTC month stale even when less than 24 hours old", () => {
    const home = temp(), capturedAt = Date.parse("2026-10-31T23:59:00Z"), value = { ...snapshot(), capturedAt, periodEnd: capturedAt };
    writeApiBilling(home, value);
    expect(readApiBilling(home, "openai", capturedAt + 120000)).toEqual({ status: "value", value, stale: true });
  });
  it("distinguishes missing and invalid snapshots without reading credentials", () => {
    const home = temp(); expect(readApiBilling(home, "openai", now)).toEqual({ status: "missing", code: "notConfigured" });
    writeApiBilling(home, snapshot()); writeFileSync(apiBillingPath(home, "openai"), "invalid");
    expect(readApiBilling(home, "openai", now)).toEqual({ status: "missing", code: "unavailable" });
  });
  it.skipIf(process.platform === "win32").each([0o644, 0o666])("rejects public snapshot permissions %s", mode => {
    const home = temp(); writeApiBilling(home, snapshot()); chmodSync(apiBillingPath(home, "openai"), mode);
    expect(readApiBilling(home, "openai", now).status).toBe("missing");
    expect(() => writeApiBilling(home, snapshot())).toThrow();
  });
  it.skipIf(process.platform === "win32")("rejects symlink files and directories without changing their targets", () => {
    const home = temp(), outside = temp(), secret = join(outside, "private.json"); writeFileSync(secret, "PRIVATE_DATA", { mode: 0o600 });
    writeApiBilling(home, snapshot()); rmSync(apiBillingPath(home, "openai")); symlinkSync(secret, apiBillingPath(home, "openai"));
    expect(readApiBilling(home, "openai", now).status).toBe("missing"); expect(() => writeApiBilling(home, snapshot())).toThrow();
    rmSync(join(home, "Library"), { recursive: true }); symlinkSync(outside, join(home, "Library"));
    expect(() => writeApiBilling(home, snapshot())).toThrow(); expect(readApiBilling(home, "openai", now).status).toBe("missing");
    expect(readFileSync(secret, "utf8")).toBe("PRIVATE_DATA"); expect(readdirSync(outside)).toEqual(["private.json"]);
  });
  it.skipIf(process.platform === "win32")("rejects public directories and oversized files", () => {
    const home = temp(); writeApiBilling(home, snapshot()); const path = apiBillingPath(home, "openai");
    chmodSync(dirname(path), 0o755); expect(readApiBilling(home, "openai", now).status).toBe("missing");
    chmodSync(dirname(path), 0o700); writeFileSync(path, " ".repeat(1048577)); expect(readApiBilling(home, "openai", now).status).toBe("missing");
  });
  it.each([1, 2 * 1048576])("rejects a file that grows by %s bytes after inspection with a bounded read", async growth => {
    const fs = await vi.importActual<typeof import("node:fs")>("node:fs"), home = temp();
    writeApiBilling(home, snapshot()); const path = apiBillingPath(home, "openai");
    vi.mocked(readSync).mockImplementationOnce((fd, buffer, ...args) => {
      appendFileSync(path, " ".repeat(growth));
      expect(buffer.byteLength).toBe(1048577);
      return fs.readSync(fd, buffer, ...args);
    });
    expect(readApiBilling(home, "openai", now)).toEqual({ status: "missing", code: "unavailable" });
  });
  it.each([
    { provider: "anthropic" }, { schema: 2 }, { currency: "EUR" }, { capturedAt: now + 60001 }, { periodEnd: now + 1 }, { periodEnd: start }, { monthStart: start + day },
    { daily: [null] }, { daily: [[]] }, { daily: [{ start: start - day, end: start, amountUSD: 1 }] },
    { daily: [{ start: now + day, end: now + 2 * day, amountUSD: 1 }] },
    { daily: [{ start, end: start + day, amountUSD: -1 }] }, { daily: [{ start, end: start + day, amountUSD: "1" }] },
    { daily: [{ start, end: start + 2 * day, amountUSD: 1 }] }, { daily: [snapshot().daily[0], snapshot().daily[0]] },
  ])("rejects invalid identity, timestamps, amounts and buckets %j", patch => {
    expect(() => parseApiBillingSnapshot(JSON.stringify({ ...snapshot(), ...patch }), "openai", now)).toThrow();
  });
  it("rejects duplicate JSON keys and preserves an old snapshot after invalid replacement", () => {
    const home = temp(); writeApiBilling(home, snapshot()); const old = readFileSync(apiBillingPath(home, "openai"), "utf8");
    expect(() => parseApiBillingSnapshot(old.replace('"schema":1', '"schema":1,"schema":1'), "openai", now)).toThrow();
    expect(() => writeApiBilling(home, { ...snapshot(), currency: "EUR" } as unknown as ApiBillingSnapshot)).toThrow();
    expect(readFileSync(apiBillingPath(home, "openai"), "utf8")).toBe(old);
  });
  it.each(process.platform === "win32" ? ["win32"] as const : ["darwin", "win32"] as const)("rejects hard links and oversized reads under %s storage policy", platform => {
    const home = temp(), data = join(home, "configured-data");
    writeApiBilling(home, snapshot(), data, platform);
    const path = apiBillingPath(home, "openai", data), linked = join(home, "linked.json");
    linkSync(path, linked);
    expect(readApiBilling(home, "openai", now, data, platform)).toEqual({ status: "missing", code: "unavailable" });
    expect(() => writeApiBilling(home, snapshot(), data, platform)).toThrow();
    rmSync(linked); writeFileSync(path, " ".repeat(1048577));
    expect(readApiBilling(home, "openai", now, data, platform)).toEqual({ status: "missing", code: "unavailable" });
  });
  it("uses Windows inherited permissions while retaining projection and atomic replacement", () => {
    const home = temp(), data = join(home, "AppData", "Roaming", "MeterUsage");
    const value = { ...snapshot(), apiKey: "PRIVATE_KEY", response: "PRIVATE_RESPONSE" } as unknown as ApiBillingSnapshot;
    writeApiBilling(home, value, data, "win32");
    const file = apiBillingPath(home, "openai", data);
    chmodSync(file, 0o644); chmodSync(dirname(file), 0o755);
    expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "value", value: snapshot(), stale: false });
    const next = { ...snapshot(), daily: [{ ...snapshot().daily[0], amountUSD: 2 }] };
    writeApiBilling(home, next, data, "win32");
    expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "value", value: next, stale: false });
    expect(readFileSync(file, "utf8")).not.toContain("PRIVATE"); expect(readdirSync(dirname(file))).toEqual(["openai.json"]);
    if (process.platform !== "win32") expect(readApiBilling(home, "openai", now, data, "darwin").status).toBe("missing");
  });
  it("rejects Windows junction/symlink ancestors before creating or reading snapshot files", () => {
    const home = temp(), outside = temp(), parent = join(home, "AppData");
    symlinkSync(outside, parent, process.platform === "win32" ? "junction" : "dir");
    const data = join(parent, "Roaming", "MeterUsage");
    expect(() => writeApiBilling(home, snapshot(), data, "win32")).toThrow();
    expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "missing", code: "unavailable" });
    expect(readdirSync(outside)).toEqual([]);
  });
  it.skipIf(process.platform === "win32")("rejects a Windows snapshot symlink without opening or replacing its target", () => {
    const home = temp(), data = join(home, "app-data"), outside = join(home, "private.json");
    writeApiBilling(home, snapshot(), data, "win32");
    const file = apiBillingPath(home, "openai", data);
    writeFileSync(outside, "PRIVATE_DATA"); rmSync(file); symlinkSync(outside, file);
    expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "missing", code: "unavailable" });
    expect(() => writeApiBilling(home, snapshot(), data, "win32")).toThrow();
    expect(readFileSync(outside, "utf8")).toBe("PRIVATE_DATA");
  });
  it("rejects a changed Windows file descriptor identity", async () => {
    const home = temp(), data = join(home, "app-data");
    writeApiBilling(home, snapshot(), data, "win32");
    const fs = await vi.importActual<typeof import("node:fs")>("node:fs");
    vi.mocked(fstatSync).mockImplementationOnce(fd => { const stat = fs.fstatSync(fd); stat.ino++; return stat; });
    expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "missing", code: "unavailable" });
  });
});

describe("official API cost contracts", () => {
  it.each(["openai", "anthropic"] as const)("fetches only fixed %s aggregate cost endpoints with the documented auth and units", async provider => {
    const requests: { url: URL; init: RequestInit }[] = [];
    const fetcher = vi.fn(async (url: string | URL | Request, init?: RequestInit) => { requests.push({ url: new URL(String(url)), init: init! }); return jsonResponse(response(provider)); }) as unknown as typeof fetch;
    expect(await collectApiBilling(provider, "synthetic-admin-key", now, fetcher)).toEqual(snapshot(provider));
    const { url, init } = requests[0];
    expect(url.origin + url.pathname).toBe(provider === "openai" ? "https://api.openai.com/v1/organization/costs" : "https://api.anthropic.com/v1/organizations/cost_report");
    expect(url.searchParams.get(provider === "openai" ? "start_time" : "starting_at")).toBe(provider === "openai" ? String(start / 1000) : new Date(start).toISOString());
    expect(url.searchParams.get("bucket_width")).toBe("1d"); expect(url.searchParams.get("limit")).toBe("31"); expect(url.searchParams.has("group_by")).toBe(false);
    expect(init).toMatchObject({ method: "GET", redirect: "error", credentials: "omit", cache: "no-store" });
    expect(init.headers).toMatchObject(provider === "openai" ? { Authorization: "Bearer synthetic-admin-key" } : { "x-api-key": "synthetic-admin-key", "anthropic-version": "2023-06-01" });
    expect(JSON.stringify(await collectApiBilling(provider, "synthetic-admin-key", now, fetcher))).not.toMatch(/PRIVATE|synthetic-admin|token|estimate/i);
  });
  it.each(["openai", "anthropic"] as const)("honors %s pagination and reported zero", async provider => {
    const urls: string[] = [];
    const fetcher = vi.fn(async (url: string | URL | Request) => { urls.push(String(url)); return urls.length === 1 ? jsonResponse({ data: [bucket(provider)], has_more: true, next_page: "cursor-one" }) : jsonResponse({ data: [bucket(provider, start + day, provider === "openai" ? 0 : "0")], has_more: false }); }) as unknown as typeof fetch;
    const value = await collectApiBilling(provider, "synthetic", now, fetcher);
    expect(value.daily).toHaveLength(2); expect(value.daily[1].amountUSD).toBe(0); expect(new URL(urls[1]).searchParams.get("page")).toBe("cursor-one");
  });
  it.each(["openai", "anthropic"] as const)("keeps empty %s cost buckets unknown while preserving explicit zero amounts", async provider => {
    const empty = { ...bucket(provider), results: [] };
    const collect = (data: unknown[]) => collectApiBilling(provider, "synthetic", now, vi.fn(async () => jsonResponse({ data, has_more: false })) as unknown as typeof fetch);
    expect((await collect([empty])).daily).toEqual([]);
    expect((await collect([empty, bucket(provider, start + day, provider === "openai" ? 0 : "0")])).daily).toEqual([{ start: start + day, end: start + 2 * day, amountUSD: 0 }]);
  });
  it("rejects repeated pagination cursors", async () => {
    const fetcher = vi.fn(async () => jsonResponse({ data: [], has_more: true, next_page: "same" })) as unknown as typeof fetch;
    await expect(collectApiBilling("openai", "synthetic", now, fetcher)).rejects.toThrow("API billing data unavailable"); expect(fetcher).toHaveBeenCalledTimes(2);
  });
  it.each([401, 403, 429, 500])("never exposes HTTP %s response bodies", async status => {
    const fetcher = vi.fn(async () => jsonResponse({ error: "PRIVATE_BODY synthetic-admin-key" }, status)) as unknown as typeof fetch;
    await expect(collectApiBilling("openai", "synthetic-admin-key", now, fetcher)).rejects.toThrow(status === 401 || status === 403 ? "API billing authentication failed" : "API billing data unavailable");
  });
  it.each([
    { data: [null], has_more: false }, { data: [{ ...bucket("openai"), results: [null] }], has_more: false },
    { data: [{ ...bucket("openai"), results: [{ amount: { value: 1, currency: "eur" } }] }], has_more: false },
    { data: [{ ...bucket("openai"), start_time: start / 1000 - 86400 }], has_more: false },
    { data: [bucket("openai"), bucket("openai")], has_more: false }, { data: [], has_more: true }, { data: [] },
  ])("fails closed for malformed or unsupported reports %j", async raw => {
    await expect(collectApiBilling("openai", "synthetic", now, vi.fn(async () => jsonResponse(raw)) as unknown as typeof fetch)).rejects.toThrow("API billing data unavailable");
  });
  it("bounds response bytes and sanitizes transport failures", async () => {
    await expect(collectApiBilling("openai", "synthetic", now, vi.fn(async () => new Response(" ".repeat(1048577))) as unknown as typeof fetch)).rejects.toThrow("API billing data unavailable");
    await expect(collectApiBilling("openai", "synthetic", now, vi.fn(async () => { throw new Error("PRIVATE_TRANSPORT"); }) as unknown as typeof fetch)).rejects.toThrow("API billing data unavailable");
  });
  it.each(["redirected", "length", "failure"])("cancels %s responses before parsing or retaining their bodies", async failure => {
    let cancelled = false;
    const stream = new ReadableStream({ cancel() { cancelled = true; } });
    const raw = new Response(stream, { status: failure === "failure" ? 500 : 200, headers: failure === "length" ? { "content-length": "1048577" } : {} });
    if (failure === "redirected") Object.defineProperty(raw, "redirected", { value: true });
    await expect(collectApiBilling("openai", "synthetic", now, vi.fn(async () => raw) as unknown as typeof fetch)).rejects.toThrow("API billing data unavailable");
    expect(cancelled).toBe(true);
  });
  it("rejects malformed private response text without persisting a report", async () => {
    vi.useFakeTimers(); vi.setSystemTime(now); const home = temp();
    await expect(runApiUsageHelper(["openai"], { OPENAI_ADMIN_KEY: "synthetic-admin-key" }, home, vi.fn(async () => new Response('{"PRIVATE_ORG":"PRIVATE_KEY" broken')) as unknown as typeof fetch)).rejects.toThrow("API billing data unavailable");
    expect(readdirSync(home)).toEqual([]);
  });
  it("rejects invalid credentials before making any request", async () => {
    const fetcher = vi.fn();
    for (const key of ["", "invalid\nheader", "x".repeat(8193)]) await expect(collectApiBilling("openai", key, now, fetcher)).rejects.toThrow();
    expect(fetcher).not.toHaveBeenCalled();
  });
  it("uses only helper environment credentials and preserves prior snapshots on failure", async () => {
    vi.useFakeTimers(); vi.setSystemTime(now);
    const home = temp(), env = { OPENAI_ADMIN_KEY: "synthetic-admin-key" };
    const fetcher = vi.fn(async () => jsonResponse(response("openai"))) as unknown as typeof fetch;
    await runApiUsageHelper(["openai"], env, home, fetcher); expect(env.OPENAI_ADMIN_KEY).toBeUndefined();
    const path = apiBillingPath(home, "openai"), prior = readFileSync(path, "utf8");
    await expect(runApiUsageHelper(["openai"], { OPENAI_ADMIN_KEY: "synthetic-admin-key" }, home, vi.fn(async () => jsonResponse({ private: "PRIVATE_FAILURE" }, 401)) as unknown as typeof fetch)).rejects.toThrow("authentication failed");
    expect(readFileSync(path, "utf8")).toBe(prior);
    await expect(runApiUsageHelper(["openai", "forbidden-key-argument"], env, home, fetcher)).rejects.toThrow("Usage:");
    await expect(runApiUsageHelper(["openai"], {}, home, fetcher)).rejects.toThrow("missing from helper environment");
  });
});
