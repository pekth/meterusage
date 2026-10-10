import { it, expect, vi } from "vite-plus/test";
import { createElement, useEffect, useRef, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { App, Connections, Meter, ProviderCard } from "../src/renderer/app";
import { tokens, primary, quota, value, window } from "../src/domain/models";
import type { ViewState } from "../src/shared/ipc";
import { trayTooltip } from "../src/domain/overview";
import { readFileSync } from "node:fs";

vi.mock("react", async importOriginal => {
  const actual = await importOriginal<typeof import("react")>();
  return { ...actual, useState: vi.fn(actual.useState), useEffect: vi.fn(actual.useEffect), useRef: vi.fn(actual.useRef) };
});
function renderApp(view: ViewState, surface = "flyout") {
  vi.stubGlobal("location", { search: `?surface=${surface}` });
  vi.mocked(useState).mockReturnValueOnce([view, () => {}]);
  try { return renderToStaticMarkup(createElement(App, { bridge: { request: async () => ({ ok: true as const }), subscribe: () => () => {} } })); }
  finally { vi.unstubAllGlobals(); }
}

const now = Date.parse("2026-10-06T12:00:00Z");
it("offers a labelled size selector and scopes scale and keyboard scrolling to main panel and Settings", () => {
  const view = state();
  for (const [size, scale] of [["small", "0.8"], ["medium", "1"], ["large", "1.15"]]) {
    view.settings.values.panelSize = size;
    for (const surface of ["flyout", "settings"]) {
      const markup = renderApp(view, surface);
      expect(markup).toContain(`zoom:${scale}`);
      expect(markup).toMatch(/class="panel-viewport"[^>]*tabindex="0"/);
      if (surface === "settings") {
        expect(markup).toContain("<legend>Usage-panel size</legend>");
        expect(markup).toContain("The Settings window stays the same size.");
        expect(markup).toMatch(new RegExp(`type="radio" name="panelSize"(?=[^>]*value="${size}")(?=[^>]*checked)`));
        for (const label of ["Small", "Medium", "Large"]) expect(markup).toContain(`>${label}</span>`);
      }
    }
    for (const surface of ["notch", "tray", "share"]) {
      expect(renderApp(view, surface)).not.toContain("zoom:");
      expect(renderApp(view, surface)).not.toContain("panel-viewport");
    }
  }
  delete view.settings.values.panelSize;
  expect(renderApp(view)).toContain("zoom:1");
  expect(renderApp(view, "settings")).toMatch(/type="radio" name="panelSize"(?=[^>]*value="medium")(?=[^>]*checked)/);
});

it("reports the scaled natural content box when scrollHeight retains the taller viewport", () => {
  const view = state(), request = vi.fn(async () => ({ ok: true as const }));
  let measure!: ResizeObserverCallback;
  const lifecycle: { cleanup?: void | (() => void) } = {};
  const node = { scrollHeight: 850, getBoundingClientRect: () => ({ height: 593 }) };
  vi.mocked(useRef).mockReturnValueOnce({ current: node });
  vi.mocked(useEffect).mockImplementationOnce(() => {}).mockImplementationOnce(effect => { lifecycle.cleanup = effect(); });
  const disconnect = vi.fn();
  vi.stubGlobal("ResizeObserver", class {
    constructor(callback: ResizeObserverCallback) { measure = callback; }
    observe = vi.fn(); disconnect = disconnect;
  });
  vi.stubGlobal("location", { search: "?surface=flyout" });
  vi.mocked(useState).mockReturnValueOnce([view, () => {}]);
  try {
    renderToStaticMarkup(createElement(App, { bridge: { request, subscribe: () => () => {} } }));
    measure([], {} as ResizeObserver);
    expect(request).toHaveBeenLastCalledWith({ action: "resize", height: 593 });
    node.getBoundingClientRect = () => ({ height: 351.2 });
    measure([], {} as ResizeObserver);
    expect(request).toHaveBeenLastCalledWith({ action: "resize", height: 352 });
    measure([], {} as ResizeObserver);
    expect(request).toHaveBeenCalledTimes(2);
    node.getBoundingClientRect = () => ({ height: 2500 });
    measure([], {} as ResizeObserver);
    expect(request).toHaveBeenLastCalledWith({ action: "resize", height: 2500 });
  } finally {
    lifecycle.cleanup?.();
    vi.unstubAllGlobals();
  }
  expect(disconnect).toHaveBeenCalledOnce();
});
it("bounds browser notch content to the viewport while retaining native work-area sizing", () => {
  const view = state(); view.snapshot.notchSlots = [primary("codex")];
  expect(renderApp(view, "notch")).toContain("--notch-max-height:100dvh");
  view.notch.maxHeight = 900;
  expect(renderApp(view, "notch")).toContain("--notch-max-height:900px");
});
it("groups settings and names provider controls while keeping accent choices selectable", () => {
  const view = state(); view.settings.values = { showProviderCodex: true, menuBarProviderCodex: true, accentTheme: "violet" };
  const markup = renderApp(view, "settings");
  expect(markup).toContain("Collect usage"); expect(markup).toContain("Show in menu bar and side notch");
  expect(markup).toContain('aria-label="Collect Codex usage"'); expect(markup).toContain('aria-label="Show Codex in menu bar and side notch"');
  expect(markup).not.toMatch(/aria-label="Show Codex in menu bar and side notch"[^>]*disabled/);
  expect(markup).toContain("Side notch"); expect(markup).toContain("Usage details"); expect(markup).toContain("Codex limit resets in the side notch");
  expect(markup).not.toContain('<span>Accent</span><select');
  expect((markup.match(/type="radio" name="accentTheme"/g) ?? []).length).toBe(6);
  expect(markup).toMatch(/type="radio" name="accentTheme"(?=[^>]*value="violet")(?=[^>]*checked)/);
  view.settings.values.showProviderCodex = false;
  const disabledMarkup = renderApp(view, "settings");
  expect(disabledMarkup).toMatch(/aria-label="Show Codex in menu bar and side notch"[^>]*disabled/);
  expect(disabledMarkup).not.toMatch(/aria-label="Collect Codex usage"[^>]*checked/);
  expect(disabledMarkup).toMatch(/aria-label="Show Codex in menu bar and side notch"[^>]*checked/);
});
it("offers simple account setup and truthful Grok availability without directories in the primary flow", () => {
  const view = state(); view.snapshot.demo = false;
  view.connections = [{ provider: "codex", status: "disconnected" }, { provider: "claude", status: "connected" }, { provider: "grok", status: "unsupported" }];
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toContain('aria-label="Disconnect Claude"');
  expect(markup).toContain("Sign in to Codex"); expect(markup).toContain("Disconnect"); expect(markup).toContain("Account allowance");
  expect(markup).toContain("Automatic connection is not available yet"); expect(markup).not.toMatch(/directory|terminal|API key/);
  view.connections[0].status = "failed";
  const failed = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(failed).toContain("Usage unavailable. Open the desktop app and try again."); expect(failed).toContain("Sign in to Codex");
  view.connections[0].status = "connecting";
  expect(renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }))).toContain("Cancel");
  view.snapshot.demo = true; view.connections[0].status = "disconnected";
  expect(renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }))).toContain("disabled");
});
it("keeps onboarding in Settings and removes it from usage after completion", () => {
  const view = state(); view.snapshot.demo = false;
  view.connections = [{ provider: "codex", status: "disconnected" }, { provider: "claude", status: "disconnected" }, { provider: "grok", status: "unsupported" }];
  view.snapshot.appearance.onboarding = false;
  const setup = renderApp(view, "settings");
  expect(setup).toContain("Your usage, at a glance"); expect(setup).toContain("Choose an account once");
  expect(setup).toContain("Connect your accounts"); expect(setup).toContain(">Done</button>");
  expect(setup).toContain("Sign in to Codex"); expect(setup).toContain("Connect Claude Desktop");
  for (const surface of ["flyout", "notch", "tray", "share"]) {
    expect(renderApp(view, surface)).not.toContain("Your usage, at a glance");
    expect(renderApp(view, surface)).not.toContain("Connect your accounts");
  }
  view.snapshot.appearance.onboarding = true;
  const completed = renderApp(view, "settings");
  expect(completed).not.toContain("Your usage, at a glance"); expect(completed).not.toContain(">Done</button>");
});
it.each(["codex", "claude"] as const)("keeps %s display control available for an active additional account", provider => {
  const view = state(), name = provider === "codex" ? "Codex" : "Claude";
  view.settings.values = { [`showProvider${name}`]: false, [`menuBarProvider${name}`]: true };
  view.snapshot.slots = [{ ...primary(provider), slotID: "additional-fixture", label: "Synthetic account" }];
  const control = new RegExp(`aria-label="Show ${name} in menu bar and side notch"[^>]*`);
  expect(renderApp(view, "settings").match(control)?.[0]).not.toContain("disabled");
  view.snapshot.slots = [];
  view.settings.accounts = [{ id: "absent-fixture", provider, label: "Absent account", pathLabel: "Synthetic absent directory", enabled: true }];
  const disabled = renderApp(view, "settings").match(control)?.[0];
  expect(disabled).toContain("disabled"); expect(disabled).toContain("checked");
});
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

