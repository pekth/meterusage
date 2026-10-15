import { it, expect } from "vite-plus/test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { providers, primary, slotKey, value, quota, window, type Provider } from "../src/domain/models";
import { normalizeProviderOrder, validProviderOrder, orderedSlots, moveProvider } from "../src/domain/provider-order";
import { Preferences } from "../src/main/preferences";
import { parseRequest, projectSettings } from "../src/main/ipc";
import { Coordinator } from "../src/main/coordinator";
import { notchEntries } from "../src/domain/notch";
import { trayTooltip } from "../src/domain/overview";
import { previewBridge } from "../src/renderer/preview";
const order: Provider[] = ["claude", ...providers.filter(p => p !== "claude")];
it("normalizes damaged and older orders without dropping providers", () => {
  for (const raw of [undefined, null, {}, "claude", 1]) expect(normalizeProviderOrder(raw)).toEqual(providers);
  expect(normalizeProviderOrder(["claude", "claude", "unknown", null, ["grok"], "grok"])).toEqual(["claude", "grok", ...providers.filter(p => p !== "claude" && p !== "grok")]);
  expect(normalizeProviderOrder(["claude"])).toEqual(order);
  expect(validProviderOrder(order)).toBe(true);
  const sparse = [...order]; delete sparse[0]; expect(validProviderOrder(sparse)).toBe(false);
  expect(() => parseRequest({ action: "providerOrder", order: sparse })).toThrow();
  for (const raw of [[], ["claude"], [...order, "claude"], [...order.slice(1), "unknown"]]) expect(validProviderOrder(raw)).toBe(false);
  expect(orderedSlots([primary("codex"), primary("claude"), { ...primary("codex"), slotID: "work" }, { ...primary("claude"), slotID: "second" }], order).map(slotKey)).toEqual(["claude", "claude#second", "codex", "codex#work"]);
  expect(moveProvider(order, "claude", -1)).toEqual(order);
  expect(moveProvider(order, "gemini", 1)).toEqual(order);
  expect(moveProvider(order, "claude", 1).slice(0, 2)).toEqual(["codex", "claude"]);
});
it("persists and reloads order, normalizes legacy input and rejects invalid writes at IPC", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-order-")), launch = { home: root, data: root, demo: true, candidate: true, env: {} };
  try {
    const prefs = await Preferences.load(launch); await prefs.set("providerOrder", order);
    expect((await Preferences.load(launch)).providerOrder).toEqual(order);
    expect(projectSettings(prefs.values, [], root).providerOrder).toEqual(order);
    expect(parseRequest({ action: "providerOrder", order })).toEqual({ action: "providerOrder", order });
    for (const invalid of [null, [], ["claude"], [...order, "claude"], [...order.slice(1), "unknown"]]) {
      expect(() => parseRequest({ action: "providerOrder", order: invalid })).toThrow();
      await expect(prefs.set("providerOrder", invalid)).rejects.toThrow();
      expect(prefs.providerOrder).toEqual(order);
    }
    expect(() => parseRequest({ action: "providerOrder", order, payload: "external" })).toThrow();
    writeFileSync(join(root, "preferences.json"), JSON.stringify({ providerOrder: ["claude", "claude", "unknown"] }));
    expect((await Preferences.load(launch)).providerOrder).toEqual(order);
  } finally { rmSync(root, { recursive: true, force: true }); }
});
it("writes defaults data only after validation and keeps saved order on failure", async () => {
  let stored = [...providers], fail = false;
  const launch = { home: "/synthetic", data: "/synthetic", demo: false, candidate: false, env: {} };
  const command = async (_binary: string, args: string[]) => {
    if (args[2] !== "providerOrder") throw new Error("Absent fixture key");
    if (args[0] === "read-type") return "Type is data";
    if (args[0] === "read") return `<${Buffer.from(JSON.stringify(stored)).toString("hex")}>`;
    expect(args.slice(0, 4)).toEqual(["write", "fixture", "providerOrder", "-data"]);
    if (fail) throw new Error("Fixture save failed");
    stored = JSON.parse(Buffer.from(args[4], "hex").toString()); return "";
  };
  const prefs = await Preferences.load(launch, command, "fixture"); fail = true;
  await expect(prefs.set("providerOrder", order)).rejects.toThrow("Fixture save failed"); expect(prefs.providerOrder).toEqual(providers);
  fail = false; await prefs.set("providerOrder", order); expect((await Preferences.load(launch, command, "fixture")).providerOrder).toEqual(order);
});
it("orders every snapshot display while retaining account and Collect/Show independence", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-order-slots-")), launch = { home: root, data: root, demo: true, candidate: true, env: {} };
  try {
    const prefs = await Preferences.load(launch);
    prefs.values.managedAccounts = [{ id: "work", provider: "codex", label: "Work", path: root, enabled: true }, { id: "disabled", provider: "claude", label: "Off", path: root, enabled: false }];
    const slots = [...providers.map(primary), { ...primary("codex"), slotID: "work", label: "Work" }, { ...primary("claude"), slotID: "disabled" }];
    const c = new Coordinator(launch, prefs, slots.map(slot => ({ slot })), () => 1000);
    await prefs.set("providerOrder", order);
    let s = c.snapshot(); expect(s.slots.map(slotKey)).toEqual(["claude", "codex", "codex#work", ...providers.filter(p => p !== "claude" && p !== "codex")]);
    for (const slot of s.slots) c.quotas[slotKey(slot)] = value(quota(slot.provider, [window(slot.provider === "openCodeGo" ? "Rolling" : "5-hour", 10)], 1000));
    s = c.snapshot(); expect(s.notchSlots).toEqual(s.slots); expect(s.traySlots.map(slotKey)).toEqual(s.slots.filter(s => s.provider !== "openRouter").map(slotKey));
    expect(notchEntries(s).map(e => e.key)).toEqual(s.notchSlots.map(slotKey)); expect(trayTooltip(s).indexOf("Claude:")).toBeLessThan(trayTooltip(s).indexOf("Codex:"));
    await prefs.set("menuBarProviderClaude", false); await prefs.set("showProviderCodex", false);
    s = c.snapshot(); expect(s.slots.map(slotKey)).toContain("codex#work"); expect(s.slots.map(slotKey)).not.toContain("codex"); expect(s.notchSlots.map(slotKey)).not.toContain("claude");
    expect(prefs.providerOrder).toEqual(order); c.stop();
  } finally { rmSync(root, { recursive: true, force: true }); }
});
it("applies saved ordering in the synthetic preview caller", async () => {
  const bridge = await previewBridge();
  const initial = await bridge.request({ action: "state" });
  if (!initial.ok || !initial.state) throw new Error("Missing preview state");
  expect(initial.state.snapshot.slots[0].provider).toBe("codex");
  expect(initial.state.snapshot.slots[1].provider).toBe("codex");
  expect((await bridge.request({ action: "providerOrder", order })).ok).toBe(true);
  const reply = await bridge.request({ action: "state" });
  if (!reply.ok || !reply.state) throw new Error("Missing preview state");
  expect(reply.state.settings.providerOrder).toEqual(order); expect(reply.state.snapshot.slots[0].provider).toBe("claude");
});
