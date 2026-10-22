import { afterEach, describe, expect, it, vi } from "vite-plus/test";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { museCodeQuota, museCodeRPC } from "../src/main/providers/muse-code";
import { headlineWindow, primary } from "../src/domain/models";
import { limitsReport } from "../src/domain/report";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { Connections, ProviderCard } from "../src/renderer/app";
import { previewBridge } from "../src/renderer/preview";
import { parseRequest } from "../src/main/ipc";
import { Preferences } from "../src/main/preferences";
import { compose } from "../src/main/composition";
import * as transport from "../src/main/providers/transport";
import { jsonReport } from "../src/main/cli";
import { Coordinator } from "../src/main/coordinator";
import { readArchive } from "../src/main/history";
import { type Source } from "../src/main/composition";

const now = Date.parse("2026-10-17T12:00:00Z");
const usage = () => ({ observedAtMs: now - 60000, tier: "power", window: { usedPercent: 27, resetsAtMs: now + 3600000, windowDurationMins: 300 }, weekly: { usedPercent: 52, resetsAtMs: now + 86400000 } });
const response = (value: unknown) => JSON.stringify({ jsonrpc: "2.0", id: 2, result: { usage: value } });
const roots: string[] = [];
afterEach(() => { vi.restoreAllMocks(); for (const path of roots.splice(0)) rmSync(path, { recursive: true, force: true }); });
function binary(body: string) {
  const root = mkdtempSync(join(tmpdir(), "meterusage-muse-fixture-")); roots.push(root);
  const path = join(root, "muse");
  writeFileSync(path, `#!${process.execPath}\n${body}\n`, { mode: 0o700 }); chmodSync(path, 0o700);
  return path;
}

