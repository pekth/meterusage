import { it, expect, vi } from "vite-plus/test";
import { createElement, useEffect, useRef, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { App, Connections, Meter, ProviderCard } from "../src/renderer/app";
import { tokens, providers, primary, quota, value, window, localDay, shiftDay } from "../src/domain/models";
import type { ViewState } from "../src/shared/ipc";
import { openRouterUsage } from "../src/main/providers/usage";
import { telemetry } from "../src/domain/telemetry";
import { trayTooltip } from "../src/domain/overview";
import { readFileSync } from "node:fs";

vi.mock("react", async importOriginal => {
  const actual = await importOriginal<typeof import("react")>();
  return { ...actual, useState: vi.fn(actual.useState), useEffect: vi.fn(actual.useEffect), useRef: vi.fn(actual.useRef) };
});
function renderApp(view: ViewState, surface = "flyout", error = "") {
  vi.stubGlobal("location", { search: `?surface=${surface}` });
  vi.mocked(useState).mockReturnValueOnce([view, () => {}]).mockReturnValueOnce([error, () => {}]);
  try { return renderToStaticMarkup(createElement(App, { bridge: { request: async () => ({ ok: true as const }), subscribe: () => () => {} } })); }
  finally { vi.unstubAllGlobals(); }
}

const now = Date.parse("2026-10-06T12:00:00Z");
it("passes the saved size to notch details without scaling the strip or share surface", () => {
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
    expect(renderApp(view, "notch")).toContain(`surface-notch size-${size}`);
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
  view.connections = [{ provider: "codex", source: "account", localAvailable: true, status: "disconnected" }, { provider: "claude", source: "account", localAvailable: true, status: "connected" }, { provider: "grok", source: "cli", localAvailable: true, status: "unsupported" }];
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toContain('aria-label="Disconnect Claude"');
  expect(markup).toContain("Sign in to Codex"); expect(markup).toContain("Disconnect"); expect(markup).toContain("Account allowance");
  expect(markup).toContain("Grok website and mobile usage are not supported"); expect(markup).not.toMatch(/directory|terminal|API key/);
  view.connections[0].status = "failed";
  const failed = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(failed).toContain("Connection failed. Check the message above and try again."); expect(failed).toContain("Sign in to Codex");
  view.connections[0].status = "connecting";
  expect(renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }))).toContain("Cancel");
  view.snapshot.demo = true; view.connections[0].status = "disconnected";
  expect(renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }))).toContain("disabled");
});
it("keeps onboarding in Settings and removes it from usage after completion", () => {
  const view = state(); view.snapshot.demo = false;
  view.connections = [{ provider: "codex", source: "account", localAvailable: true, status: "disconnected" }, { provider: "claude", source: "account", localAvailable: true, status: "disconnected" }, { provider: "grok", source: "cli", localAvailable: true, status: "unsupported" }];
  view.snapshot.appearance.onboarding = false;
  const setup = renderApp(view, "settings");
  expect(setup).toContain("Your usage, at a glance"); expect(setup).toContain("Choose a method for each provider");
  expect(setup).toContain("Choose how to connect"); expect(setup).toContain(">Done</button>");
  expect(setup).toContain("Sign in to Codex"); expect(setup).toContain("Connect Claude Desktop");
  for (const surface of ["flyout", "notch", "tray", "share"]) {
    expect(renderApp(view, surface)).not.toContain("Your usage, at a glance");
    expect(renderApp(view, surface)).not.toContain("Choose how to connect");
  }
  view.snapshot.appearance.onboarding = true;
  const completed = renderApp(view, "settings");
  expect(completed).not.toContain("Your usage, at a glance"); expect(completed).not.toContain(">Done</button>");
});
it("offers only supported methods and puts Done after the source choices", () => {
  const view = state(); view.snapshot.demo = false; view.snapshot.appearance.onboarding = false;
  const markup = renderApp(view, "settings");
  expect(markup).toContain('aria-label="Codex connection method"');
  expect(markup).toContain('aria-label="Claude connection method"');
  expect(markup).toContain('aria-label="Grok connection method"');
  expect(markup).toContain('>Browser sign-in</option>');
  expect(markup).toContain('>Claude Desktop</option>');
  expect(markup).toContain('>Claude Code CLI</option>');
  const grok = markup.slice(markup.indexOf('aria-label="Grok connection method"')).split('</select>')[0];
  expect(grok).toContain('>Grok CLI</option>'); expect(grok).not.toContain('value="account"');
  expect(markup.indexOf('>Done</button>')).toBeGreaterThan(markup.indexOf('aria-label="Grok connection method"'));
});
it("keeps a selected CLI switch explicit while showing the still-connected account", () => {
  const view = state(); view.snapshot.demo = false;
  view.connections = [{ provider: "codex", source: "account", localAvailable: true, status: "connected" }];
  vi.mocked(useState).mockReturnValueOnce(["cli", () => {}]);
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toContain('value="cli" selected=""');
  expect(markup).toContain('>Use CLI</button>');
  expect(markup).toContain('Connected · Account allowance');
  expect(markup).toContain('Use CLI disconnects this MeterUsage account connection.');
  expect(markup).not.toContain('>Disconnect</button>');
});
it("restores the saved CLI source without claiming account sign-in", () => {
  const view = state(); view.snapshot.demo = false;
  view.settings.values.showProviderClaude = true;
  view.connections = [{ provider: "claude", source: "cli", localAvailable: true, status: "disconnected" }];
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toContain('value="cli" selected=""');
  expect(markup).toContain('CLI selected. Data appears when available.');
  expect(markup).toContain('Allowance needs a companion usage file.');
  expect(markup).not.toContain('>Connect Claude Desktop</button>');
  expect(markup).not.toContain('Connected · Account allowance');
});
it("blocks CLI in isolated profiles and disables the selector while connecting", () => {
  const view = state(); view.snapshot.demo = false;
  view.connections = [{ provider: "claude", source: "account", localAvailable: false, status: "connecting" }];
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toContain('aria-label="Claude connection method" disabled=""');
  expect(markup).toContain('value="cli" disabled=""');
  expect(markup).toContain('aria-label="Cancel Claude connection"');
  expect(markup).not.toContain('>Use CLI</button>');
});
it("starts an isolated profile on its available account method", () => {
  const view = state(); view.snapshot.demo = false;
  view.connections = [{ provider: "claude", source: "cli", localAvailable: false, status: "disconnected" }];
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toContain('value="account" selected=""');
  expect(markup).toContain('>Connect Claude Desktop</button>');
  expect(markup).toContain('value="cli" disabled=""');
});
it("disables disconnect for saved account state in demo", () => {
  const view = state();
  view.connections = [{ provider: "codex", source: "account", localAvailable: false, status: "connected" }];
  const markup = renderToStaticMarkup(createElement(Connections, { state: view, action: async () => {} }));
  expect(markup).toMatch(/aria-label="Disconnect Codex"[^>]*disabled=""/);
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

it("limits the reset visibility setting to live notch details, keeping flyout redemption", () => {
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
      expect(markup.includes("Use reset")).toBe(capability === true && surface !== "share");
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

it("shows idle and failed public status sources without inventing unsupported providers", () => {
  const view = state(); view.snapshot.slots = []; view.snapshot.quotas = {}; view.snapshot.activities = {};
  view.snapshot.statuses.codex = { status: "missing", code: "offline", reason: "Status unavailable" };
  const markup = renderApp(view), section = markup.slice(markup.indexOf('aria-label="Service status"'), markup.indexOf("</section>", markup.indexOf('aria-label="Service status"')));
  expect(section).toContain("Status unavailable"); expect(section).toContain("Codex"); expect(section).not.toContain("Claude");
  view.snapshot.refreshing = true;
  expect(renderApp(view)).toContain("Checking…");
  view.snapshot.refreshing = false; view.snapshot.statuses.codex = { status: "idle" };
  expect(renderApp(view)).toContain("Not checked yet");
});

it("shows the age of the last successful public status check", () => {
  const view = state(); view.snapshot.statuses.codex = value({ provider: "codex", severity: "operational", description: "All systems operational", checkedAt: now - 60000, stale: true, refreshError: "Offline" });
  const markup = renderApp(view), section = markup.slice(markup.indexOf('aria-label="Service status"'), markup.indexOf("</section>", markup.indexOf('aria-label="Service status"')));
  expect(section).toContain("Last known 1m ago"); expect(section).toContain("Offline");
});

it("marks retained service status as last known in notch cards and tray tooltips", () => {
  const view = state(); view.snapshot.statuses.codex = value({ provider: "codex", severity: "operational", description: "All systems operational", checkedAt: now - 60000, stale: true, refreshError: "Service status unavailable" });
  const card = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: view, action: async () => {}, detail: true }));
  expect(card).toContain("Last known Operational · 1m ago · Service status unavailable");
  view.snapshot.traySlots = [primary("codex")];
  expect(trayTooltip(view.snapshot)).toContain("Codex: 80% used · resets in 4h · Last known Operational · checked 1m ago · Service status unavailable");
  view.snapshot.statuses.codex = value({ provider: "codex", severity: "majorOutage", description: "Major outage", checkedAt: now });
  expect(trayTooltip(view.snapshot)).toContain("Major outage");
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

it("keeps eligible menu resets accessible at Small, Medium and Large and hides archived actions", () => {
  const view = state(), q = quota("codex", [w], now); q.canConsumeReset = true; q.resetCreditCount = 3;
  q.resetCredits = ["one", "two", "three"].map(id => ({ id, title: "Full reset", status: "available", expiresAt: now + 3600000 }));
  view.snapshot.quotas.codex = value(q);
  for (const [size, scale] of [["small", "0.8"], ["medium", "1"], ["large", "1.15"]]) {
    view.settings.values.panelSize = size;
    const markup = renderApp(view);
    expect(markup).toContain(`zoom:${scale}`);
    expect(markup.match(/<button aria-label="Use reset: Full reset for Codex">Use reset<\/button>/g)).toHaveLength(3);
  }
  view.snapshot.archived.codex = q; view.snapshot.quotas.codex = { status: "missing", code: "offline", reason: "Offline" };
  expect(renderApp(view)).not.toContain("Use reset");
});

it("sizes reset controls with the compact detail footer while retaining the account label", () => {
  const view = state(), q = quota("codex", [w], now);
  q.canConsumeReset = true; q.resetCreditCount = 1;
  q.resetCredits = [{ id: "fixture", title: "Full reset", status: "available" }];
  view.snapshot.quotas.codex = value(q); view.snapshot.appearance.resetButton = true;
  const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: view, action: async () => {}, detail: true }));
  expect(markup).toContain('aria-label="Use reset: Full reset for Codex"');
  const css = readFileSync("src/renderer/style.css", "utf8");
  expect(css).toMatch(/\.detail-card footer button, \.reset-credit button \{ font-size: 11px; \}/);
});

