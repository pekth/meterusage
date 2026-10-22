import { afterEach, expect, it, vi } from "vite-plus/test";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { isValidElement, type ReactNode } from "react";
import { DesktopConnections } from "../src/main/connections";
import { compose } from "../src/main/composition";
import { Coordinator } from "../src/main/coordinator";
import { Preferences } from "../src/main/preferences";
import { launchConfiguration } from "../src/main/launch";
import { parseRequest } from "../src/main/ipc";
import { ProviderCard } from "../src/renderer/app";
import type { Request, ViewState } from "../src/shared/ipc";
import * as transport from "../src/main/providers/transport";

vi.mock("node:fs", async original => ({ ...await original<typeof import("node:fs")>(), accessSync: () => { throw new Error("No native discovery in synthetic reset tests"); } }));
const roots: string[] = [], coordinators: Coordinator[] = [];
const profile = "11111111-1111-4111-8111-111111111111", other = "22222222-2222-4222-8222-222222222222";
const at = Date.parse("2026-10-10T12:00:00Z");
const allowance = (status = "available", expiresAt = at + 3600000, used = 80) => JSON.stringify({ result: {
  rateLimits: { primary: { usedPercent: used, windowDurationMins: 300 } },
  rateLimitResetCredits: { availableCount: status === "available" ? 1 : 0, credits: [{ id: "fixture-credit", title: "Full reset", status, expiresAt }] },
} });
async function setup(codexTest = false) {
  const root = mkdtempSync(join(tmpdir(), "meterusage-reset-fixture-")); roots.push(root);
  const launch = launchConfiguration(codexTest ? ["--codex-test-profile", join(root, "profile")] : [], { PATH: root, TMPDIR: root }, root);
  const prefs = await Preferences.load(launch, async () => ""); prefs.values.desktopCodexConnection = profile;
  vi.spyOn(transport, "cliPath").mockReturnValue("/synthetic/codex");
  let now = at;
  const connections = new DesktopConnections(launch, prefs, "/synthetic/unused", () => {}, async () => { throw new Error("Native command forbidden"); }, async () => { throw new Error("HTTP forbidden"); }, () => ++now);
  const sources = () => compose(launch, prefs, { connections }).filter(s => s.slot.provider === "codex"), source = sources()[0];
  const coordinator = new Coordinator(launch, prefs, [source], () => ++now, () => {}, sources); coordinators.push(coordinator);
  const rpc = vi.spyOn(transport, "codexRPC").mockResolvedValue(allowance());
  return { launch, prefs, connections, source, coordinator, rpc };
}
afterEach(() => { for (const c of coordinators.splice(0)) c.stop(); vi.restoreAllMocks(); for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
function resetButton(node: ReactNode): { onClick: () => void } | undefined {
  if (Array.isArray(node)) return node.map(resetButton).find(Boolean);
  if (!isValidElement<{ children?: ReactNode; onClick: () => void }>(node)) return;
  return node.type === "button" && node.props.children === "Use reset" ? node.props : resetButton(node.props.children);
}

it.each([false, true])("routes the connected menu button through validated intent, cancel and one synthetic consume (codexTest=%s)", async codexTest => {
  const { coordinator: c, source, rpc, launch } = await setup(codexTest);
  expect(source.consumeReset).toBeTypeOf("function"); expect(source.activity).toBeUndefined();
  await c.refresh(); expect(c.snapshot().quotas.codex).toMatchObject({ status: "value", value: { canConsumeReset: true } });
  const view: ViewState = { snapshot: c.snapshot(), settings: { values: {}, accounts: [] }, systemDark: true, notch: { expanded: false, cardOnRight: false, selected: "codex", dragging: false } };
  let request!: Request;
  const button = resetButton(ProviderCard({ slot: source.slot, state: view, action: async raw => { request = parseRequest(raw); } }));
  expect(button).toBeDefined(); button!.onClick();
  expect(request).toEqual({ action: "reset", key: "codex", creditID: "fixture-credit" });
  if (request.action !== "reset") throw new Error("Expected reset request");
  const cancelled = c.prepareReset(request.key, request.creditID); c.cancelReset(cancelled.token);
  await expect(c.confirmReset(cancelled.token)).rejects.toThrow("expired");
  expect(rpc.mock.calls.filter(([, , credit]) => credit !== undefined)).toHaveLength(0);
  rpc.mockImplementation(async (_binary, options, credit, configuration) => {
    expect(options.env).toEqual({ HOME: launch.home, PATH: transport.cliEnvironment(launch.home, { PATH: launch.env.PATH }).PATH, CODEX_HOME: join(launch.data, "connections/codex", profile), TMPDIR: launch.env.TMPDIR });
    expect(configuration).toContain('cli_auth_credentials_store="keyring"');
    return credit ? '{"result":{"outcome":"reset"}}' : allowance("available", at + 3600000, rpc.mock.calls.some(([, , id]) => id !== undefined) ? 0 : 80);
  });
  const confirmed = c.prepareReset(request.key, request.creditID); await c.confirmReset(confirmed.token);
  await expect(c.confirmReset(confirmed.token)).rejects.toThrow("expired");
  expect(rpc.mock.calls.filter(([, , credit]) => credit !== undefined)).toHaveLength(1);
  expect(c.quotas.codex).toMatchObject({ status: "value", value: { windows: [{ usedPercent: 0 }] } });
  expect(c.archived.codex.resetPacingSince).toBeGreaterThan(at);
});

it.each(["consumed", "revoked", "expired", "absent", "offline"])("rechecks %s credits after confirmation without consuming", async state => {
  const { coordinator: c, rpc } = await setup(); await c.refresh();
  const intent = c.prepareReset("codex", "fixture-credit");
  if (state === "offline") rpc.mockRejectedValue(new Error("Synthetic network failure"));
  else rpc.mockResolvedValue(state === "absent" ? '{"result":{"rateLimits":{},"rateLimitResetCredits":{"availableCount":0,"credits":[]}}}' : allowance(state === "expired" ? "available" : state, state === "expired" ? at : at + 3600000));
  await expect(c.confirmReset(intent.token)).rejects.toThrow("Couldn't redeem");
  expect(rpc.mock.calls.filter(([, , credit]) => credit !== undefined)).toHaveLength(0);
});

it.each(["off", other])("rejects a profile changed to %s while native confirmation is open", async next => {
  const { coordinator: c, prefs, rpc } = await setup(); await c.refresh();
  const intent = c.prepareReset("codex", "fixture-credit"), calls = rpc.mock.calls.length;
  prefs.values.desktopCodexConnection = next;
  await expect(c.confirmReset(intent.token)).rejects.toThrow();
  expect(rpc).toHaveBeenCalledTimes(calls);
});

it.each(["disconnect", "change", "stop"])("rejects %s during fresh eligibility and never dispatches consume", async action => {
  const { coordinator: c, prefs, connections, rpc } = await setup(); await c.refresh();
  let release!: (raw: string) => void, signal!: AbortSignal;
  rpc.mockImplementation((_binary, options, _credit, _configuration, operation) => operation === "logout" ? Promise.resolve('{"result":{}}') : new Promise(resolve => { release = resolve; signal = options.signal!; }));
  const pending = c.confirmReset(c.prepareReset("codex", "fixture-credit").token);
  if (action === "disconnect") await connections.disconnect("codex");
  else if (action === "stop") await connections.stop();
  else prefs.values.desktopCodexConnection = other;
  if (action !== "change") expect(signal.aborted).toBe(true);
  release(allowance()); await expect(pending).rejects.toThrow();
  expect(rpc.mock.calls.filter(([, , credit]) => credit !== undefined)).toHaveLength(0);
});

it.each(["replace", "clear cache", "stop"])("cancels coordinator %s during eligibility without dispatching consume", async action => {
  const { coordinator: c, source, launch, prefs, connections, rpc } = await setup(); await c.refresh();
  let release!: (raw: string) => void, signal!: AbortSignal;
  rpc.mockImplementation(async (_binary, _options, credit) => credit ? '{"result":{"outcome":"reset"}}' : allowance());
  rpc.mockImplementationOnce((_binary, options) => new Promise(resolve => { release = resolve; signal = options.signal!; }));
  const pending = c.confirmReset(c.prepareReset("codex", "fixture-credit").token).then(() => "accepted", () => "rejected");
  try {
    if (action === "stop") c.stop();
    else if (action === "clear cache") await c.clearCache();
    else { c.sources = compose(launch, prefs, { connections }).filter(s => s.slot.provider === "codex"); await c.refresh(); }
  } finally { release(allowance()); }
  const result = await pending;
  expect(rpc.mock.calls.filter(([, , credit]) => credit !== undefined)).toHaveLength(0);
  expect(signal.aborted).toBe(true); expect(result).toBe("rejected");
  expect(prefs.values.desktopCodexConnection).toBe(profile); expect(connections.enabled("codex")).toBe(true);
  if (action !== "stop") expect(c.sources).not.toContain(source);
  expect(c.archived.codex.resetPacingSince).toBeUndefined();
});

it.each(["replace", "stop"])("keeps the late result guard after coordinator %s even when a source ignores abort", async action => {
  const { coordinator: c, source, rpc } = await setup(); await c.refresh();
  let complete!: (result: boolean) => void, signal!: AbortSignal;
  source.consumeReset = async (_credit, cancellation) => { signal = cancellation!; return new Promise(resolve => { complete = resolve; }); };
  const pending = c.confirmReset(c.prepareReset("codex", "fixture-credit").token);
  if (action === "stop") c.stop(); else { c.sources = [{ ...source }]; await c.refresh(); }
  const quota = c.quotas.codex, archive = c.archived.codex, calls = rpc.mock.calls.length;
  complete(true); await expect(pending).rejects.toThrow("Couldn't redeem Codex reset");
  expect(signal.aborted).toBe(true); expect(c.quotas.codex).toBe(quota); expect(c.archived.codex).toBe(archive);
  expect(c.archived.codex.resetPacingSince).toBeUndefined(); expect(rpc).toHaveBeenCalledTimes(calls);
});

it("blocks overlapping confirmed resets and ignores completion after disconnect", async () => {
  const { coordinator: c, connections, rpc } = await setup(); await c.refresh();
  let complete!: (raw: string) => void, signal!: AbortSignal;
  rpc.mockImplementation((_binary, options, credit) => credit ? new Promise(resolve => { complete = resolve; signal = options.signal!; }) : Promise.resolve(allowance()));
  const pending = c.confirmReset(c.prepareReset("codex", "fixture-credit").token);
  await vi.waitFor(() => expect(complete).toBeTypeOf("function"));
  await expect(connections.consumeReset(profile, "fixture-credit")).rejects.toThrow();
  const duplicate = c.prepareReset("codex", "fixture-credit"); await expect(c.confirmReset(duplicate.token)).rejects.toThrow();
  await connections.disconnect("codex"); expect(signal.aborted).toBe(true);
  complete('{"result":{"outcome":"reset"}}'); await expect(pending).rejects.toThrow();
  expect(rpc.mock.calls.filter(([, , credit]) => credit !== undefined)).toHaveLength(1);
  expect(c.archived.codex.resetPacingSince).toBeUndefined();
});

it.each(['{"result":{"outcome":"unavailable"}}', '{"result":{}}', '{"error":{"code":-1,"message":"OMIT_PROVIDER_DETAIL"}}'])("requires explicit reset success and keeps provider errors private: %s", async result => {
  const { coordinator: c, rpc } = await setup(); await c.refresh();
  rpc.mockImplementation(async (_binary, _options, credit) => credit ? result : allowance());
  await expect(c.confirmReset(c.prepareReset("codex", "fixture-credit").token)).rejects.toThrow("Couldn't redeem Codex reset");
  expect(c.archived.codex.resetPacingSince).toBeUndefined();
});
