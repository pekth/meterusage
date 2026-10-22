import { describe, it, expect } from "vite-plus/test";
import { parseRequest, trustedSender, projectSettings } from "../src/main/ipc";
describe("renderer boundary", () => {
  it("accepts only no-argument Claude usage-page intent", () => {
    expect(parseRequest({ action: "claudeUsagePage" })).toEqual({ action: "claudeUsagePage" });
    for (const field of ["url", "account", "profile", "provider", "path", "cookie"]) expect(() => parseRequest({ action: "claudeUsagePage", [field]: "synthetic" })).toThrow("Invalid request");
  });
  it("allows only fixed providers and no credential or selector in saved-key requests", () => {
    for (const provider of ["openai", "anthropic"]) expect(parseRequest({ action: "apiBillingFetchSaved", provider })).toEqual({ action: "apiBillingFetchSaved", provider });
    for (const provider of ["openAI", "claude", null, 1]) expect(() => parseRequest({ action: "apiBillingFetchSaved", provider })).toThrow("Invalid request");
    for (const field of ["adminKey", "service", "account", "path", "allowUI"]) expect(() => parseRequest({ action: "apiBillingFetchSaved", provider: "openai", [field]: "synthetic" })).toThrow("Invalid request");
  });
  it("accepts only an exact one-run API billing request with a bounded header-safe key", () => {
    for (const provider of ["openai", "anthropic"]) for (const adminKey of ["x", "synthetic-admin-key", "x".repeat(8192)]) {
      const request = { action: "apiBillingFetch", provider, adminKey };
      expect(parseRequest(request)).toEqual(request);
    }
    const request = { action: "apiBillingFetch", provider: "openai", adminKey: "synthetic" };
    for (const adminKey of ["", "x".repeat(8193), "a b", "a\u00a0b", "a\u2028b", ...Array.from({ length: 32 }, (_, n) => `a${String.fromCharCode(n)}b`), "a\x7fb", null, 1, ["synthetic"], {}]) expect(() => parseRequest({ ...request, adminKey })).toThrow("Invalid request");
    for (const provider of ["codex", "claude", "OPENAI", ["openai"], null, 1]) expect(() => parseRequest({ ...request, provider })).toThrow("Invalid request");
    for (const raw of [{ action: request.action }, { action: request.action, provider: "openai" }, { ...request, url: "https://example.invalid" }, { ...request, path: "/synthetic" }, { ...request, save: true }]) expect(() => parseRequest(raw)).toThrow("Invalid request");
    expect(() => parseRequest(Object.assign(Object.create({ adminKey: "synthetic" }), { action: request.action, provider: "openai" }))).toThrow("Invalid request");
    expect(() => parseRequest({ action: "setPreference", key: "adminKey", value: "synthetic" })).toThrow("Invalid request");
    expect(projectSettings({ adminKey: "synthetic" }, [], "/synthetic").values).not.toHaveProperty("adminKey");
  });
  it("accepts report intent without renderer-selected content or destination", () => {
    expect(parseRequest({ action: "sendReport" })).toEqual({ action: "sendReport" });
    expect(() => parseRequest({ action: "setPreference", key: "reportNextAllowedAt", value: 0 })).toThrow();
    for (const extra of [{ diagnostics: "private" }, { url: "https://example.invalid" }, { id: "chosen" }, { consent: true }, { body: {} }]) expect(() => parseRequest({ action: "sendReport", ...extra })).toThrow();
  });
  it("accepts and publishes only Small, Medium and Large panel sizes", () => {
    for (const value of ["small", "medium", "large"]) {
      const request = { action: "setPreference", key: "panelSize", value };
      expect(parseRequest(request)).toEqual(request);
      expect(projectSettings({ panelSize: value }, [], "/synthetic").values.panelSize).toBe(value);
    }
    for (const value of ["", "Small", "extra-large", "__proto__", ["large"], 1, true, null]) expect(() => parseRequest({ action: "setPreference", key: "panelSize", value })).toThrow("Invalid request");
  });
  it("requires primitive provider names before connection consent", () => {
    for (const action of ["connect", "disconnect", "connectionCancel", "connectionLocal"]) {
      for (const provider of [["claude"], ["codex"], { toString: () => "claude" }, null, 1]) expect(() => parseRequest({ action, provider })).toThrow("Invalid request");
      for (const provider of ["codex", "claude", "grok"]) expect(parseRequest({ action, provider })).toEqual({ action, provider });
    }
  });
  it("requires exactly a provider for explicit CLI selection", () => {
    for (const request of [{ action: "connectionLocal" }, { action: "connectionLocal", provider: "other" }, { action: "connectionLocal", provider: "codex", path: "/tmp" }, { action: "connectionLocal", provider: "claude", consent: true }, { action: "connectionLocal", provider: "grok", source: "cli" }]) expect(() => parseRequest(request)).toThrow("Invalid request");
  });
  it("rejects arbitrary paths, settings, malformed accounts and unknown fields", () => {
    for (const r of [null, [], { action: "open", path: "/tmp" }, { action: "accountAdd", provider: "codex", path: "/tmp" }, { action: "setPreference", key: "managedAccounts", value: [] }, { action: "setPreference", key: "updateLastCheckDate", value: 1 }, { action: "accountUpdate", id: "../a", label: "a", enabled: true }, { action: "reset", key: "codex#../a", creditID: "a" }, { action: "refresh", args: [] }, { action: "resize", height: Infinity }]) expect(() => parseRequest(r)).toThrow();
    expect(parseRequest({ action: "setPreference", key: "showProviderCodex", value: true })).toEqual({ action: "setPreference", key: "showProviderCodex", value: true });
    expect(parseRequest({ action: "reset", key: "codex#fixture-account", creditID: "credit-1" }).action).toBe("reset");
    expect(parseRequest({ action: "accountUpdate", id: "fixture-account", label: "Work" })).toEqual({ action: "accountUpdate", id: "fixture-account", label: "Work" });
    expect(parseRequest({ action: "accountUpdate", id: "fixture-account", enabled: false }).action).toBe("accountUpdate");
    expect(parseRequest({ action: "accountPath", id: "fixture-account" }).action).toBe("accountPath");
    for (const request of [{ action: "accountUpdate", id: "fixture-account" }, { action: "accountUpdate", id: "fixture-account", enabled: undefined }, { action: "accountPath", id: "fixture-account", path: "/tmp" }]) expect(() => parseRequest(request)).toThrow();
  });
  it("requires the registered window, document and main frame", () => {
    const frame = { url: "file:///app/index.html?surface=flyout" }, documents = new Map([[10, frame.url]]);
    const sender = { id: 10, mainFrame: frame };
    expect(trustedSender({ sender, senderFrame: frame }, documents)).toBe(true);
    expect(trustedSender({ sender, senderFrame: { ...frame } }, documents)).toBe(false);
    expect(trustedSender({ sender: { id: 11, mainFrame: frame }, senderFrame: frame }, documents)).toBe(false);
    frame.url = "https://example.invalid";
    expect(trustedSender({ sender, senderFrame: frame }, documents)).toBe(false);
  });
});