it.each(["daily", "weekly", "cumulative"])("exposes exact heatmap values on hover and focus with %s scope", mode => {
  const view = state(), day = localDay(now);
  const daily = [{ day, tokens: tokens({ output: 1234567 }), sessionCount: 2, estimatedCostUSD: 0 }];
  view.snapshot.activities.codex = value({ provider: "codex", scannedAt: now, sessions: [], daily, telemetry: telemetry([], daily, now) });
  view.snapshot.appearance.heatmap = true; view.snapshot.appearance.codexHeatmap = true;
  vi.mocked(useState).mockReturnValueOnce([mode, () => {}]);
  const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: view, action: async () => {}, detail: true }));
  const date = (at: number) => new Date(at).toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
  const scope = mode === "weekly" ? `Week of ${date(shiftDay(day, -new Date(day).getDay()))}` : mode === "cumulative" ? `Through ${date(day)}` : date(day);
  expect(markup).toContain(`tabindex="0" role="img" aria-label="${scope}: ${new Intl.NumberFormat().format(1234567)} tokens, 2 sessions"`);
  expect(markup).toContain(`title="${scope}: ${new Intl.NumberFormat().format(1234567)} tokens, 2 sessions"`);
  expect(markup).toContain(`data-readout="${scope} · 1.2M tokens · 2 sessions"`);
  for (const name of ["daily", "weekly", "cumulative"]) expect(markup).toMatch(new RegExp(`<option value="${name}"[^>]*>${name[0].toUpperCase() + name.slice(1)}</option>`));
  const css = readFileSync("src/renderer/style.css", "utf8");
  expect(css).toContain('content: attr(data-readout)');
  expect(css).toContain('.heatmap-cell:hover::after'); expect(css).toContain('.heatmap-cell:focus::after');
  expect(css).toContain('padding-bottom: 4.5em');
});

