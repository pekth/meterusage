import { afterEach, expect, it, vi } from "vite-plus/test";
import { chmodSync, mkdtempSync, readFileSync, readdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ApiBillingFetch, apiBillingFetchErrors } from "../src/main/api-billing-fetch";
import { apiBillingPath, writeApiBilling } from "../src/main/providers/api-billing";
import { Coordinator } from "../src/main/coordinator";
import { Preferences } from "../src/main/preferences";
import { projectSettings } from "../src/main/ipc";
import type { Launch } from "../src/main/launch";
import type { ApiBillingProvider } from "../src/domain/api-billing";

const roots: string[] = [];
const now = Date.parse("2026-10-17T12:00:00Z"), start = Date.UTC(2026, 9, 1), day = 86400000;
const keys = { openai: "synthetic-openai-admin", anthropic: "synthetic-anthropic-admin" };
const snapshot = (provider: ApiBillingProvider, amountUSD = 1) => ({ schema: 1 as const, provider, capturedAt: now, monthStart: start, periodEnd: now, currency: "USD" as const, daily: [{ start, end: start + day, amountUSD }] });
const response = (provider: ApiBillingProvider) => Response.json({ has_more: false, private: "PRIVATE_RESPONSE", data: [provider === "openai"
  ? { start_time: start / 1000, end_time: (start + day) / 1000, results: [{ amount: { value: 2, currency: "usd" } }] }
  : { starting_at: new Date(start).toISOString(), ending_at: new Date(start + day).toISOString(), results: [{ amount: "300", currency: "USD" }] }] });
