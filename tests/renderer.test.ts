import { it, expect } from "vite-plus/test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Meter, ProviderCard } from "../src/renderer/app";
import { tokens, primary, quota, value, window } from "../src/domain/models";
import type { ViewState } from "../src/shared/ipc";

const now = Date.parse("2026-10-06T12:00:00Z");
const w = window("5-hour", 80, now + 4 * 3600000, 300);
const session = (id: string, at: number, output: number, cacheRead = 0) => ({ id, projectName: id, model: "fixture", tokens: tokens({ output, cacheRead }), estimatedCostUSD: 0, startedAt: at, messageCount: 10 });
const state = (): ViewState => ({ snapshot: {
  demo: true, refreshing: false, clock: now, slots: [primary("codex")], traySlots: [], notchSlots: [], quotas: { codex: value(quota("codex", [w], now)) }, archived: {},
  activities: { codex: value({ provider: "codex", scannedAt: now, daily: [], sessions: [session("old-project", now - 2 * 3600000, 100000), session("active-project", now - 60000, 100, 100)] }) },
  usages: {}, plans: {}, statuses: {}, appearance: { theme: "dark", accent: "blue", heatmap: false, claudeHeatmap: false, codexHeatmap: false, pacing: true, telemetry: false, chart: false, resetButton: false, compactTray: true, notch: true, pinned: false, onboarding: true }, archiveWriteFailed: false, clearingCache: false,
}, settings: { values: {}, accounts: [] }, systemDark: true, notch: { expanded: true, cardOnRight: false, selected: "codex", dragging: false } });

it("hides forecasts when pacing is disabled and retains the reported reset time", () => {
  const render = (pacing: boolean) => renderToStaticMarkup(createElement(Meter, { w, now, pacing }));
  expect(render(true)).toContain("left");
  expect(render(false)).not.toContain("left"); expect(render(false)).toContain("Resets ");
});

it("shows active-window burn metrics with window scope, distinct from recent sessions", () => {
  const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: state(), action: async () => {}, detail: true }));
  expect(markup).toContain("Active window burn");
  const section = markup.slice(markup.indexOf("Active window burn"), markup.indexOf("</section>", markup.indexOf("Active window burn")));
  expect(section).toContain("active-project"); expect(section).not.toContain("old-project");
  expect(section).toContain("200 tokens"); expect(section).toContain("100% cache hit"); expect(section).toContain("20 tokens/turn"); expect(section).toContain("1 long chat");
  const flyout = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: state(), action: async () => {} }));
  expect(flyout).not.toContain("Active window burn");
});
