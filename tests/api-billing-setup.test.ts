import { describe, expect, it, vi, afterEach } from "vite-plus/test";
import { readFileSync } from "node:fs";
import { createElement, useRef } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ApiBillingSetup } from "../src/renderer/api-billing-setup";

vi.mock("react", async original => {
  const actual = await original<typeof import("react")>();
  return { ...actual, useRef: vi.fn(actual.useRef), useState: vi.fn(() => [false, vi.fn()]) };
});
afterEach(() => vi.restoreAllMocks());

describe("one-time API billing setup", () => {
  it.each(["openai", "anthropic"] as const)("shows a masked %s Admin key field without Terminal instructions", provider => {
    const html = renderToStaticMarkup(createElement(ApiBillingSetup, { provider, disabled: false, action: async () => {} }));
    expect(html).toContain('type="password"'); expect(html).toContain('autoComplete="off"');
    expect(html).toContain('maxLength="8192"'); expect(html).toContain("Fetch billing");
    expect(html).toContain(provider === "openai" ? "Organization settings → Admin keys" : "Settings → Admin keys");
    expect(html).not.toMatch(/<pre|<code|ELECTRON_RUN_AS_NODE|OPENAI_ADMIN_KEY|ANTHROPIC_ADMIN_KEY/);
  });

  it.each([false, true])("clears the field before fetching and releases duplicate-submit protection after success/failure (%s)", async fails => {
    const field = { value: "  synthetic-admin  " }, input = { current: field }, pending = { current: false };
    vi.mocked(useRef).mockReturnValueOnce(input).mockReturnValueOnce(pending);
    let finish!: () => void;
    const action = vi.fn(() => new Promise<void>((resolve, reject) => { finish = () => fails ? reject(new Error("Synthetic failure")) : resolve(); }));
    const form = ApiBillingSetup({ provider: "openai", disabled: false, action });
    const event = { preventDefault: vi.fn() };
    const submission = form.props.onSubmit(event);
    expect(field.value).toBe("");
    expect(action).toHaveBeenCalledExactlyOnceWith({ action: "apiBillingFetch", provider: "openai", adminKey: "synthetic-admin" });
    field.value = "second-synthetic";
    await form.props.onSubmit(event); expect(action).toHaveBeenCalledTimes(1);
    finish();
    if (fails) await expect(submission).rejects.toThrow("Synthetic failure"); else await submission;
    expect(pending.current).toBe(false);
  });

  it("blocks access in demo profiles", async () => {
    vi.mocked(useRef).mockReturnValueOnce({ current: { value: "synthetic-admin" } }).mockReturnValueOnce({ current: false });
    const action = vi.fn(async () => {}), props = { provider: "anthropic" as const, disabled: true, action };
    const form = ApiBillingSetup(props);
    await form.props.onSubmit({ preventDefault: vi.fn() }); expect(action).not.toHaveBeenCalled();
    const html = renderToStaticMarkup(createElement(ApiBillingSetup, props));
    expect(html.match(/disabled=""/g)).toHaveLength(3);
  });

  it("uses the saved-key action without sending or retaining input", async () => {
    const field = { value: "synthetic-unsubmitted" }, pending = { current: false };
    vi.mocked(useRef).mockReturnValueOnce({ current: field }).mockReturnValueOnce(pending);
    const action = vi.fn(async () => {}), form = ApiBillingSetup({ provider: "openai", disabled: false, action });
    const button = form.props.children[0];
    await button.props.onClick();
    expect(field.value).toBe(""); expect(pending.current).toBe(false);
    expect(action).toHaveBeenCalledExactlyOnceWith({ action: "apiBillingFetchSaved", provider: "openai" });
  });

  it("retains the advanced environment helper as an optional setup path", () => {
    const guide = readFileSync(new URL("../docs/API_USAGE_BETA.md", import.meta.url), "utf8");
    const helper = readFileSync(new URL("../src/main/api-usage-helper.ts", import.meta.url), "utf8");
    expect(guide).toContain("Settings → API connections");
    expect(guide).toContain("Fetch billing"); expect(guide).toContain("not saved");
    expect(guide).toContain("api-usage-helper.cjs openai"); expect(guide).toContain("api-usage-helper.cjs anthropic");
    expect(helper).toContain("delete env[name]");
  });
});
