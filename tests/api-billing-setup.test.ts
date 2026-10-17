import { describe, expect, it } from "vite-plus/test";
import { readFileSync } from "node:fs";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { ApiBillingSetup } from "../src/renderer/api-billing-setup";

describe("API billing setup instructions", () => {
  it("renders collapsed setup guidance without a credential field", () => {
    const html = renderToStaticMarkup(createElement(ApiBillingSetup));
    expect(html).toContain("<details"); expect(html).not.toContain(" open=");
    expect(html).toContain("Organization → Admin keys"); expect(html).toContain("Console → Settings → Admin keys");
    expect(html).toContain("OPENAI_ADMIN_KEY"); expect(html).toContain("ANTHROPIC_ADMIN_KEY");
    expect(html).toContain("api-usage-helper.cjs openai"); expect(html).toContain("api-usage-helper.cjs anthropic");
    expect(html).toContain("Project API keys"); expect(html).toContain("subscription sign-in");
    expect(html).toContain("Refresh rereads the snapshot"); expect(html).toContain("existing OpenRouter connection");
    expect(html).not.toMatch(/<input|<textarea|type="password"/);
  });

  it("documents only key-free installed helper commands and the refresh sequence", () => {
    const guide = readFileSync(new URL("../docs/API_USAGE_BETA.md", import.meta.url), "utf8");
    const helper = readFileSync(new URL("../src/main/api-usage-helper.ts", import.meta.url), "utf8");
    expect(guide).toContain("api-usage-helper.cjs openai"); expect(guide).toContain("api-usage-helper.cjs anthropic");
    expect(guide).toContain("OPENAI_ADMIN_KEY"); expect(guide).toContain("ANTHROPIC_ADMIN_KEY");
    expect(guide).toContain("Refresh does not contact");
    expect(helper).toContain("env[name]"); expect(helper).toContain("delete env[name]");
    expect(helper).not.toMatch(/process\.argv\.slice\(.*KEY/);
  });
});