it("labels count-only heatmap days without inventing measured zero tokens", () => {
  const view = state(), day = localDay(now), daily = [{ day, tokens: tokens(), sessionCount: 2, estimatedCostUSD: 0 }];
  view.snapshot.slots = [primary("grok")]; view.snapshot.activities = {};
  view.snapshot.usages.grok = value({ provider: "grok", capturedAt: now, sessionCount: 2, messageCount: 0, todaySessionCount: 2, todayMessageCount: 0, telemetry: telemetry([], daily, now) });
  view.snapshot.appearance.heatmap = true;
  const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("grok"), state: view, action: async () => {} }));
  expect(markup).toContain('2 sessions, token totals unavailable'); expect(markup).not.toContain('0 tokens');
  expect(markup).toContain('2 sessions · token totals unavailable');
});

it("keeps OpenRouter ledger dates in UTC when the local date is a day earlier", () => {
  vi.stubEnv("TZ", "America/Los_Angeles");
  try {
    const view = state(); view.snapshot.slots = [primary("openRouter")]; view.snapshot.activities = {};
    view.snapshot.usages.openRouter = value(openRouterUsage(JSON.stringify({ data: [{ date: "2026-10-06", prompt_tokens: 1234567, requests: 2 }] }), now));
    view.snapshot.appearance.heatmap = true;
    const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("openRouter"), state: view, action: async () => {} }));
    const date = new Date(Date.UTC(2026, 9, 6)).toLocaleDateString([], { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
    expect(markup).toContain(`aria-label="${date}: ${new Intl.NumberFormat().format(1234567)} tokens, 2 sessions"`);
    expect(markup).toContain(`data-readout="${date} · 1.2M tokens · 2 sessions"`);
  } finally { vi.unstubAllEnvs(); }
});

