import { describe, it, expect, afterEach, vi } from "vite-plus/test";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, existsSync, readFileSync, symlinkSync, utimesSync, realpathSync, readlinkSync, unlinkSync, chmodSync } from "node:fs";
import { tmpdir, hostname } from "node:os";
import { createServer } from "node:net";
import { join } from "node:path";
import { launchConfiguration, type Launch } from "../src/main/launch";
import { Preferences, defaultsDomain } from "../src/main/preferences";
import { compose, accountHome } from "../src/main/composition";
import { jsonReport, runJSON } from "../src/main/cli";
import { endpoints, type Command } from "../src/main/providers/transport";
import { providers, quota, Unavailable } from "../src/domain/models";
import { DesktopConnections } from "../src/main/connections";
const roots: string[] = []; const temp = () => { const root = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-fixture-")); roots.push(root); return root; };
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
const now = Date.parse("2026-10-06T12:00:00Z");
const liveFixture = (home: string): Launch => ({ home, data: join(home, "app-data"), env: {}, demo: false, candidate: false });
describe("Codex live test profile", () => {
  it("accepts only coherent Electron singleton metadata for GUI handoff, preserving every link", async () => {
    const root = temp(), home = temp(), socketDirectory = temp(), electron = join(root, "electron");
    const args = ["--codex-test-profile", root];
    launchConfiguration(args, {}, home);
    mkdirSync(electron);
    const socket = join(socketDirectory, "SingletonSocket"), cookie = "123456789";
    const server = createServer();
    await new Promise<void>(resolve => server.listen(socket, resolve));
    const links = new Map([
      [join(electron, "SingletonSocket"), socket],
      [join(electron, "SingletonCookie"), cookie],
      [join(electron, "SingletonLock"), `${hostname()}-${process.pid}`],
      [join(socketDirectory, "SingletonCookie"), cookie],
    ]);
    for (const [path, target] of links) symlinkSync(target, path);
    try {
      expect(() => launchConfiguration(args, {}, home)).toThrow("symlink");
      expect(launchConfiguration(args, {}, home, true).profile).toBe(root);
      for (const [path, target] of links) expect(readlinkSync(path)).toBe(target);
      for (const path of ["electron/Cache/link", "connections/link", "electron/Cache/SingletonSocket"]) {
        mkdirSync(join(root, path, ".."), { recursive: true }); symlinkSync(socketDirectory, join(root, path));
        expect(() => launchConfiguration(args, {}, home, true)).toThrow("symlink");
        unlinkSync(join(root, path));
      }
      for (const [path, target] of [
        [join(electron, "SingletonSocket"), join(socketDirectory, "absent")],
        [join(electron, "SingletonSocket"), socketDirectory],
        [join(electron, "SingletonSocket"), "/foreign/SingletonSocket"],
        [join(electron, "SingletonCookie"), "not-a-cookie"],
        [join(electron, "SingletonLock"), "foreign-host-123"],
        [join(electron, "SingletonLock"), `${hostname()}-../123`],
      ]) {
        unlinkSync(path); symlinkSync(target, path);
        expect(() => launchConfiguration(args, {}, home, true)).toThrow("singleton");
        expect(readlinkSync(path)).toBe(target);
        unlinkSync(path); symlinkSync(links.get(path)!, path);
      }
      const alias = join(temp(), "alias"); symlinkSync(socketDirectory, alias);
      unlinkSync(join(electron, "SingletonSocket")); symlinkSync(join(alias, "SingletonSocket"), join(electron, "SingletonSocket"));
      expect(() => launchConfiguration(args, {}, home, true)).toThrow("singleton");
      unlinkSync(join(electron, "SingletonSocket")); symlinkSync(socket, join(electron, "SingletonSocket"));
      chmodSync(socketDirectory, 0o755);
      expect(() => launchConfiguration(args, {}, home, true)).toThrow("singleton");
      chmodSync(socketDirectory, 0o700);
      unlinkSync(join(electron, "SingletonLock"));
      expect(() => launchConfiguration(args, {}, home, true)).toThrow("singleton");
      symlinkSync(links.get(join(electron, "SingletonLock"))!, join(electron, "SingletonLock"));
      unlinkSync(join(socketDirectory, "SingletonCookie")); symlinkSync("987654321", join(socketDirectory, "SingletonCookie"));
      expect(() => launchConfiguration(args, {}, home, true)).toThrow("singleton");
    } finally { await new Promise<void>(resolve => server.close(() => resolve())); }
  });
  it("isolates data while retaining OS home and only helper environment", () => {
    const root = temp(), home = temp();
    const launch = launchConfiguration(["--codex-test-profile", root], { HOME: "/foreign/home", CODEX_HOME: "/foreign/codex", OPENAI_API_KEY: "synthetic-secret", METERUSAGE_DEMO: "0", PATH: "/usr/bin:/bin", TMPDIR: "/tmp" }, home);
    expect(launch).toMatchObject({ codexTest: true, demo: false, candidate: true, home, data: root, profile: root });
    expect(launch.env).toEqual({ PATH: "/usr/bin:/bin", TMPDIR: "/tmp" });
    expect(launchConfiguration(["--codex-test-profile", root], {}, home).profile).toBe(root);
    expect(() => launchConfiguration(["--demo", "--candidate-profile", root], {}, home)).toThrow("empty");
  });
  it("rejects conflicting flags and invalid or foreign profile paths before mutation", () => {
    const home = temp(), root = temp();
    for (const [args, env] of [
      [["--demo", "--codex-test-profile", root], {}],
      [["--codex-test-profile", root], { METERUSAGE_DEMO: "1" }],
      [["--candidate-profile", root, "--codex-test-profile", root], {}],
    ] as [string[], NodeJS.ProcessEnv][]) expect(() => launchConfiguration(args, env, home)).toThrow("conflict");
    expect(existsSync(join(root, ".meterusage-codex-test"))).toBe(false);
    for (const path of [undefined, "relative"]) expect(() => launchConfiguration(["--codex-test-profile", ...(path ? [path] : [])], {}, home)).toThrow("absolute");
    for (const path of ["/", home, join(home, "Library/Application Support/MeterUsage"), join(home, "Library/Application Support/MeterUsage/nested")]) expect(() => launchConfiguration(["--codex-test-profile", path], {}, home)).toThrow("installed");
    expect(existsSync(join(home, "Library"))).toBe(false);
    writeFileSync(join(root, "foreign.txt"), "preserved");
    expect(() => launchConfiguration(["--codex-test-profile", root], {}, home)).toThrow("empty");
    expect(readFileSync(join(root, "foreign.txt"), "utf8")).toBe("preserved");
    const alias = join(temp(), "alias"); symlinkSync(root, alias);
    for (const path of [alias, join(alias, "nested")]) expect(() => launchConfiguration(["--codex-test-profile", path], {}, home)).toThrow("symlink");
    const demo = temp(); launchConfiguration(["--demo", "--candidate-profile", demo], {}, home);
    expect(() => launchConfiguration(["--codex-test-profile", demo], {}, home)).toThrow("empty");
  });
  it.each(["electron", "electron/Cache", "connections", "connections/codex/account", "preferences.json"])("rejects a nested profile symlink at %s without touching its target", path => {
    const root = temp(), home = temp(), foreign = temp();
    launchConfiguration(["--codex-test-profile", root], {}, home);
    writeFileSync(join(foreign, "sentinel"), "preserved");
    mkdirSync(join(root, path, ".."), { recursive: true });
    symlinkSync(foreign, join(root, path));
    expect(() => launchConfiguration(["--codex-test-profile", root], {}, home)).toThrow("symlink");
    expect(readFileSync(join(foreign, "sentinel"), "utf8")).toBe("preserved");
  });
  it("rejects dangling nested links and accepts regular populated profile directories", () => {
    const root = temp(), home = temp();
    launchConfiguration(["--codex-test-profile", root], {}, home);
    mkdirSync(join(root, "electron", "Cache"), { recursive: true });
    writeFileSync(join(root, "electron", "Cache", "entry"), "synthetic");
    expect(launchConfiguration(["--codex-test-profile", root], {}, home).profile).toBe(root);
    symlinkSync(join(temp(), "absent"), join(root, "connections"));
    expect(() => launchConfiguration(["--codex-test-profile", root], {}, home)).toThrow("symlink");
  });
  it("roundtrips JSON preferences without defaults and keeps collection restricted after reload", async () => {
    const root = temp(), home = temp(), launch = launchConfiguration(["--codex-test-profile", root], {}, home);
    const command = vi.fn<Command>(async () => { throw new Error("Installed defaults must not be used"); });
    const prefs = await Preferences.load(launch, command);
    expect(providers.filter(p => prefs.enabled(p))).toEqual(["codex"]);
    expect(prefs.values).toMatchObject({ desktopCodexConnection: "off", desktopCodexCleanup: "", desktopClaudeIdentity: "off", launchAtLogin: false, updateCheckEnabled: false });
    const id = "11111111-1111-4111-8111-111111111111";
    await prefs.set("appearanceTheme", "dark"); await prefs.set("desktopCodexConnection", id);
    const restored = await Preferences.load(launchConfiguration(["--codex-test-profile", root], {}, home), command);
    expect(restored.values).toMatchObject({ appearanceTheme: "dark", desktopCodexConnection: id });
    expect(JSON.parse(readFileSync(join(root, "preferences.json"), "utf8"))).toMatchObject({ appearanceTheme: "dark", desktopCodexConnection: id });
    for (const key of ["showProviderClaude", "showProviderGrok", "showProviderOpenRouter", "showProviderOpenCodeGo", "launchAtLogin", "updateCheckEnabled"]) await expect(restored.set(key, true)).rejects.toThrow("Codex test");
    writeFileSync(join(root, "preferences.json"), JSON.stringify({ ...restored.values, ...Object.fromEntries(providers.map(p => [`showProvider${p[0].toUpperCase() + p.slice(1)}`, true])), launchAtLogin: true, updateCheckEnabled: true, desktopClaudeIdentity: "a".repeat(64) }));
    const restricted = await Preferences.load(launch, command);
    expect(providers.filter(p => restricted.enabled(p))).toEqual(["codex"]);
    expect(restricted.values).toMatchObject({ launchAtLogin: false, updateCheckEnabled: false, desktopClaudeIdentity: "off", desktopCodexConnection: id });
    restricted.values.showProviderClaude = true; expect(restricted.enabled("claude")).toBe(false);
    await restricted.set("showProviderCodex", false); expect(restricted.enabled("codex")).toBe(false);
    expect(command).not.toHaveBeenCalled(); expect(existsSync(join(home, "Library"))).toBe(false);
  });
  it("composes only connected Codex quota and never falls back to local, demo or other providers", async () => {
    const launch = launchConfiguration(["--codex-test-profile", temp()], {}, temp());
    const command = vi.fn<Command>(async () => { throw new Error("Forbidden command"); });
    const http = vi.fn(async () => { throw new Error("Forbidden HTTP"); });
    const prefs = await Preferences.load(launch, command);
    prefs.values.managedAccounts = [{ id: "foreign-account", provider: "claude", label: "Foreign", path: temp(), enabled: true }];
    for (const p of providers) prefs.values[`showProvider${p[0].toUpperCase() + p.slice(1)}`] = true;
    const withoutConnection = compose(launch, prefs, { command, http });
    expect(withoutConnection).toHaveLength(1);
    expect(withoutConnection[0].slot).toEqual({ provider: "codex", slotID: "", label: "" });
    expect(Object.keys(withoutConnection[0]).sort()).toEqual(["accountBound", "quota", "slot"]);
    expect(withoutConnection[0].accountBound).toBe(true);
    await expect(withoutConnection[0].quota!()).rejects.toMatchObject({ code: "notSignedIn" });
    const connections = new DesktopConnections(launch, prefs, "/synthetic/helper", () => {}, command, http);
    const expected = quota("codex", [{ label: "5-hour", usedPercent: 37 }], now);
    const read = vi.spyOn(connections, "quota").mockResolvedValue(expected);
    const [source] = compose(launch, prefs, { connections, command, http });
    const signal = new AbortController().signal;
    expect(await source.quota!(signal)).toEqual(expected); expect(read).toHaveBeenCalledExactlyOnceWith("codex", signal);
    read.mockRejectedValue(new Unavailable("notSignedIn", "codex"));
    await expect(source.quota!()).rejects.toMatchObject({ code: "notSignedIn" });
    read.mockRejectedValue(new Unavailable("failed", "codex"));
    await expect(source.quota!()).rejects.toMatchObject({ code: "failed" });
    expect(command).not.toHaveBeenCalled(); expect(http).not.toHaveBeenCalled();
  });
});
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