const files = (root: string): string[] => readdirSync(root, { withFileTypes: true }).flatMap(entry => entry.isDirectory() ? files(join(root, entry.name)) : [readFileSync(join(root, entry.name), "utf8")]);
afterEach(() => { vi.restoreAllMocks(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
async function setup(overrides: Partial<Launch> = {}) {
  vi.spyOn(Date, "now").mockReturnValue(now);
  const home = mkdtempSync(join(tmpdir(), "meterusage-api-fetch-")); roots.push(home);
  const isolated: Launch = { home, data: home, env: {}, demo: true, candidate: true };
  const prefs = await Preferences.load(isolated);
  await prefs.set("appearanceTheme", "dark");
  const launch: Launch = { ...isolated, demo: false, candidate: false, ...overrides };
  const coordinator = new Coordinator(launch, prefs, [], () => now);
  const refresh = vi.fn(() => coordinator.refresh());
  return { home, prefs, launch, coordinator, refresh };
}

it("fetches both providers with only their own key and persists only projected costs", async () => {
  const { home, launch, prefs, coordinator, refresh } = await setup();
  const fetcher = vi.fn<typeof fetch>(async url => response(new URL(String(url)).hostname === "api.openai.com" ? "openai" : "anthropic"));
  const billing = new ApiBillingFetch(launch, refresh, fetcher);
  const env = { ...process.env }, argv = [...process.argv], preferences = JSON.stringify(prefs.values);
  const stdout = vi.spyOn(process.stdout, "write"), stderr = vi.spyOn(process.stderr, "write"), log = vi.spyOn(console, "log");
  const replies = await Promise.all((["openai", "anthropic"] as const).map(provider => billing.run(provider, keys[provider])));
  expect(replies).toEqual([undefined, undefined]); expect(refresh).toHaveBeenCalledTimes(2);
  for (const provider of ["openai", "anthropic"] as const) {
    expect(coordinator.snapshot().apiBilling?.[provider]).toMatchObject({ status: "value", value: { provider, daily: [{ amountUSD: provider === "openai" ? 2 : 3 }] } });
    const [url, init] = fetcher.mock.calls.find(([url]) => new URL(String(url)).hostname === (provider === "openai" ? "api.openai.com" : "api.anthropic.com"))!;
    expect(new URL(String(url)).pathname).toBe(provider === "openai" ? "/v1/organization/costs" : "/v1/organizations/cost_report");
    const headers = new Headers(init?.headers);
    expect(headers.get(provider === "openai" ? "authorization" : "x-api-key")).toBe(provider === "openai" ? `Bearer ${keys.openai}` : keys.anthropic);
    expect(headers.has(provider === "openai" ? "x-api-key" : "authorization")).toBe(false);
    expect(init).toMatchObject({ redirect: "error", credentials: "omit", cache: "no-store", method: "GET" });
  }
  expect(process.env).toEqual(env); expect(process.argv).toEqual(argv); expect(JSON.stringify(prefs.values)).toBe(preferences);
  const published = JSON.stringify([coordinator.snapshot(), projectSettings(prefs.values, prefs.accounts, home, "settings"), coordinator.diagnostics(), coordinator.json(), replies, ...files(home), stdout.mock.calls, stderr.mock.calls, log.mock.calls]);
  for (const secret of [...Object.values(keys), "PRIVATE_RESPONSE", "adminKey"]) expect(published).not.toContain(secret);
});

it.each([{ demo: true }, { candidate: true }, { profile: "/synthetic" }, { codexTest: true }, { claudeTest: true }])("refuses restricted profiles before fetching (%j)", async mode => {
  const { launch, refresh } = await setup(mode), fetcher = vi.fn<typeof fetch>();
  await expect(new ApiBillingFetch(launch, refresh, fetcher).run("openai", keys.openai)).rejects.toThrow(apiBillingFetchErrors.profile);
  expect(fetcher).not.toHaveBeenCalled(); expect(refresh).not.toHaveBeenCalled();
});

it("refuses an in-flight duplicate, permits the other provider, and releases the lock", async () => {
  const { launch, refresh } = await setup();
  let finish!: (value: Response) => void;
  const fetcher = vi.fn<typeof fetch>().mockImplementationOnce(() => new Promise(resolve => { finish = resolve; })).mockImplementation(async () => response("anthropic"));
  const billing = new ApiBillingFetch(launch, refresh, fetcher), pending = billing.run("openai", keys.openai);
  await expect(billing.run("openai", "synthetic-other-key")).rejects.toThrow(apiBillingFetchErrors.busy);
  await billing.run("anthropic", keys.anthropic); expect(fetcher).toHaveBeenCalledTimes(2);
  finish(response("openai")); await pending;
  fetcher.mockResolvedValueOnce(response("openai")); await billing.run("openai", keys.openai);
  expect(fetcher).toHaveBeenCalledTimes(3);
});

it.each([401, 403, 500, "transport", "write"])("preserves the old snapshot, masks failure and releases the lock (%s)", async failure => {
  const { launch, home, coordinator, refresh } = await setup();
  writeApiBilling(home, snapshot("openai")); await coordinator.refresh();
  const oldFile = readFileSync(apiBillingPath(home, "openai"), "utf8"), oldState = coordinator.snapshot().apiBilling;
  const fetcher = vi.fn<typeof fetch>(async () => {
    if (failure === "transport") throw new Error(keys.openai);
    return typeof failure === "number" ? new Response(keys.openai, { status: failure }) : response("openai");
  });
  // A non-private existing snapshot must be refused by the atomic writer.
  if (failure === "write") chmodSync(apiBillingPath(home, "openai"), 0o644);
  const billing = new ApiBillingFetch(launch, refresh, fetcher);
  await expect(billing.run("openai", keys.openai)).rejects.toThrow(failure === 401 || failure === 403 ? apiBillingFetchErrors.auth : apiBillingFetchErrors.unavailable);
  expect(readFileSync(apiBillingPath(home, "openai"), "utf8")).toBe(oldFile); expect(coordinator.snapshot().apiBilling).toEqual(oldState); expect(refresh).not.toHaveBeenCalled();
  if (failure === "write") chmodSync(apiBillingPath(home, "openai"), 0o600);
  fetcher.mockResolvedValueOnce(response("openai")); await billing.run("openai", keys.openai);
  expect(refresh).toHaveBeenCalledOnce();
});

it("aborts on quit and rejects a late success without writing or refreshing", async () => {
  const { launch, home, refresh } = await setup();
  writeApiBilling(home, snapshot("openai"));
  const before = files(home);
  let finish!: (value: Response) => void;
  const fetcher = vi.fn<typeof fetch>(() => new Promise(resolve => { finish = resolve; }));
  const billing = new ApiBillingFetch(launch, refresh, fetcher), pending = billing.run("openai", keys.openai);
  const signal = fetcher.mock.calls[0][1]?.signal;
  billing.stop(); expect(signal?.aborted).toBe(true);
  finish(response("openai")); await expect(pending).rejects.toThrow(apiBillingFetchErrors.unavailable);
  await expect(billing.run("anthropic", keys.anthropic)).rejects.toThrow(apiBillingFetchErrors.unavailable);
  expect(fetcher).toHaveBeenCalledOnce(); expect(files(home)).toEqual(before); expect(refresh).not.toHaveBeenCalled();
});

it.each(["openai", "anthropic"] as const)("reuses only the selected legacy saved %s key without publishing it", async provider => {
  const { launch, refresh, home } = await setup();
  const saved = vi.fn(async (_provider: ApiBillingProvider, _signal: AbortSignal) => keys[provider]), fetcher = vi.fn<typeof fetch>(async () => response(provider));
  const billing = new ApiBillingFetch(launch, refresh, fetcher, saved);
  await billing.run(provider);
  expect(saved).toHaveBeenCalledExactlyOnceWith(provider, expect.any(AbortSignal));
  expect(new Headers(fetcher.mock.calls[0][1]?.headers).get(provider === "openai" ? "authorization" : "x-api-key")).toBe(provider === "openai" ? `Bearer ${keys[provider]}` : keys[provider]);
  expect(JSON.stringify(files(home))).not.toContain(keys[provider]);
  await billing.run(provider, "synthetic-new-key");
  expect(saved).toHaveBeenCalledTimes(1);
});

it("blocks saved-key access in isolated profiles and after quit", async () => {
  for (const mode of [{ demo: true }, { candidate: true }, { profile: "/synthetic" }, { codexTest: true }, { claudeTest: true }]) {
    const { launch, refresh } = await setup(mode), saved = vi.fn(async () => keys.openai);
    await expect(new ApiBillingFetch(launch, refresh, fetch, saved).run("openai")).rejects.toThrow(apiBillingFetchErrors.profile);
    expect(saved).not.toHaveBeenCalled();
  }
  const { launch, refresh } = await setup(), saved = vi.fn(async () => keys.openai);
  const billing = new ApiBillingFetch(launch, refresh, fetch, saved); billing.stop();
  await expect(billing.run("openai")).rejects.toThrow(apiBillingFetchErrors.unavailable);
  expect(saved).not.toHaveBeenCalled();
});

it.each(["missing", "denied", "cancelled"])("preserves snapshots and hides saved-key errors (%s)", async failure => {
  const { launch, refresh, home } = await setup();
  writeApiBilling(home, snapshot("openai")); const before = files(home);
  let finish!: (key: string) => void;
  const saved = vi.fn(async (_provider: ApiBillingProvider, _signal: AbortSignal) => {
    if (failure === "missing") return "";
    if (failure === "denied") throw new Error(keys.openai);
    return new Promise<string>(resolve => { finish = resolve; });
  });
  const fetcher = vi.fn<typeof fetch>(), billing = new ApiBillingFetch(launch, refresh, fetcher, saved);
  const pending = billing.run("openai");
  if (failure === "cancelled") {
    await expect(billing.run("openai")).rejects.toThrow(apiBillingFetchErrors.busy);
    billing.stop(); expect(saved.mock.calls[0][1].aborted).toBe(true); finish(keys.openai);
  }
  await expect(pending).rejects.toThrow(failure === "cancelled" ? apiBillingFetchErrors.unavailable : failure === "missing" ? apiBillingFetchErrors.savedMissing : apiBillingFetchErrors.savedAccess);
  expect(fetcher).not.toHaveBeenCalled(); expect(refresh).not.toHaveBeenCalled(); expect(files(home)).toEqual(before);
});