it("projects configured directories to Settings only", () => {
  const accounts = [{ id: "fixture", provider: "codex" as const, label: "Work", path: "/invented/home/config-directory", enabled: true }];
  for (const surface of ["flyout", "notch", "tray", "share"] as const) {
    const settings = projectSettings({ managedAccounts: accounts }, accounts, "/invented/home", surface);
    expect(settings.accounts[0]).not.toHaveProperty("pathLabel"); expect(JSON.stringify(settings)).not.toContain("config-directory");
  }
  expect(projectSettings({}, accounts, "/invented/home", "settings").accounts[0].pathLabel).toBe("~/config-directory");
});

it("binds sharing to the displayed account key", () => {
  expect(parseRequest({ action: "share", key: "claude#fixture-account" })).toEqual({ action: "share", key: "claude#fixture-account" });
  for (const raw of [{ action: "share" }, { action: "share", key: "claude#../other" }, { action: "share", key: "claude", path: "/tmp" }]) expect(() => parseRequest(raw)).toThrow();
});

it("allows natural panel heights for native display clamping and keeps separate share requests", () => {
  expect(parseRequest({ action: "resize", height: 2500 })).toEqual({ action: "resize", height: 2500 });
  expect(parseRequest({ action: "shareResize", height: 2500 })).toEqual({ action: "shareResize", height: 2500 });
  expect(parseRequest({ action: "shareResize", height: 5000 }).action).toBe("shareResize");
  for (const raw of [{ action: "resize", height: NaN }, { action: "resize", height: 0 }, { action: "resize", height: "2500" }, { action: "shareResize", height: Infinity }, { action: "shareResize", height: 0 }, { action: "shareResize", height: 100, width: 250 }]) expect(() => parseRequest(raw)).toThrow();
});

it("allows only known public service-status pages, without a renderer-selected URL", () => {
  expect(parseRequest({ action: "statusPage", provider: "claude" })).toEqual({ action: "statusPage", provider: "claude" });
  for (const raw of [{ action: "statusPage", provider: "grok" }, { action: "statusPage", provider: "claude", url: "https://example.invalid" }, { action: "statusPage", provider: "https://example.invalid" }]) expect(() => parseRequest(raw)).toThrow();
});

it("rejects removed strip and legacy pin edits and excludes strip mode from settings", () => {
  for (const value of ["usage", "dots"]) {
    expect(() => parseRequest({ action: "setPreference", key: "sideNotchStripMode", value })).toThrow();
    expect(projectSettings({ sideNotchStripMode: value }, [], "/synthetic").values).not.toHaveProperty("sideNotchStripMode");
  }
  expect(() => parseRequest({ action: "setPreference", key: "sideNotchPanelPinned", value: true })).toThrow();
});

it("keeps Grok Cursor credentials and identity outside renderer-controlled connection requests", () => {
  for (const extra of [{ token: "synthetic" }, { cookie: "synthetic" }, { identity: "a".repeat(64) }, { path: "/synthetic" }, { url: "https://example.invalid" }, { consent: true }]) expect(() => parseRequest({ action: "connect", provider: "grok", ...extra })).toThrow("Invalid request");
  expect(() => parseRequest({ action: "setPreference", key: "desktopGrokIdentity", value: "a".repeat(64) })).toThrow("Invalid request");
  expect(projectSettings({ desktopGrokIdentity: "a".repeat(64) }, [], "/synthetic").values).not.toHaveProperty("desktopGrokIdentity");
});