it("shows unavailable reset status without a redemption action", () => {
  const view = state(), q = quota("codex", [], now); q.resetCreditCount = 1; view.snapshot.appearance.resetButton = true;
  view.snapshot.quotas.codex = value(q);
  for (const status of ["consumed", "revoked", undefined]) {
    q.resetCredits = [{ id: "c", title: "Reset", status }];
    const markup = renderApp(view); expect(markup).not.toContain("Use reset"); expect(markup).toContain(status ?? "Status not reported");
  }
  q.canConsumeReset = true;
  q.resetCredits = [{ id: "c", title: "Reset", status: "AVAILABLE", expiresAt: now + 1000 }]; expect(renderApp(view)).toContain("Use reset");
  q.resetCredits[0].expiresAt = now; expect(renderApp(view)).not.toContain("Use reset"); expect(renderApp(view)).toContain("expired");
});

it("limits the reset visibility setting to the notch and shared detail, keeping flyout redemption", () => {
  const view = state(), q = quota("codex", [w], now); q.resetCreditCount = 1; q.resetCredits = [{ id: "fixture-credit", title: "Reset", status: "available", expiresAt: now + 1000 }];
  view.snapshot.quotas.codex = value(q); view.snapshot.notchSlots = [primary("codex")];
  q.canConsumeReset = true;
  expect(renderApp(view)).toContain("Use reset"); expect(renderApp(view, "notch")).not.toContain("Use reset"); expect(renderApp(view, "share")).not.toContain("Use reset");
  expect(renderApp(view, "settings")).toContain("Codex limit resets in the side notch");
  view.snapshot.appearance.resetButton = true; expect(renderApp(view, "notch")).toContain("Use reset");
});

