import { describe, it, expect } from "vite-plus/test";
import { parseRequest, trustedSender, projectSettings } from "../src/main/ipc";
describe("renderer boundary", () => {
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

it("reports full shared-card height separately from bounded window resizing", () => {
  expect(parseRequest({ action: "shareResize", height: 2500 })).toEqual({ action: "shareResize", height: 2500 });
  expect(parseRequest({ action: "shareResize", height: 5000 }).action).toBe("shareResize");
  for (const raw of [{ action: "resize", height: 2500 }, { action: "shareResize", height: Infinity }, { action: "shareResize", height: 0 }, { action: "shareResize", height: 100, width: 250 }]) expect(() => parseRequest(raw)).toThrow();
});
