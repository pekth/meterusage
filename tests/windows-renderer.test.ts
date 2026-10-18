import { expect, it } from "vite-plus/test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ApiBillingConnections, Connections, Settings, UsagePanel } from "../src/renderer/app";
import { primary, value } from "../src/domain/models";
import type { ViewState } from "../src/shared/ipc";

const state = (): ViewState => ({
  platform: "win32", systemDark: false, settings: { values: { refreshIntervalSeconds: 60, panelSize: "medium" }, accounts: [] },
  notch: { expanded: false, cardOnRight: false, selected: "codex", dragging: false },
  connections: ["codex", "claude", "antigravity", "grok"].map(provider => ({ provider: provider as "codex" | "claude" | "antigravity" | "grok", source: "cli", localAvailable: true, status: provider === "codex" ? "disconnected" : "unsupported" })),
  snapshot: {
    demo: false, refreshing: false, clock: 1791763200000, slots: [], traySlots: [], notchSlots: [], quotas: {}, archived: {}, activities: {}, usages: {}, plans: {}, statuses: {}, archiveWriteFailed: false, clearingCache: false,
    appearance: { theme: "system", accent: "blue", heatmap: true, claudeHeatmap: true, codexHeatmap: true, pacing: true, telemetry: true, chart: true, resetButton: true, compactTray: true, notch: false, pinned: false, onboarding: true },
  },
});
const action = async () => {};

it("offers Windows CLI collection while disabling unavailable desktop account choices", () => {
  const markup = renderToStaticMarkup(createElement(Connections, { state: state(), action }));
  expect(markup).toContain("Desktop account access is available on macOS. Choose CLI for local data on this PC.");
  for (const name of ["Claude Desktop", "Antigravity Desktop", "Grok Bot Desktop (Beta)"]) {
    expect(markup).toContain(`<option value="account" disabled="">${name}</option>`);
  }
  expect(markup).toContain('<option value="cli" selected="">Claude Code CLI</option>');
  expect(markup).toContain("Use CLI");
  expect(markup).not.toContain("Connect Claude Desktop");
});

it("hides macOS saved-key and updater controls while keeping one-time billing and local usage", () => {
  const view = state();
  const billing = renderToStaticMarkup(createElement(ApiBillingConnections, { state: view, action }));
  expect(billing).toContain("OpenAI API Admin key");
  expect(billing).toContain("Anthropic API Admin key");
  expect(billing).not.toContain("Use saved key");
  expect(billing).not.toContain("Use a saved key");
  expect(billing).not.toContain("Keychain");
  const settings = renderToStaticMarkup(createElement(Settings, { state: view, action, saveOrder: async () => true }));
  expect(settings).not.toContain("Check for updates");
  expect(settings).not.toContain("Compact menu bar");
  view.snapshot.slots = [primary("codex")];
  view.snapshot.usages.codex = value({ provider: "codex", sessionCount: 1, messageCount: 1, todaySessionCount: 1, todayMessageCount: 1, capturedAt: view.snapshot.clock });
  expect(renderToStaticMarkup(createElement(UsagePanel, { state: view, action }))).toContain("Activity on this PC");
});
