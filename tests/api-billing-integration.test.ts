import { it, expect, afterEach, vi } from "vite-plus/test";
import { createElement, useState } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { Coordinator } from "../src/main/coordinator";
import { Preferences } from "../src/main/preferences";
import { launchConfiguration } from "../src/main/launch";
import { ApiBillingCards, ApiBillingConnections, Connections, App } from "../src/renderer/app";
import type { ViewState } from "../src/shared/ipc";
import type { ApiBillingProvider, ApiBillingSnapshot } from "../src/domain/api-billing";
import * as billing from "../src/main/providers/api-billing";

vi.mock("react", async original => {
  const actual = await original<typeof import("react")>();
  return { ...actual, useState: vi.fn(actual.useState) };
});
const roots: string[] = [];
const now = Date.parse("2026-10-16T12:34:56Z");
const snapshot = (provider: ApiBillingProvider, capturedAt = now): ApiBillingSnapshot => {
  const at = new Date(capturedAt), monthStart = Date.UTC(at.getUTCFullYear(), at.getUTCMonth(), 1);
  return { schema: 1, provider, capturedAt, monthStart, periodEnd: capturedAt, currency: "USD", daily: [{ start: monthStart, end: monthStart + 86400000, amountUSD: provider === "openai" ? 12.34 : 5.67 }] };
};
afterEach(() => { vi.restoreAllMocks(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
async function setup(mode: "live" | "demo" | "codex" | "claude" = "live") {
  const home = mkdtempSync(join(tmpdir(), "meterusage-api-ui-")); roots.push(home);
  const isolated = launchConfiguration(["--demo", "--candidate-profile", home], {});
  const preferences = await Preferences.load(isolated);
  const launch = { ...isolated, demo: mode === "demo", ...(mode === "codex" ? { codexTest: true } : {}), ...(mode === "claude" ? { claudeTest: true } : {}) };
  const c = new Coordinator(launch, preferences, [], () => now);
  const view = (): ViewState => ({ snapshot: c.snapshot(), settings: { values: {}, accounts: [] }, systemDark: false, notch: { expanded: false, cardOnRight: false, selected: "", dragging: false } });
  return { c, home, view };
}
it("refresh projects billing independently and removes a value after a file becomes unavailable", async () => {
  const { c, home, view } = await setup();
  billing.writeApiBilling(home, snapshot("openai"));
  billing.writeApiBilling(home, snapshot("anthropic"));
  // Extra private fields never cross the snapshot projection.
  const path = billing.apiBillingPath(home, "openai");
  writeFileSync(path, JSON.stringify({ ...JSON.parse(readFileSync(path, "utf8")), privateField: "OMIT_PRIVATE" }));
  const before = c.json();
  await c.refresh();
  expect(c.snapshot().apiBilling?.openai).toMatchObject({ status: "value", stale: false, value: { provider: "openai" } });
  expect(JSON.stringify(c.snapshot())).not.toContain("OMIT_PRIVATE");
  expect(c.snapshot().slots).toEqual([]); expect(c.snapshot().archived).toEqual({}); expect(c.json()).toBe(before);
  let cards = renderToStaticMarkup(createElement(ApiBillingCards, { state: view() }));
  expect(cards).toContain("$12.34"); expect(cards).toContain("$5.67");
  writeFileSync(path, "{}");
  await c.refresh();
  expect(c.snapshot().apiBilling?.openai).toEqual({ status: "missing", code: "unavailable" });
  cards = renderToStaticMarkup(createElement(ApiBillingCards, { state: view() }));
  expect(cards).not.toContain("OpenAI API"); expect(cards).toContain("Anthropic API");
  const settings = renderToStaticMarkup(createElement(ApiBillingConnections, { state: view(), action: async () => {} }));
  expect(settings).toContain("Billing snapshot unavailable. Fetch again to replace it.");
});
it.each(["demo", "codex", "claude"] as const)("does not discover snapshots in the %s profile", async mode => {
  const { c, home } = await setup(mode);
  billing.writeApiBilling(home, snapshot("openai"));
  const read = vi.spyOn(billing, "readApiBilling");
  await c.refresh();
  expect(read).not.toHaveBeenCalled(); expect(c.snapshot().apiBilling).toBeUndefined();
});
it("renders exact UTC snapshot age, old-month period and separate billing without invented allowances", async () => {
  const { c, view } = await setup();
  c.apiBilling = { openai: { status: "value", stale: false, value: snapshot("openai") }, anthropic: { status: "value", stale: true, value: snapshot("anthropic", Date.parse("2026-09-30T23:45:12Z")) } };
  const markup = renderToStaticMarkup(createElement(ApiBillingCards, { state: view() }));
  for (const text of ["OpenAI API", "Anthropic API", "API billing", "Provider-reported billing", "USD", "2026-09-01 to 2026-09-30 UTC", "2026-09-30T23:45:12.000Z", "2026-10-16T12:34:56.000Z", "Stale snapshot", "Priority Tier excluded."]) expect(markup).toContain(text);
  for (const text of ["tokens", "quota", "%", "current month", "Codex", "Claude Desktop"]) expect(markup).not.toContain(text);
});
it("separates API setup from app connections and explains one-time Admin keys", async () => {
  const { view } = await setup();
  const markup = renderToStaticMarkup(createElement(ApiBillingConnections, { state: view(), action: async () => {} }));
  for (const text of ["OpenAI API", "Anthropic API", "Admin key", "never saved", "No billing snapshot yet.", "Fetch billing"]) expect(markup).toContain(text);
  expect(markup.match(/type="password"/g)).toHaveLength(2);
  const connections = renderToStaticMarkup(createElement(Connections, { state: view(), action: async () => {} }));
  for (const text of ["OpenAI API", "Anthropic API", 'type="password"', "API connections", "Fetch billing"]) expect(connections).not.toContain(text);
  expect(connections).toContain("Choose how to connect");
});

it("places billing on the flyout only and preserves tray, notch and share surfaces", async () => {
  const { c, view } = await setup();
  c.apiBilling = { openai: { status: "value", stale: false, value: snapshot("openai") } };
  for (const surface of ["flyout", "tray", "notch", "share"]) {
    vi.stubGlobal("location", { search: `?surface=${surface}` });
    vi.mocked(useState).mockReturnValueOnce([view(), () => {}]).mockReturnValueOnce(["", () => {}]);
    try {
      const markup = renderToStaticMarkup(createElement(App, { bridge: { request: async () => ({ ok: true as const }), subscribe: () => () => {} } }));
      if (surface === "flyout") expect(markup).toContain("OpenAI API");
      else expect(markup).not.toContain("OpenAI API");
    } finally { vi.unstubAllGlobals(); }
  }
});

it("distinguishes no reported cost buckets from an explicit zero-cost bucket", async () => {
  const { c, view } = await setup();
  const empty = snapshot("openai"); empty.daily = [];
  c.apiBilling = { openai: { status: "value", stale: false, value: empty } };
  const noBuckets = renderToStaticMarkup(createElement(ApiBillingCards, { state: view() }));
  expect(noBuckets).toContain("No cost buckets reported"); expect(noBuckets).not.toContain("$0.00");
  const zero = snapshot("openai"); zero.daily[0].amountUSD = 0;
  c.apiBilling.openai = { status: "value", stale: false, value: zero };
  const explicitZero = renderToStaticMarkup(createElement(ApiBillingCards, { state: view() }));
  expect(explicitZero).toContain("$0.00"); expect(explicitZero).not.toContain("No cost buckets reported");
  const settings = renderToStaticMarkup(createElement(ApiBillingConnections, { state: view(), action: async () => {} }));
  expect(settings).not.toContain("docs/API_USAGE_BETA.md");
});
