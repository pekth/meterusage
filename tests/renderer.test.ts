import { it, expect, vi } from "vite-plus/test";
import { createElement, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { App, Meter, ProviderCard } from "../src/renderer/app";
import { tokens, primary, quota, value, window } from "../src/domain/models";
import type { ViewState } from "../src/shared/ipc";

vi.mock("react", async importOriginal => {
  const actual = await importOriginal<typeof import("react")>();
  return { ...actual, useState: vi.fn(actual.useState) };
});
function renderApp(view: ViewState, surface = "flyout") {
  vi.stubGlobal("location", { search: `?surface=${surface}` });
  vi.mocked(useState).mockReturnValueOnce([view, () => {}]);
  try { return renderToStaticMarkup(createElement(App, { bridge: { request: async () => ({ ok: true as const }), subscribe: () => () => {} } })); }
  finally { vi.unstubAllGlobals(); }
}

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

it("keeps reported service health visible when all usage providers are hidden", () => {
  const view = state(); view.snapshot.slots = []; view.snapshot.quotas = {}; view.snapshot.activities = {};
  view.snapshot.statuses.codex = value({ provider: "codex", severity: "majorOutage", description: "Synthetic service outage", checkedAt: now });
  view.snapshot.statuses.claude = value({ provider: "claude", severity: "operational", description: "All systems operational", checkedAt: now });
  const markup = renderApp(view);
  expect(markup).toContain('aria-label="Service status"'); expect(markup).toContain("Synthetic service outage"); expect(markup).toContain("All systems operational");
  expect(markup).toContain("var(--alert)"); expect(markup).toContain("Enable a provider in Settings");
  expect(markup.indexOf("Service status")).toBeLessThan(markup.indexOf("Enable a provider"));
});

it("does not fabricate service rows for absent or failed status sources", () => {
  const view = state(); view.snapshot.slots = []; view.snapshot.quotas = {}; view.snapshot.activities = {};
  view.snapshot.statuses.codex = { status: "missing", code: "offline", reason: "Status unavailable" };
  const markup = renderApp(view), section = markup.slice(markup.indexOf('aria-label="Service status"'), markup.indexOf("</section>", markup.indexOf('aria-label="Service status"')));
  expect(section).toContain("Not checked yet"); expect(section).not.toContain("Codex"); expect(section).not.toContain("Claude");
});

it("shows raw-window ambient notch ETA without recent burn and hides it when pacing is off", () => {
  const view = state(); view.snapshot.notchSlots = [primary("codex")]; view.snapshot.activities = {};
  const row = () => { const markup = renderApp(view, "notch"), start = markup.indexOf('class="strip-provider"'); return markup.slice(start, markup.indexOf("</button>", start)); };
  expect(row()).toContain("15m"); expect(row()).toContain('class="notch-eta"');
  view.snapshot.appearance.pacing = false; expect(row()).not.toContain('class="notch-eta"');
  view.snapshot.appearance.pacing = true; view.snapshot.quotas.codex = value(quota("codex", [window("5-hour", 1, now + 3600000, 300)], now));
  expect(row()).toContain("1h");
  view.snapshot.quotas.codex = value(quota("codex", [window("5-hour", 1, now + 4 * 3600000, 300)], now)); expect(row()).not.toContain('class="notch-eta"');
  view.snapshot.quotas.codex = { status: "missing", code: "offline", reason: "Offline" }; view.snapshot.archived.codex = quota("codex", [w], now - 60000);
  expect(row()).toContain("15m"); expect(row()).toContain("last known reading");
});