it("always shows usage rings and percentages, with hover-only details and no design selector", () => {
  const view = state(); view.snapshot.notchSlots = [primary("codex"), primary("claude")];
  view.snapshot.quotas.claude = value(quota("claude", [window("7-day", 42)], now));
  view.snapshot.appearance.pinned = true;
  for (const expanded of [false, true]) {
    for (const key of ["codex", "claude"]) {
      view.notch.expanded = expanded; view.notch.selected = key;
      const markup = renderApp(view, "notch");
      expect(markup).toContain('class="ring"'); expect(markup).toContain('<span>42</span>');
      expect(markup.includes('class="provider-card detail-card"')).toBe(expanded);
      expect(markup).not.toContain("folded-pill"); expect(markup).not.toContain("folded-strip");
      expect(markup).toContain(key === "codex" ? "Codex" : "Claude");
    }
  }
  const settings = renderApp(view, "settings");
  expect(settings).not.toContain("Resting strip"); expect(settings).not.toContain("Compact dots");
  expect(settings).not.toContain("Pin detail card");
  const css = readFileSync("src/renderer/style.css", "utf8");
  expect(css).not.toContain("folded-pill"); expect(css).not.toContain("folded-strip");
  expect(css).not.toContain("zoom: var(--panel-scale)");
  expect(css).toContain("--notch-body: 11px; --notch-secondary: 10px;");
});

