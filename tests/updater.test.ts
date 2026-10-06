import { describe, it, expect, afterEach } from "vite-plus/test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync, realpathSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { Updater, parseRelease, newer, verifyDigest, stageUpdate, releaseEndpoint } from "../src/main/updater";
import { launchConfiguration } from "../src/main/launch";
import { Preferences } from "../src/main/preferences";
const bytes = Buffer.from("synthetic update bytes"), digest = "sha256:" + createHash("sha256").update(bytes).digest("hex");
const payload = (url = "https://github.com/pekth/meterusage/releases/download/v0.2.42/MeterUsage-0.2.42.zip", hash = digest) => JSON.stringify({ tag_name: "v0.2.42", assets: [{ name: "MeterUsage-0.2.42.zip", browser_download_url: url, digest: hash }] });
const roots: string[] = []; const temp = () => { const p = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-fixture-")); roots.push(p); return p; };
afterEach(() => roots.splice(0).forEach(p => rmSync(p, { recursive: true, force: true })));
describe("verified explicit updates", () => {
  it("accepts the existing ZIP contract and rejects wrong repository, missing digest and changed bytes", () => {
    expect(newer("0.10.0", "0.9.9")).toBe(true); expect(newer("garbage", "0.2.41")).toBe(false);
    expect(parseRelease(payload()).version).toBe("0.2.42");
    expect(() => parseRelease(payload("https://example.invalid/app.zip"))).toThrow();
    expect(() => parseRelease(payload(undefined, ""))).toThrow();
    expect(() => verifyDigest(bytes, digest)).not.toThrow(); expect(() => verifyDigest(Buffer.from("tampered"), digest)).toThrow();
  });
  it("never contacts release servers or installs from a demo candidate", async () => {
    const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
    let calls = 0; const updater = new Updater(prefs, "0.2.41", () => {}, async () => { calls++; return bytes; });
    await updater.checkIfDue(); updater.available = parseRelease(payload()); await expect(updater.install("/tmp/MeterUsage.app", updater.visible)).rejects.toThrow("unavailable"); expect(calls).toBe(0);
  });
  it("checks hourly, announces once and persists dismissal separately from usage failures", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture defaults"); return ""; }, "fixture.meterusage");
    let calls = 0, announcements = 0; const updater = new Updater(prefs, "0.2.41", () => {}, async url => { expect(url).toBe(releaseEndpoint); calls++; return Buffer.from(payload()); }, () => announcements++);
    const now = Date.parse("2026-10-06T12:00:00Z");
    await updater.checkIfDue(now); await updater.checkIfDue(now + 1000); expect(calls).toBe(1); expect(announcements).toBe(1); expect(updater.visible?.version).toBe("0.2.42");
    await updater.dismiss(); expect(updater.visible).toBeUndefined(); await updater.checkIfDue(now + 3600000); expect(calls).toBe(2); expect(announcements).toBe(1);
    await prefs.set("updateCheckEnabled", false); updater.reset(); await updater.checkIfDue(now + 7200000); expect(calls).toBe(2); expect(updater.available).toBeUndefined();
  });
  it("cannot restore an old check or announcement after update checks are disabled", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture"); return ""; }, "fixture.meterusage");
    let respond!: (data: Buffer) => void, signal: AbortSignal | undefined, announcements = 0;
    const updater = new Updater(prefs, "0.2.41", () => {}, async (_url, _max, activeSignal) => { signal = activeSignal; return new Promise<Buffer>(resolve => { respond = resolve; }); }, () => announcements++);
    const check = updater.checkIfDue(Date.parse("2026-10-06T12:00:00Z"));
    // Wait for the injected download to start, rather than assuming the
    // serialized preference write takes a particular number of microtasks.
    await new Promise<void>(resolve => setImmediate(resolve));
    await prefs.set("updateCheckEnabled", false); updater.reset(); expect(signal?.aborted).toBe(true);
    respond(Buffer.from(payload())); await check; expect(updater.available).toBeUndefined(); expect(announcements).toBe(0);
  });
  it("stages only a matching signed bundle and aborts before extraction on invalid bytes or traversal", async () => {
    const archive = readFileSync("tests/fixtures/update-safe.zip"), release = parseRelease(payload(undefined, "sha256:" + createHash("sha256").update(archive).digest("hex"))); let calls = 0, stagedRoot: string | undefined, wrongVersion = false;
    const command = async (binary: string, args: string[]) => {
      calls++;
            if (binary.endsWith("ditto")) { stagedRoot = args[3]; const bundle = join(args[3], "MeterUsage.app/Contents"); roots.push(args[3]); mkdirSync(bundle, { recursive: true }); writeFileSync(join(bundle, "Info.plist"), "synthetic"); return ""; }
      if (binary.endsWith("PlistBuddy")) return args[1].endsWith("CFBundleIdentifier") ? "dev.meterusage.app" : args[1].endsWith("CFBundleExecutable") ? "meterusage" : wrongVersion ? "0.2.40" : release.version;
      if (binary.endsWith("codesign")) return "";
      throw new Error("unexpected fixture command");
    };
    await expect(stageUpdate(release, Buffer.from("changed"), command)).rejects.toThrow("digest"); expect(calls).toBe(0);
    const bundle = await stageUpdate(release, archive, command); expect(bundle).toContain("MeterUsage.app"); expect(calls).toBe(5);
    wrongVersion = true; await expect(stageUpdate(release, archive, command)).rejects.toThrow("bundle"); expect(existsSync(stagedRoot!)).toBe(false);
    for (const kind of ["outside-link", "through-link", "traversal"]) {
      const bad = readFileSync(`tests/fixtures/update-${kind}.zip`), r = { ...release, asset: { ...release.asset, digest: "sha256:" + createHash("sha256").update(bad).digest("hex") } };
      let extracted = false;
      await expect(stageUpdate(r, bad, async () => { extracted = true; return ""; })).rejects.toThrow("archive");
      expect(extracted).toBe(false);
    }
  });
  it("downloads the confirmed release and aborts before staging after disabling updates", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("fixture absent"); return ""; }, "fixture.meterusage");
    let respond!: (bytes: Buffer) => void, requested = "", signal: AbortSignal | undefined, staged = false;
    const updater = new Updater(prefs, "0.2.41", () => {}, async (url, _max, s) => { requested = url; signal = s; return new Promise<Buffer>(resolve => { respond = resolve; }); });
    const confirmed = parseRelease(payload()); updater.available = { ...confirmed, version: "0.2.43", asset: { ...confirmed.asset, url: "https://github.com/pekth/meterusage/releases/download/v0.2.43/MeterUsage-0.2.43.zip" } };
    const installing = updater.install("/tmp/MeterUsage.app", confirmed, async () => { staged = true; return ""; });
    const rejected = expect(installing).rejects.toThrow("Could not install");
    expect(requested).toBe(confirmed.asset.url);
    await prefs.set("updateCheckEnabled", false); updater.reset(); expect(signal?.aborted).toBe(true);
    respond(bytes); await rejected; expect(staged).toBe(false); expect(updater.installState).toBe("failed");
  });

});
