import { describe, it, expect, afterEach, vi } from "vite-plus/test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, readFileSync, symlinkSync, utimesSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { launchConfiguration, type Launch } from "../src/main/launch";
import { Preferences, defaultsDomain } from "../src/main/preferences";
import { compose, accountHome } from "../src/main/composition";
import { jsonReport, runJSON } from "../src/main/cli";
import { endpoints, type Command } from "../src/main/providers/transport";
const roots: string[] = []; const temp = () => { const root = mkdtempSync(join(tmpdir(), "meterusage-fixture-")); roots.push(root); return root; };
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const now = Date.parse("2026-10-06T12:00:00Z");
const liveFixture = (home: string): Launch => ({ home, data: join(home, "app-data"), env: {}, demo: false, candidate: false });
describe("candidate isolation before composition", () => {
  it("rejects incomplete, relative, installed and nonempty profiles", () => {
    const root = temp();
    expect(() => launchConfiguration(["--candidate-profile", root], {}, root)).toThrow("requires");
    expect(() => launchConfiguration(["--demo", "--candidate-profile", "relative"], {}, root)).toThrow("absolute");
    expect(() => launchConfiguration(["--demo", "--candidate-profile", join(root, "Library/Application Support/MeterUsage")], {}, root)).toThrow("installed");
    writeFileSync(join(root, "foreign.txt"), "preserved"); expect(() => launchConfiguration(["--demo", "--candidate-profile", root], {}, "/invented/home")).toThrow("empty"); expect(readFileSync(join(root, "foreign.txt"), "utf8")).toBe("preserved");
    const alias = join(temp(), "alias"); symlinkSync(root, alias); expect(() => launchConfiguration(["--demo", "--candidate-profile", alias], {}, "/invented/home")).toThrow("symlink");
  });
  it("uses only synthetic transports and profile state even with hostile live environment", async () => {
    const root = temp(), launch = launchConfiguration(["--demo", "--candidate-profile", root], { OPENROUTER_API_KEY: "never-read", HOME: "/invented/home", CODEX_HOME: "/invented/account" });
    const forbidden: Command = async () => { throw new Error("Live command invoked"); };
    const preferences = await Preferences.load(launch, forbidden), sources = compose(launch, preferences, { now: () => now, command: forbidden, http: async () => { throw new Error("Live HTTP invoked"); } });
    const report = await jsonReport(sources, now); expect(report.providers).toHaveLength(8); expect(report.providers.every(p => p.status === "ok")).toBe(true);
    expect(launch.env).toEqual({}); expect(launch.home).toBe(root); await preferences.set("appearanceTheme", "dark"); expect((await Preferences.load(launch, forbidden)).values.appearanceTheme).toBe("dark");
    expect(JSON.stringify(report)).not.toMatch(/never-read|invented\/home/); expect(existsSync(join(root, "quota-archive.json"))).toBe(false);
  });
  it("returns headless schema1 including explicit --force and --json compatibility", async () => {
    const root = temp(); const r = JSON.parse(await runJSON(["--json", "--force", "--demo", "--candidate-profile", root], {}));
    expect(r.schema).toBe(1); expect(r.providers.map((p: { provider: string }) => p.provider)).toEqual(["claude", "claude", "codex", "codex", "openRouter", "openCodeGo", "grok", "antigravity"]);
    expect(r.providers[1].account).toBe("Second account"); expect(r.providers[2].credits.balance).toBe(41.6);
  });
});
describe("typed preferences and managed accounts", () => {
  it("serializes overlapping writes and applies account changes to the latest saved list", async () => {
    let release!: () => void, writes = 0;
    const stored: string[][] = [], gate = new Promise<void>(resolve => { release = resolve; });
    const command: Command = async (_binary, args) => {
      if (args[0] !== "write") throw new Error("absent fixture");
      writes++; if (writes === 1) await gate; stored.push(args); return "";
    };
    const prefs = await Preferences.load(liveFixture(temp()), command, "dev.meterusage.fixture");
    const a = { id: "stable-id", provider: "codex" as const, label: "Work", path: "~/fixture", enabled: true };
    const first = prefs.set("managedAccounts", [a]);
    const rename = prefs.updateAccounts(accounts => accounts.map(a => ({ ...a, label: "Renamed" })));
    const disable = prefs.updateAccounts(accounts => accounts.map(a => ({ ...a, enabled: false })));
    await Promise.resolve(); expect(writes).toBe(1); release(); await Promise.all([first, rename, disable]);
    expect(prefs.accounts).toEqual([{ ...a, label: "Renamed", enabled: false }]);
    expect(JSON.parse(Buffer.from(stored[2][4], "hex").toString())).toEqual(prefs.accounts);
    await expect(prefs.set("invalid", true)).rejects.toThrow(); await prefs.set("appearanceTheme", "dark"); expect(prefs.values.appearanceTheme).toBe("dark");
  });
  it("reads Data, Date, booleans and coordinates and writes the same types", async () => {
    const root = temp(), accounts = [{ id: "synthetic-id", provider: "claude", label: "Work", path: "~/alternate", enabled: false }];
    const stored: Record<string, { type: string; value: string }> = { managedAccounts: { type: "data", value: `<${Buffer.from(JSON.stringify(accounts)).toString("hex")}>` }, updateLastCheckDate: { type: "date", value: "2026-10-06 12:00:00 +0000" }, sideNotchPanelCorner: { type: "string", value: "1440,800" }, showProviderCodex: { type: "boolean", value: "0" }, refreshIntervalSeconds: { type: "float", value: "10" } };
    const writes: string[][] = [], command: Command = async (binary, args) => {
      expect(binary).toBe("/usr/bin/defaults"); expect(args[1]).toBe("dev.meterusage.fixture");
      if (args[0] === "write") { writes.push(args); return ""; }
      const value = stored[args[2]]; if (!value) throw new Error("absent"); return args[0] === "read-type" ? `Type is ${value.type}` : value.value;
    };
    const prefs = await Preferences.load(liveFixture(root), command, "dev.meterusage.fixture");
    expect(defaultsDomain).toBe("dev.meterusage.app"); expect(prefs.accounts).toEqual(accounts); expect(prefs.values.updateLastCheckDate).toBe(now); expect(prefs.enabled("codex")).toBe(false); expect(prefs.refreshInterval).toBe(30); expect(prefs.values.sideNotchPanelCorner).toBe("1440,800");
    await prefs.set("managedAccounts", accounts); await prefs.set("updateLastCheckDate", now); await prefs.set("showProviderCodex", true);
    expect(writes.map(a => a[3])).toEqual(["-data", "-date", "-bool"]); expect(JSON.parse(Buffer.from(writes[0][4], "hex").toString())).toEqual(accounts);
    await expect(prefs.set("unknownKey", true)).rejects.toThrow("Invalid"); await expect(prefs.set("managedAccounts", [...accounts, ...accounts])).rejects.toThrow("Invalid");
  });
  it("preserves account identity on rename/disable and removes only preferences", async () => {
    const root = temp(), provider = join(temp(), "account"); mkdirSync(provider); writeFileSync(join(provider, "provider-data"), "preserved");
    const launch = launchConfiguration(["--demo", "--candidate-profile", root], {}), prefs = await Preferences.load(launch);
    const a = { id: "stable-id", provider: "codex" as const, label: "Work", path: provider, enabled: true };
    await prefs.set("managedAccounts", [a]); await prefs.set("managedAccounts", [{ ...a, label: "Renamed", enabled: false }]); expect((await Preferences.load(launch)).accounts[0].id).toBe("stable-id");
    await prefs.set("managedAccounts", []); expect(readFileSync(join(provider, "provider-data"), "utf8")).toBe("preserved");
  });
});
describe("provider path and transport composition", () => {
  it("prioritizes the primary Claude app-support companion without alternate-account fallback", async () => {
    const root = temp(), alt = join(root, "alternate"), dir = join(root, "Library/Application Support/MeterUsage");
    mkdirSync(alt); mkdirSync(dir, { recursive: true }); mkdirSync(join(root, ".claude"));
    const companion = join(dir, "claude-usage.json");
    writeFileSync(companion, '{"five_hour":{"used_percentage":25}}');
    writeFileSync(join(root, ".claude/claudewatch-usage.json"), '{"five_hour":{"used_percentage":75}}');
    writeFileSync(join(alt, "meterusage-usage.json"), '{"five_hour":{"used_percentage":10}}');
    const launch = launchConfiguration([], {}, root), prefs = await Preferences.load(launch, async () => { throw new Error("absent"); });
    prefs.values.managedAccounts = [{ id: "alternate", provider: "claude", label: "Alternate", path: alt, enabled: true }];
    const sources = compose(launch, prefs, { now: () => now });
    const primary = sources.find(s => s.slot.provider === "claude" && !s.slot.slotID)!;
    expect((await primary.quota!()).windows[0].usedPercent).toBe(25);
    expect((await sources.find(s => s.slot.slotID === "alternate")!.quota!()).windows[0].usedPercent).toBe(10);
    writeFileSync(companion, 'invalid'); await expect(primary.quota!()).rejects.toThrow("No usage");
  });
  it("keeps Claude file capture age across polls and prefers explicit updated_at", async () => {
    const root = temp(), path = join(root, ".claude/meterusage-usage.json"), old = now - 86400000;
    mkdirSync(join(root, ".claude")); writeFileSync(path, '{"five_hour":{"used_percentage":0}}'); utimesSync(path, old / 1000, old / 1000);
    let clock = now; const prefs = await Preferences.load(liveFixture(root), async () => { throw new Error("absent"); });
    const source = compose(liveFixture(root), prefs, { now: () => clock }).find(s => s.slot.provider === "claude")!;
    expect((await source.quota!()).capturedAt).toBe(old); clock += 60000; expect((await source.quota!()).capturedAt).toBe(old);
    writeFileSync(path, JSON.stringify({ five_hour: { used_percentage: 0 }, updated_at: (old + 1000) / 1000 }));
    expect((await source.quota!()).capturedAt).toBe(old + 1000);
  });
  it.each([0, 29000])("preserves required OpenRouter quota when optional credits stall (key delay %sms)", async keyDelay => {
    const root = temp(), launch = { ...liveFixture(root), env: { OPENROUTER_API_KEY: "synthetic-key" } };
    const prefs = await Preferences.load(launch, async () => { throw new Error("absent"); }); let cancelled = false;
    const source = compose(launch, prefs, { now: () => now, http: async (url, _p, _key, signal) => {
      if (url === endpoints.openRouterCredits) { signal?.addEventListener("abort", () => { cancelled = true; }); return new Promise<string>(() => {}); }
      await new Promise(resolve => setTimeout(resolve, keyDelay)); return '{"data":{"usage":0,"limit":100}}';
    } }).find(s => s.slot.provider === "openRouter")!;
    vi.useFakeTimers();
    try {
      const report = jsonReport([source], now); await vi.advanceTimersByTimeAsync(30000);
      const provider = (await report).providers[0]; expect(provider.status).toBe("ok"); expect(provider.windows[0].used_percent).toBe(0); expect(cancelled).toBe(true);
    } finally { vi.useRealTimers(); }
  });
  it("has all nine primary providers and never falls back from alternate Claude plan/quota", async () => {
    const root = temp(), alt = join(root, "alternate"); mkdirSync(alt); mkdirSync(join(root, ".claude")); writeFileSync(join(root, ".claude.json"), '{"oauthAccount":{"seatTier":"pro"}}'); writeFileSync(join(root, ".claude", "meterusage-usage.json"), '{"five_hour":{"used_percentage":75}}');
    const prefs = await Preferences.load(liveFixture(root), async () => { throw new Error("absent"); }); prefs.values.managedAccounts = [{ id: "alternate", provider: "claude", label: "Alternate", path: alt, enabled: true }];
    const sources = compose(liveFixture(root), prefs, { now: () => now }); expect(sources.filter(s => !s.slot.slotID)).toHaveLength(9);
    const alternate = sources.find(s => s.slot.slotID === "alternate")!; await expect(alternate.plan!()).rejects.toThrow("No usage"); await expect(alternate.quota!()).rejects.toThrow("No usage");
    const primary = sources.find(s => s.slot.provider === "claude" && !s.slot.slotID)!; expect(await primary.plan!()).toBe("Pro"); expect((await primary.quota!()).windows[0].usedPercent).toBe(75);
    expect(accountHome({ id: "a", provider: "claude", label: "A", path: "~/alternate", enabled: true }, root)).toBe(alt);
  });
  it("re-reads rotated Grok tokens each refresh and tolerates optional OpenRouter credit failure", async () => {
    const root = temp(); mkdirSync(join(root, ".grok")); mkdirSync(join(root, ".openrouter")); const path = join(root, ".grok/auth.json");
    writeFileSync(path, '{"https://auth.x.ai":{"key":"fixture-first"}}'); writeFileSync(join(root, ".openrouter/api-key"), "fixture-openrouter");
    const keys: string[] = [], prefs = await Preferences.load(liveFixture(root), async () => { throw new Error("absent"); });
    const sources = compose(liveFixture(root), prefs, { now: () => now, http: async (url, _provider, key) => {
      if (url === endpoints.openRouterCredits) throw new Error("optional unavailable");
      if (url === endpoints.openRouterKey) return '{"data":{"usage":0,"limit":100}}';
      keys.push(key!); return '{"config":{"creditUsagePercent":0,"billingPeriodEnd":"2030-01-01T00:00:00Z"}}';
    } });
    const grok = sources.find(s => s.slot.provider === "grok")!; await grok.quota!(); writeFileSync(path, '{"https://auth.x.ai":{"key":"fixture-second"}}'); await grok.quota!(); expect(keys).toEqual(["fixture-first", "fixture-second"]);
    expect((await sources.find(s => s.slot.provider === "openRouter")!.quota!()).windows[0].usedPercent).toBe(0);
  });
});