it("demonstrates the same hover delay across providers in the synthetic preview", async () => {
  vi.useFakeTimers();
  try {
    const { previewBridge } = await import("../src/renderer/preview");
    const bridge = await previewBridge();
    const read = async () => { const reply = await bridge.request({ action: "state" }); if (!reply.ok || !reply.state) throw new Error("Missing preview state"); return reply.state; };
    expect((await read()).notch.expanded).toBe(false);
    for (const key of ["codex", "claude"]) {
      await bridge.request({ action: "notchHover", hovering: true });
      await bridge.request({ action: "notchSelect", key });
      expect((await read()).notch).toMatchObject({ expanded: true, selected: key });
      await bridge.request({ action: "notchHover", hovering: false });
      vi.advanceTimersByTime(449); expect((await read()).notch.expanded).toBe(true);
      vi.advanceTimersByTime(1); expect((await read()).notch.expanded).toBe(false);
    }
  } finally { vi.useRealTimers(); }
});

it("explains disabled demo connections before their actions and preserves labelled provider hit areas", () => {
  const view = state(), markup = renderApp(view, "settings");
  const explanation = markup.indexOf("Demo uses sample data. Account access is disabled.");
  expect(explanation).toBeGreaterThan(-1);
  expect(explanation).toBeLessThan(markup.indexOf("Sign in to Codex"));
  expect(explanation).toBeLessThan(markup.indexOf("Connect Claude Desktop"));
  expect(markup).toContain('<section class="providers">');
  expect(markup).toMatch(/<label class="setting"><span>Collect<\/span><input type="checkbox" aria-label="Collect Codex usage"[^>]*\/><\/label>/);
  expect(markup).toMatch(/<label class="setting"><span>Show<\/span><input type="checkbox" aria-label="Show Codex in menu bar and side notch"[^>]*\/><\/label>/);
  view.snapshot.demo = false;
  expect(renderApp(view, "settings")).not.toContain("Demo uses sample data. Account access is disabled.");
});

it("keeps static exports free of actions and selectors while retaining credit and heatmap data", () => {
  const view = state(), q = quota("codex", [w], now), day = localDay(now);
  q.canConsumeReset = true; q.resetCreditCount = 1;
  q.resetCredits = [{ id: "fixture", title: "Full reset", status: "available", expiresAt: now + 1000 }];
  view.snapshot.quotas.codex = value(q); view.snapshot.notchSlots = [primary("codex")];
  view.snapshot.appearance.resetButton = view.snapshot.appearance.heatmap = view.snapshot.appearance.codexHeatmap = true;
  const daily = [{ day, tokens: tokens({ output: 1234567 }), sessionCount: 2, estimatedCostUSD: 0 }];
  view.snapshot.activities.codex = value({ provider: "codex", scannedAt: now, sessions: [], daily, telemetry: telemetry([], daily, now) });
  const live = renderApp(view, "notch"), exported = renderApp(view, "share");
  for (const action of ["Use reset", "Share card", "Heatmap view"]) {
    expect(live).toContain(action); expect(exported).not.toContain(action);
  }
  expect(exported).not.toMatch(/<(button|select)\b/);
  for (const data of ["1 earned reset credits", "Full reset", "available", "Expires", "26 weeks", "1,234,567 tokens, 2 sessions", "80% used"]) {
    expect(live).toContain(data); expect(exported).toContain(data);
  }
});

it("distinguishes recorded history from local activity without changing their values or inventing scope", () => {
  const view = state(), daily = [{ day: localDay(now), tokens: tokens({ output: 100 }), sessionCount: 2, estimatedCostUSD: 0 }];
  view.snapshot.appearance.telemetry = true;
  view.snapshot.activities.codex = value({ provider: "codex", scannedAt: now, sessions: [], daily, telemetry: telemetry([{ startedAt: now, tokens: 50, messageCount: 3 }, { startedAt: now, tokens: 50, messageCount: 1 }], daily, now) });
  view.snapshot.usages.codex = value({ provider: "codex", capturedAt: now, sessionCount: 9, messageCount: 7, todaySessionCount: 1, todayMessageCount: 1 });
  view.snapshot.notchSlots = [primary("codex")];
  for (const surface of ["flyout", "notch", "share"]) {
    const markup = renderApp(view, surface);
    expect(markup).toContain('<h3>Activity on this Mac</h3>');
    expect(markup).toContain('<dt>Sessions</dt><dd>9</dd>');
    expect(markup).toContain('<dt>Messages</dt><dd>7</dd>');
    expect(markup).toContain('<h3>Recorded activity</h3>');
    expect(markup).toContain('<dt>Recorded sessions</dt><dd>2</dd>');
    expect(markup).toContain('<dt>Recorded messages</dt><dd>4</dd>');
  }
  view.snapshot.activities.codex = value({ provider: "codex", scannedAt: now, sessions: [], daily, telemetry: telemetry([], daily, now) });
  expect(renderApp(view)).not.toContain("Recorded sessions"); expect(renderApp(view)).not.toContain("Recorded messages");
  view.snapshot.appearance.telemetry = false; view.snapshot.appearance.chart = true;
  expect(renderApp(view)).not.toContain("Recorded activity");
  expect(renderApp(view)).toContain('aria-label="Token usage in the last 30 days"');
});