it("hides reset actions for allowance-only sources while retaining earned credit details", () => {
  const view = state(), q = quota("codex", [w], now); q.resetCreditCount = 1;
  q.resetCredits = [{ id: "fixture-credit", title: "Reset", status: "available" }];
  view.snapshot.quotas.codex = value(q); view.snapshot.notchSlots = [primary("codex")]; view.snapshot.appearance.resetButton = true;
  for (const capability of [undefined, false, true]) {
    q.canConsumeReset = capability;
    for (const surface of ["flyout", "notch", "share"]) {
      const markup = renderApp(view, surface); expect(markup).toContain("1 earned reset credits");
      expect(markup.includes("Use reset")).toBe(capability === true);
    }
  }
});

it("uses general weekly-only Claude allowance in tray, tooltip and notch without model-specific fallback", () => {
  const view = state(), s = view.snapshot, slot = primary("claude");
  s.slots = s.traySlots = s.notchSlots = [slot]; s.appearance.compactTray = false;
  s.quotas = { claude: value(quota("claude", [window("Weekly · Fable", 99), window("Weekly · All models", 42)], now)) }; s.activities = {};
  expect(trayTooltip(s)).toBe("Claude: 42% used");
  expect(renderApp(view, "tray")).toContain("42%"); expect(renderApp(view, "notch")).toContain('aria-label="Show Claude details, 42% used"');
  s.quotas.claude = value(quota("claude", [window("Weekly · Fable", 99)], now));
  expect(trayTooltip(s)).toBe("No usage data yet"); expect(renderApp(view, "notch")).not.toContain('class="strip-provider"');
  s.quotas.claude = value(quota("claude", [window("Weekly · All models", 42), window("Session", 7)], now));
  expect(trayTooltip(s)).toBe("Claude: 7% used");
});

