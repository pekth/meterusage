import { describe, expect, it } from "vite-plus/test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { QuotaActivityStore, trackingWindow } from "../src/main/quota-activity";
import { quotaHeatmapCells, heatmapCells } from "../src/domain/overview";
import { quota, window, localDay, tokens } from "../src/domain/models";

const day1 = new Date(2026, 9, 20, 12).getTime(), day2 = day1 + 86_400_000, reset = day1 + 5 * 86_400_000;
const claude = (weekly: number, resetsAt = reset) => quota("claude", [window("5-hour", 50, undefined, 300), window("Weekly · All models", weekly, resetsAt, 10080)]);
const store = () => new QuotaActivityStore(join(mkdtempSync(join(tmpdir(), "quota-activity-")), "quota-activity.json"));

describe("quota activity", () => {
  it("tracks the weekly all-models window", () => {
    expect(trackingWindow(claude(3))?.label).toBe("Weekly · All models");
  });
  it("treats the first reading as a baseline and adds rises to their day", () => {
    const s = store();
    s.record("claude", claude(0), day1);
    expect(s.days("claude")).toEqual([]);
    s.record("claude", claude(4), day1 + 600_000);
    s.record("claude", claude(5), day1 + 1_200_000);
    s.record("claude", claude(11), day2);
    expect(s.days("claude")).toEqual([{ day: localDay(day1), percent: 5 }, { day: localDay(day2), percent: 6 }]);
  });
  it("seeds the current window's usage over its elapsed days as estimated", () => {
    const s = store(), resetsAt = day1 + 4 * 86_400_000; // window began three days before day1
    s.record("claude", claude(8, resetsAt), day1);
    const days = s.days("claude");
    expect(days.length).toBe(4);
    expect(days.every(d => d.estimated)).toBe(true);
    expect(days.reduce((n, d) => n + d.percent, 0)).toBeCloseTo(8);
  });
  it("seeds a pre-seeding series once without double counting recorded rises", () => {
    const path = join(mkdtempSync(join(tmpdir(), "quota-activity-")), "q.json"), resetsAt = day1 + 6 * 86_400_000;
    writeFileSync(path, JSON.stringify({ claude: { label: "Weekly · All models", lastPercent: 7, lastResetsAt: resetsAt, days: [{ day: localDay(day1), percent: 1 }] } }));
    const s = new QuotaActivityStore(path);
    s.record("claude", claude(7, resetsAt), day1 + 60_000);
    expect(s.days("claude").reduce((n, d) => n + d.percent, 0)).toBeCloseTo(7);
    s.record("claude", claude(7, resetsAt), day1 + 120_000);
    expect(s.days("claude").reduce((n, d) => n + d.percent, 0)).toBeCloseTo(7);
  });
  it("counts a new window from zero after rollover", () => {
    const s = store();
    s.record("grok", claude(0, day1), day1 - 60_000);
    s.record("grok", claude(80, day1), day1 - 30_000);
    s.record("grok", claude(3, day1 + 7 * 86_400_000), day1 + 60_000);
    expect(s.days("grok").map(d => d.percent)).toEqual([83]);
  });
  it("keeps providers separate and persists", () => {
    const path = join(mkdtempSync(join(tmpdir(), "quota-activity-")), "q.json"), s = new QuotaActivityStore(path);
    s.record("claude", claude(0), day1); s.record("claude", claude(3), day1 + 60_000);
    s.record("codex", claude(0), day1);
    const reloaded = new QuotaActivityStore(path);
    expect(reloaded.days("claude").map(d => d.percent)).toEqual([3]);
    expect(reloaded.days("codex")).toEqual([]);
  });
  it("builds 26-week cells in each mode", () => {
    const days = [{ day: localDay(day1), percent: 2 }, { day: localDay(day2), percent: 5 }];
    const daily = quotaHeatmapCells(days, day2, "daily").filter(c => c && c.percent > 0).map(c => c!.percent);
    expect(daily).toEqual([2, 5]);
    expect(quotaHeatmapCells(days, day2, "cumulative").filter(Boolean).at(-1)!.percent).toBe(7);
  });
  it("aligns quota cells with local token cells for tooltips", () => {
    const q = quotaHeatmapCells([{ day: localDay(day1), percent: 2 }], day2, "daily");
    const t = heatmapCells([{ day: day1, tokens: tokens({ input: 500 }), estimatedCostUSD: 0, sessionCount: 1 }], day2, "daily");
    expect(q.length).toBe(t.length);
    const i = q.findIndex(c => c?.day === localDay(day1));
    expect(t[i]?.tokens).toBe(500);
  });
});