it("preserves action alerts and dated archive reasons across the shared cards", () => {
  const view = state(), message = "Synthetic save failed: choice retained";
  const markup = renderApp(view, "settings", message);
  expect(markup).toContain(`<div class="action-error" role="alert"><span>${message}</span><button aria-label="Dismiss error">×</button></div>`);
  expect(markup).toContain("Copy diagnostics"); expect(markup).toContain("Clear local scan cache");
  view.snapshot.archived.codex = quota("codex", [w], now - 60000);
  view.snapshot.quotas.codex = { status: "missing", code: "offline", reason: "Synthetic offline reason" };
  view.snapshot.notchSlots = [primary("codex")];
  for (const surface of ["flyout", "notch", "share"]) {
    const card = renderApp(view, surface);
    expect(card).toContain(`<p class="stale quota-stale">Last known · ${new Date(now - 60000).toLocaleString()}<br/>Synthetic offline reason</p>`);
    expect(card).toContain("80% used"); expect(card).not.toContain("Use reset");
  }
});

it("renders the preferred provider groups in Settings, usage, tray and notch", () => {
  const view = state(), s = view.snapshot;
  view.settings.providerOrder = ["claude", ...providers.filter(p => p !== "claude")];
  s.slots = s.traySlots = s.notchSlots = [primary("claude"), { ...primary("claude"), slotID: "work", label: "Work" }, primary("codex")];
  s.appearance.compactTray = false;
  for (const slot of s.slots) s.quotas[slot.slotID ? `${slot.provider}#${slot.slotID}` : slot.provider] = value(quota(slot.provider, [window("5-hour", slot.provider === "claude" ? 11 : 22)], now));
  for (const surface of ["settings", "flyout", "tray", "notch"]) {
    const markup = renderApp(view, surface);
    const first = surface === "settings" ? 'aria-label="Reorder Claude"' : surface === "notch" ? 'aria-label="Show Claude details' : surface === "tray" ? "11%" : '<h2>Claude</h2>';
    const second = surface === "settings" ? 'aria-label="Reorder Codex"' : surface === "notch" ? 'aria-label="Show Codex details' : surface === "tray" ? "22%" : '<h2>Codex</h2>';
    expect(markup.indexOf(first), surface).toBeGreaterThanOrEqual(0); expect(markup.indexOf(first)).toBeLessThan(markup.indexOf(second));
  }
  s.statuses = { codex: { status: "idle" }, claude: { status: "idle" } };
  const markup = renderApp(view);
  expect(markup.indexOf("<strong>Claude</strong>")).toBeLessThan(markup.indexOf("<strong>Codex</strong>"));
});


it("renders provider account buckets beside quota without local activity", () => {
  const view = state();
  view.snapshot.activities = {};
  view.snapshot.appearance.heatmap = view.snapshot.appearance.codexHeatmap = true;
  Object.assign(view.snapshot, { accountActivities: { codex: value({ capturedAt: now, dailyUsageBuckets: [
    { startDate: "2026-10-04", tokens: 1234567 }, { startDate: "2026-10-06", tokens: 0 },
  ] }) } });
  for (const props of [{}, { detail: true }, { detail: true, staticExport: true }]) {
    const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: view, action: async () => {}, ...props }));
    expect(markup).toContain("Account token activity");
    expect(markup).toContain("Provider account");
    expect(markup).toContain('tabindex="0" role="img" aria-label="2026-10-04: 1,234,567 tokens"');
    expect(markup).toContain('aria-label="2026-10-05: Unavailable"');
    expect(markup).toContain('aria-label="2026-10-06: 0 tokens"');
    expect(markup).not.toContain("Recorded activity");
    expect(markup).not.toContain("sessions");
    expect(markup).not.toContain("Heatmap view");
  }
});


