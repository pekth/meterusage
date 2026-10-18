import { afterEach, expect, it, vi } from "vite-plus/test";
import { chmodSync, fstatSync, linkSync, mkdtempSync, mkdirSync, readFileSync, readdirSync, realpathSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { apiBillingPath, readApiBilling, writeApiBilling } from "../src/main/providers/api-billing";
import { ApiBillingFetch, apiBillingFetchErrors } from "../src/main/api-billing-fetch";
import type { ApiBillingSnapshot } from "../src/domain/api-billing";
import type { Launch } from "../src/main/launch";

vi.mock("node:fs", async original => { const fs = await original<typeof import("node:fs")>(); return { ...fs, fstatSync: vi.fn(fs.fstatSync) }; });
const roots: string[] = [], now = Date.parse("2026-10-17T12:00:00Z"), start = Date.UTC(2026, 9, 1), day = 86400000;
const temp = () => { const home = realpathSync(mkdtempSync(join(tmpdir(), "meterusage-windows-api-"))); roots.push(home); return home; };
const snapshot = (amountUSD = 1): ApiBillingSnapshot => ({ schema: 1, provider: "openai", capturedAt: now, monthStart: start, periodEnd: now, currency: "USD", daily: [{ start, end: start + day, amountUSD }] });
afterEach(() => { vi.restoreAllMocks(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

it("stores only numeric billing in configured Windows app data and replaces atomically", () => {
  const home = temp(), data = join(home, "AppData", "Roaming", "MeterUsage"), path = apiBillingPath(home, "openai", data);
  writeApiBilling(home, { ...snapshot(), apiKey: "PRIVATE_KEY", account: "PRIVATE_ACCOUNT" } as ApiBillingSnapshot, data, "win32");
  chmodSync(path, 0o644); chmodSync(dirname(path), 0o755);
  expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "value", stale: false, value: snapshot() });
  writeApiBilling(home, snapshot(2), data, "win32");
  expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "value", stale: false, value: snapshot(2) });
  expect(readFileSync(path, "utf8")).not.toContain("PRIVATE"); expect(readdirSync(dirname(path))).toEqual(["openai.json"]);
});

it("rejects Windows junction ancestors before following them", () => {
  const home = temp(), outside = temp(), parent = join(home, "AppData"), data = join(parent, "Roaming", "MeterUsage");
  symlinkSync(outside, parent, process.platform === "win32" ? "junction" : "dir");
  expect(() => writeApiBilling(home, snapshot(), data, "win32")).toThrow();
  expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "missing", code: "unavailable" });
  expect(readdirSync(outside)).toEqual([]);
});

it.each(["hardlink", "directory", "oversized"])("rejects an unsafe Windows snapshot: %s", failure => {
  const home = temp(), data = join(home, "app-data"), path = apiBillingPath(home, "openai", data);
  writeApiBilling(home, snapshot(), data, "win32");
  if (failure === "hardlink") linkSync(path, join(home, "linked.json"));
  else if (failure === "directory") { rmSync(path); mkdirSync(path); }
  else writeFileSync(path, " ".repeat(1048577));
  expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "missing", code: "unavailable" });
  if (failure !== "oversized") expect(() => writeApiBilling(home, snapshot(), data, "win32")).toThrow();
});

it("rejects a changed Windows descriptor identity", async () => {
  const home = temp(), data = join(home, "app-data"), fs = await vi.importActual<typeof import("node:fs")>("node:fs");
  writeApiBilling(home, snapshot(), data, "win32");
  vi.mocked(fstatSync).mockImplementationOnce(fd => { const stat = fs.fstatSync(fd); stat.ino++; return stat; });
  expect(readApiBilling(home, "openai", now, data, "win32")).toEqual({ status: "missing", code: "unavailable" });
});

it("requires a pasted Windows key, never saves it and honors configured app data", async () => {
  vi.spyOn(Date, "now").mockReturnValue(now);
  const home = temp(), data = join(home, "app-data"), launch: Launch = { home, data, env: {}, demo: false, candidate: false, platform: "win32" };
  const refresh = vi.fn(async () => {}), fetcher = vi.fn<typeof fetch>(async () => Response.json({ has_more: false, private: "PRIVATE_RESPONSE", data: [{ start_time: start / 1000, end_time: (start + day) / 1000, results: [{ amount: { value: 2, currency: "usd" } }] }] }));
  const billing = new ApiBillingFetch(launch, refresh, fetcher);
  await expect(billing.run("openai")).rejects.toThrow(apiBillingFetchErrors.savedMissing);
  expect(fetcher).not.toHaveBeenCalled(); expect(refresh).not.toHaveBeenCalled(); expect(readdirSync(home)).toEqual([]);
  await billing.run("openai", "synthetic-admin-key");
  const raw = readFileSync(apiBillingPath(home, "openai", data), "utf8");
  expect(JSON.parse(raw)).toMatchObject({ provider: "openai", daily: [{ amountUSD: 2 }] });
  expect(raw).not.toMatch(/synthetic|PRIVATE/); expect(refresh).toHaveBeenCalledOnce();
});