it("keeps remote OpenRouter account usage out of explicitly local totals", () => {
  const view = state(), s = view.snapshot; s.slots = [primary("codex"), primary("openRouter")];
  s.quotas = {}; s.activities.codex = value({ provider: "codex", scannedAt: now, daily: [], sessions: [session("local", now - 60000, 20)] });
  s.usages.openRouter = value({ provider: "openRouter", sessionCount: 123, messageCount: 456, todaySessionCount: 12, todayMessageCount: 45, todayTokens: tokens({ input: 999999 }), weekTokens: tokens({ input: 999999 }), todayCostUSD: 999, capturedAt: now });
  const markup = renderApp(view), start = markup.indexOf("AI activity on this Mac"), local = markup.slice(start, markup.indexOf("</section>", start));
  expect(local).toContain("Tokens today</dt><dd>20</dd>"); expect(local).toContain("Last 7 days</dt><dd>20</dd>"); expect(local).toContain("$0.00");
  const card = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("openRouter"), state: view, action: async () => {} }));
  expect(card).toContain("Account activity"); expect(card).not.toContain("Activity on this Mac"); expect(card).toContain("123");
  s.slots = [primary("openRouter")]; s.activities = {};
  expect(renderApp(view)).not.toContain("AI activity on this Mac");
});

it("shows rolling cost shares before token shares and handles an empty 30-day reference", () => {
  const view = state(); view.snapshot.slots = [primary("openCodeGo")]; view.snapshot.activities = {}; view.snapshot.quotas = {};
  const usage = { provider: "openCodeGo" as const, sessionCount: 10, messageCount: 50, todaySessionCount: 1, todayMessageCount: 2, capturedAt: now,
    usageWindows: [{ label: "last 24h", sessionCount: 1, messageCount: 2, tokens: tokens({ input: 200 }), estimatedCostUSD: 8 }, { label: "last 30d", sessionCount: 10, messageCount: 50, tokens: tokens({ input: 1000 }), estimatedCostUSD: 10 }] };
  view.snapshot.usages.openCodeGo = value(usage);
  const cost = renderApp(view); expect(cost).toContain("80%"); expect(cost).toContain('aria-valuenow="80"'); expect(cost).toContain("Share of last 30d usage"); expect(cost).toContain("200 tokens · 2 messages");
  expect(cost).toContain("10 sessions · 50 messages · 1,000 tokens · ~$10.00");
  usage.usageWindows[0].estimatedCostUSD = 20; expect(renderApp(view)).toContain('aria-valuenow="100"');
  usage.usageWindows[1].estimatedCostUSD = 0;
  const token = renderApp(view); expect(token).toContain("20%"); expect(token).toContain('aria-valuenow="20"'); expect(token).toContain("Share of last 30d tokens");
  usage.usageWindows[1].tokens = tokens(); const zero = renderApp(view); expect(zero).toContain('aria-valuenow="0"'); expect(zero).not.toContain("NaN");
  usage.usageWindows.pop(); expect(renderApp(view)).toContain('aria-valuenow="0"');
});