it("keeps unavailable account history explicit and respects global and Codex heatmap preferences", () => {
  const view = state(); view.snapshot.activities = {};
  view.snapshot.appearance.heatmap = view.snapshot.appearance.codexHeatmap = true;
  for (const reading of [{ status: "idle" as const }, { status: "missing" as const, code: "failed" as const, reason: "Unavailable" }, value({ capturedAt: now, dailyUsageBuckets: null }), value({ capturedAt: now, dailyUsageBuckets: [] })]) {
    view.snapshot.accountActivities = { codex: reading };
    const markup = renderApp(view);
    expect(markup).toContain("Account history unavailable"); expect(markup).not.toContain("0 tokens");
  }
  for (const [global, codex] of [[false, true], [true, false]]) {
    view.snapshot.appearance.heatmap = global; view.snapshot.appearance.codexHeatmap = codex;
    expect(renderApp(view)).not.toContain("Account token activity");
  }
  view.snapshot.appearance.heatmap = view.snapshot.appearance.codexHeatmap = true;
  const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: { provider: "codex", slotID: "local", label: "Local" }, state: view, action: async () => {} }));
  expect(markup).not.toContain("Account token activity");
  const css = readFileSync("src/renderer/style.css", "utf8");
  expect(css).toContain(".heatmap-cell:hover::after"); expect(css).toContain(".heatmap-cell:focus::after");
  expect(css).toContain(".heatmap .unavailable-day > span");
});

it.each([[0, "0"], [42, "42"], [12500, "12.5K"], [1234567, "1.2M"], [499543210, "499.5M"], [2400000000, "2.4B"]])("makes %s account tokens readable without losing the exact count", (count, compact) => {
  vi.stubEnv("TZ", "America/Los_Angeles");
  try {
    const view = state(); view.snapshot.activities = {};
    view.snapshot.appearance.heatmap = view.snapshot.appearance.codexHeatmap = true;
    view.snapshot.accountActivities = { codex: value({ capturedAt: now, dailyUsageBuckets: [{ startDate: "2026-10-11", tokens: count as number }] }) };
    const date = new Date("2026-10-11").toLocaleDateString([], { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" });
    for (const props of [{}, { detail: true }, { detail: true, staticExport: true }]) {
      const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("codex"), state: view, action: async () => {}, ...props }));
      const exact = `2026-10-11: ${new Intl.NumberFormat("en").format(count as number)} tokens`;
      expect(markup).toContain(`aria-label="${exact}" title="${exact}" data-readout="${date} · ${compact} tokens"`);
      expect(markup).toContain('aria-label="2026-10-10: Unavailable"');
    }
  } finally { vi.unstubAllEnvs(); }
});

it.each(providers)("uses the shared heatmap design for %s activity", provider => {
  const view = state(), day = localDay(now), daily = [{ day, tokens: tokens({ output: 1234567 }), sessionCount: 2, estimatedCostUSD: 0 }];
  view.snapshot.activities = { [provider]: value({ provider, scannedAt: now, sessions: [], daily, telemetry: telemetry([], daily, now) }) };
  view.snapshot.appearance.heatmap = view.snapshot.appearance.codexHeatmap = view.snapshot.appearance.claudeHeatmap = true;
  const markup = renderToStaticMarkup(createElement(ProviderCard, { slot: primary(provider), state: view, action: async () => {} }));
  expect(markup).toContain('class="activity-heatmap"');
  expect(markup).toContain('class="heatmap-heading"');
  expect(markup).toContain('class="heatmap-legend secondary"');
  expect(markup).toContain('aria-label="Usage intensity from less to more"');
  expect(markup).toContain(`${new Intl.NumberFormat().format(1234567)} tokens, 2 sessions`);
  expect(markup).toContain('1.2M tokens · 2 sessions');
});