describe("Muse Code allowance", () => {
  it("preserves observation age and provider percentages, including over-quota values", () => {
    const payload = usage(); payload.window.usedPercent = 127;
    const q = museCodeQuota(response(payload), now);
    expect(q).toMatchObject({ provider: "muse", capturedAt: now - 60000, planType: "power", windows: [{ label: "Session", usedPercent: 127, windowDurationMins: 300 }, { label: "Weekly", usedPercent: 52, windowDurationMins: 10080 }] });
    expect(headlineWindow("muse", q.windows)?.label).toBe("Session");
    expect(limitsReport([primary("muse")], { muse: { status: "value", value: q } }, {}, now).providers[0]).toMatchObject({ provider: "muse", windows: [{ used_percent: 127, remaining_percent: 0 }, { used_percent: 52 }] });
    expect(limitsReport([primary("muse")], { muse: { status: "value", value: q } }, {}, now)).toMatchObject({ generated_at: "2026-10-17T12:00:00Z", providers: [{ observed_at: "2026-10-17T11:59:00Z" }] });
    expect(q).not.toHaveProperty("credits");
  });
  it("projects only quota metadata and omits unsafe tier text", () => {
    const payload = { ...usage(), tier: "OMIT@example.invalid", token: "OMIT_TOKEN", prompt: "OMIT_PROMPT", account: "OMIT_ACCOUNT" };
    const result = JSON.stringify(museCodeQuota(response(payload), now));
    expect(result).not.toContain("OMIT"); expect(result).not.toContain("planType");
  });
  it.each([
    () => ({}), () => ({ ...usage(), window: undefined }), () => ({ ...usage(), weekly: null }),
    () => ({ ...usage(), observedAtMs: now + 1 }), () => ({ ...usage(), observedAtMs: 0 }),
    () => ({ ...usage(), window: { ...usage().window, usedPercent: -1 } }),
    () => ({ ...usage(), weekly: { ...usage().weekly, usedPercent: "20" } }),
    () => ({ ...usage(), window: { ...usage().window, usedPercent: 0.5 } }),
    () => ({ ...usage(), window: { ...usage().window, windowDurationMins: 0 } }),
    () => ({ ...usage(), weekly: { ...usage().weekly, resetsAtMs: now } }),
    () => ({ ...usage(), weekly: { ...usage().weekly, resetsAtMs: Number.MAX_SAFE_INTEGER } }),
  ])("leaves absent, expired or malformed usage unavailable", make => {
    expect(() => museCodeQuota(response(make()), now)).toThrow("No usage yet");
  });
  it("rejects missing observations, duplicate fields and provider errors without exposing raw errors", () => {
    for (const raw of ['{"result":{}}', '{"result":{"usage":null}}', '{"error":{"code":-32601,"message":"OMIT_PROVIDER_ERROR"}}', response(usage()).replace('"usedPercent":27', '"usedPercent":27,"usedPercent":1')]) {
      expect(() => museCodeQuota(raw, now)).toThrow("No usage yet");
    }
  });
  it("completes the official MSP handshake and only sends usage/read", async () => {
    const executable = binary(`
      const readline = require('node:readline');
      let phase = 0;
      readline.createInterface({ input: process.stdin }).on('line', line => {
        const m = JSON.parse(line);
        if (process.argv.slice(2).join(' ') !== 'serve' || m.jsonrpc !== '2.0') process.exit(2);
        if (phase === 0 && m.method === 'initialize' && m.params.capabilities.experimentalApi === true && m.params.capabilities.userInputDialogs === false) {
          phase++; process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { experimentalApi: true, museHome: 'OMIT_HOME' } }) + '\\n');
        } else if (phase === 1 && m.method === 'initialized') { phase++; }
        else if (phase === 2 && m.method === 'usage/read') {
          phase++; process.stdout.write(JSON.stringify({ jsonrpc: '2.0', method: 'usage/changed', params: { private: 'OMIT' } }) + '\\n');
          const result = ${JSON.stringify(response(usage()) + "\n")};
          process.stdout.write(result.slice(0, 35)); setTimeout(() => process.stdout.write(result.slice(35)), 5);
        } else process.exit(3);
      });
    `);
    const result = await museCodeRPC(executable, {});
    expect(museCodeQuota(result, now).windows[0].usedPercent).toBe(27);
  });
  it("fails closed when experimental usage is unavailable", async () => {
    const executable = binary(`require('node:readline').createInterface({ input: process.stdin }).once('line', () => process.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"experimentalApi":false}}\\n'));`);
    await expect(museCodeRPC(executable, {})).rejects.toThrow("No usage yet");
  });
  it("settles cancellation without leaving a provider subprocess running", async () => {
    const executable = binary("setInterval(() => {}, 1000)");
    const controller = new AbortController(), result = museCodeRPC(executable, { signal: controller.signal });
    controller.abort();
    await expect(result).rejects.toThrow("Provider request cancelled");
  });
  it("starts disabled, reads the selected CLI and stays out of isolated provider profiles", async () => {
    const executable = binary(`require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
      const m = JSON.parse(line);
      if (m.method === 'initialize') process.stdout.write('{"jsonrpc":"2.0","id":1,"result":{"experimentalApi":true}}\\n');
      if (m.method === 'usage/read') process.stdout.write(${JSON.stringify(response(usage()) + "\n")});
    });`);
    const home = roots.at(-1)!, launch = { home, data: join(home, "app-data"), env: {}, demo: false, candidate: false };
    const prefs = await Preferences.load(launch, async () => "");
    expect(prefs.enabled("muse")).toBe(false);
    const resolve = vi.spyOn(transport, "cliPath").mockImplementation(name => { expect(name).toBe("muse"); return executable; });
    const disabled = compose(launch, prefs, { now: () => now }).filter(s => s.slot.provider === "muse");
    expect(await jsonReport(disabled, now)).toMatchObject({ providers: [] });
    expect(resolve).not.toHaveBeenCalled();
    await prefs.set("showProviderMuse", true);
    expect(prefs.enabled("muse")).toBe(true);
    const source = compose(launch, prefs, { now: () => now }).find(s => s.slot.provider === "muse")!;
    await expect(source.quota!()).resolves.toMatchObject({ provider: "muse", capturedAt: now - 60000 });
    expect(resolve).toHaveBeenCalledOnce();
    for (const mode of ["codexTest", "claudeTest"] as const) expect(compose({ ...launch, candidate: true, [mode]: true }, prefs).some(s => s.slot.provider === "muse")).toBe(false);
  });
  it("keeps Muse allowance in memory and preserves the legacy archive for rollback", async () => {
    const root = mkdtempSync(join(tmpdir(), "meterusage-muse-archive-")); roots.push(root);
    const data = usage(); data.window.usedPercent = 127;
    const q = museCodeQuota(response(data), now), path = join(root, "quota-archive.json");
    const codex = { ...museCodeQuota(response(usage()), now), provider: "codex" as const, resetPacingSince: now - 120000 };
    const launch = { home: root, data: root, env: {}, demo: true, candidate: true };
    const prefs = await Preferences.load(launch);
    const coordinator = new Coordinator(launch, prefs, [{ slot: primary("codex"), quota: async () => codex }, { slot: primary("muse"), quota: async () => q }], () => now);
    try {
      await coordinator.refresh();
      expect(coordinator.snapshot().archived.muse.windows[0].usedPercent).toBe(127);
      const stored: { provider: string }[] = JSON.parse(readFileSync(path, "utf8"));
      expect(stored.map(entry => entry.provider)).toEqual(["codex"]);
      const restored = readArchive(path);
      expect(restored.muse).toBeUndefined();
      expect(restored.codex).toEqual(codex);
    } finally { coordinator.stop(); }
  });
  it("aborts a removed Muse read and rejects its result after a quick stop/start", async () => {
    const root = mkdtempSync(join(tmpdir(), "meterusage-muse-cancel-")); roots.push(root);
    const launch = { home: root, data: root, env: {}, demo: true, candidate: true };
    const prefs = await Preferences.load(launch);
    let oldSignal: AbortSignal | undefined, stableSignal: AbortSignal | undefined, release!: (q: ReturnType<typeof museCodeQuota>) => void, releaseStable!: () => void, ready!: () => void;
    const started = new Promise<void>(resolve => { ready = resolve; });
    const held = new Promise<void>(resolve => { releaseStable = resolve; });
    const q = museCodeQuota(response(usage()), now);
    const old: Source = { slot: primary("muse"), quota: signal => { oldSignal = signal; ready(); return new Promise(resolve => { release = resolve; }); } };
    const stable: Source = { slot: primary("claude"), quota: async signal => { stableSignal = signal; await held; return { ...q, provider: "claude" }; } };
    const coordinator = new Coordinator(launch, prefs, [old, stable], () => now);
    coordinator.quotaActivity.record("muse", q, now);
    const previousDays = coordinator.quotaActivity.days("muse"), previousFile = readFileSync(join(root, "quota-activity.json"), "utf8");
    const pending = coordinator.refresh();
    try {
      await started; await prefs.set("showProviderMuse", false);
      coordinator.sources = [stable]; coordinator.forgetQuota("muse", true);
      expect(coordinator.quotaActivity.days("muse")).toEqual(previousDays);
      expect(oldSignal?.aborted).toBe(true); expect(stableSignal?.aborted).toBe(false);
      await prefs.set("showProviderMuse", true);
      const next: Source = { slot: primary("muse"), quota: async () => q };
      coordinator.sources = [stable, next];
      const stale = usage(); stale.window.usedPercent = 99;
      release(museCodeQuota(response(stale), now)); releaseStable(); await pending;
      expect(coordinator.quotas.muse).toMatchObject({ status: "value", value: { windows: [{ usedPercent: 27 }, { usedPercent: 52 }] } });
      expect(coordinator.quotaActivity.days("muse")).toEqual(previousDays);
      expect(readFileSync(join(root, "quota-activity.json"), "utf8")).toBe(previousFile);
    } finally { coordinator.stop(); release?.(q); releaseStable(); await pending; }
  });
  it("renders its separate setup and dated allowance without inventing activity", async () => {
    const bridge = await previewBridge(), reply = await bridge.request({ action: "state" });
    if (!reply.ok || !reply.state) throw new Error("Missing demo state");
    const state = reply.state;
    state.settings.values.showProviderMuse = false;
    const action = async () => {};
    const setup = renderToStaticMarkup(createElement(Connections, { state, action }));
    expect(setup).toContain("Use Muse Code CLI"); expect(setup).toContain("Muse.ai allowance is separate");
    const card = renderToStaticMarkup(createElement(ProviderCard, { slot: primary("muse"), state, action }));
    expect(card).toContain("Observed "); expect(card).toContain("CLI subscription allowance");
    expect(card).not.toContain("Measured tokens"); expect(card).not.toContain("Activity on this Mac");
    expect(parseRequest({ action: "setPreference", key: "showProviderMuse", value: true })).toEqual({ action: "setPreference", key: "showProviderMuse", value: true });
  });
});