it("keeps the four Swift adaptive provider identities and semantic status overrides", () => {
  const css = readFileSync("src/renderer/style.css", "utf8"), view = state(); view.snapshot.activities = {}; view.snapshot.quotas = {};
  for (const [provider, variable, light, dark] of [["claude", "claude", "#c25e00", "#d97706"], ["antigravity", "antigravity", "#2563eb", "#60a5fa"], ["openCodeGo", "opencode", "#0f766e", "#2dd4bf"], ["openRouter", "openrouter", "#6d28d9", "#a78bfa"]] as const) {
    view.snapshot.slots = [primary(provider)]; view.snapshot.statuses = {};
    for (const theme of ["light", "dark", "system"]) { view.snapshot.appearance.theme = theme; expect(renderApp(view)).toContain(`var(--${variable})`); }
    expect(css).toMatch(new RegExp(`\\.app \\{[^}]*--${variable}: ${light}`));
    for (const theme of ["dark", "system"]) expect(css).toMatch(new RegExp(`\\.theme-${theme} \\{[^}]*--${variable}: ${dark}`));
    view.snapshot.statuses[provider] = value({ provider, severity: "majorOutage", description: "Outage", checkedAt: now }); expect(renderApp(view)).toContain("var(--alert)"); expect(renderApp(view)).not.toContain(`var(--${variable})`);
  }
});

it("shows count-only current-day usage and capture age without invented token totals", () => {
  const view = state(); view.snapshot.slots = [primary("grok")]; view.snapshot.quotas = {}; view.snapshot.activities = {};
  const usage = { provider: "grok" as const, sessionCount: 10, messageCount: 50, todaySessionCount: 1, todayMessageCount: 2, capturedAt: now - 3600000 };
  view.snapshot.usages.grok = value(usage);
  const markup = renderApp(view); expect(markup).toContain("Today: 1 session · 2 messages · updated 1h ago"); expect(markup).not.toContain("Measured tokens");
  view.snapshot.usages.grok = value({ ...usage, todaySessionCount: 0, todayMessageCount: 0 }); expect(renderApp(view)).toContain("Updated 1h ago · token totals unavailable");
  view.snapshot.usages.grok = value({ ...usage, todaySessionCount: 0, todayMessageCount: 0, tokens: tokens() }); expect(renderApp(view)).toContain("measured token totals");
});

it("keeps textual tray outage, reset countdown, dated age and last refresh", () => {
  const s = state().snapshot, account = { ...primary("codex"), slotID: "work", label: "Work" };
  s.traySlots = [account, primary("grok")]; s.quotas = {}; s.archived = { "codex#work": quota("codex", [window("5-hour", 0, now + 3600000)], now - 7200000) };
  s.statuses.grok = value({ provider: "grok", severity: "majorOutage", description: "Fixture outage", checkedAt: now }); s.lastRefreshedAt = now - 60000;
  expect(trayTooltip(s)).toBe("Codex · Work: 0% used · resets in 1h · last reading 2h ago\nGrok: Major outage\nUpdated 1m ago");
  s.statuses.grok = value({ provider: "grok", severity: "unknown", description: "Unavailable", checkedAt: now }); expect(trayTooltip(s)).toContain("Grok: Unknown");
  s.traySlots = []; s.lastRefreshedAt = undefined; expect(trayTooltip(s)).toBe("No usage data yet");
});

it("uses adaptive Grok identity contrast while status overrides remain semantic", () => {
  const view = state(); view.snapshot.slots = [primary("grok")]; view.snapshot.quotas = {}; view.snapshot.activities = {};
  for (const theme of ["light", "dark", "system"]) { view.snapshot.appearance.theme = theme; expect(renderApp(view)).toContain("background:var(--grok)"); }
  const css = readFileSync("src/renderer/style.css", "utf8");
  expect(css).toMatch(/\.app \{[^}]*--grok: #1e1e22/); expect(css).toMatch(/\.theme-dark \{[^}]*--grok: #ebebf0/); expect(css).toMatch(/\.theme-system \{[^}]*--grok: #ebebf0/);
  view.snapshot.statuses.grok = value({ provider: "grok", severity: "majorOutage", description: "Outage", checkedAt: now }); expect(renderApp(view)).toContain("background:var(--alert)");
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
