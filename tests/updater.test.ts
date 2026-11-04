import { describe, it, expect, afterEach, vi } from "vite-plus/test";
import { createHash } from "node:crypto";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync, existsSync, readFileSync, realpathSync, symlinkSync } from "node:fs";
import { join, dirname } from "node:path";
import { tmpdir } from "node:os";
import { Updater, fetchUpdate, parseRelease, parseReleases, newer, verifyDigest, stageUpdate, releaseEndpoint, releasesEndpoint } from "../src/main/updater";
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
  it("blocks updates from a live candidate even when its saved setting enables them", async () => {
    const root = temp();
    const prefs = await Preferences.load({ demo: true, candidate: true, home: root, data: root, env: {} });
    prefs.launch.demo = false;
    prefs.values.updateCheckEnabled = true;
    let calls = 0;
    const updater = new Updater(prefs, "0.2.41", () => {}, async () => { calls++; return Buffer.from(payload()); });
    await updater.checkIfDue();
    const release = parseRelease(payload()); updater.available = release;
    await expect(updater.install("/tmp/MeterUsage.app", release)).rejects.toThrow("unavailable");
    expect(updater.visible).toBeUndefined(); expect(calls).toBe(0);
  });
  it("checks hourly, announces once and persists dismissal separately from usage failures", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture defaults"); return ""; }, "fixture.meterusage");
    let calls = 0, announcements = 0; const updater = new Updater(prefs, "0.2.41", () => {}, async url => { expect(url).toBe(releaseEndpoint); calls++; return Buffer.from(payload()); }, () => announcements++);
    const now = Date.parse("2026-10-06T12:00:00Z");
    await updater.checkIfDue(now); await updater.checkIfDue(now + 1000); expect(calls).toBe(1); expect(announcements).toBe(1); expect(updater.visible?.version).toBe("0.2.42");
    await updater.dismiss(); expect(updater.visible).toBeUndefined(); await updater.checkIfDue(now + 3600000); expect(calls).toBe(2); expect(announcements).toBe(1);
    await prefs.set("updateCheckEnabled", false); updater.reset(); await updater.checkIfDue(now + 7200000); expect(calls).toBe(2); expect(updater.available).toBeUndefined();
  });
  it("checks now on request without the hourly limit or a notification, and reports failures", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture defaults"); return ""; }, "fixture.meterusage");
    let calls = 0, announcements = 0, response: () => Buffer = () => Buffer.from(payload());
    const updater = new Updater(prefs, "0.2.41", () => {}, async () => { calls++; return response(); }, () => announcements++);
    const now = Date.parse("2026-10-06T12:00:00Z");
    await updater.checkIfDue(now); expect(calls).toBe(1); expect(announcements).toBe(1);
    await updater.dismiss(); expect(updater.visible).toBeUndefined();
    // A dismissed release is still offered when the user asks, within the hour and without another notification.
    expect((await updater.checkNow(now + 1000))?.version).toBe("0.2.42"); expect(calls).toBe(2); expect(announcements).toBe(1);
    const current = new Updater(prefs, "0.2.42", () => {}, async () => { calls++; return Buffer.from(payload()); }, () => announcements++);
    await expect(current.checkNow(now + 2000)).resolves.toBeUndefined(); expect(current.available).toBeUndefined();
    response = () => { throw new Error("offline"); };
    await expect(updater.checkNow(now + 3000)).rejects.toThrow("offline");
    await prefs.set("updateCheckEnabled", false); const before = calls;
    await expect(updater.checkNow(now + 4000)).rejects.toThrow("unavailable"); expect(calls).toBe(before);
  });
  it("reuses a scheduled check in progress without its notification, and rejects it once reset", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture defaults"); return ""; }, "fixture.meterusage");
    let calls = 0, announcements = 0, respond!: (data: Buffer) => void;
    const updater = new Updater(prefs, "0.2.41", () => {}, async () => { calls++; return new Promise<Buffer>(resolve => { respond = resolve; }); }, () => announcements++);
    const now = Date.parse("2026-10-06T12:00:00Z");
    const scheduled = updater.checkIfDue(now); await new Promise<void>(resolve => setImmediate(resolve));
    const manual = updater.checkNow(now + 1000);
    respond(Buffer.from(payload())); await scheduled;
    expect((await manual)?.version).toBe("0.2.42"); expect(calls).toBe(1); expect(announcements).toBe(0);
    // A reset while the manual check waits cancels it rather than starting a fresh lookup.
    const second = updater.checkIfDue(now + 3600000); await new Promise<void>(resolve => setImmediate(resolve));
    const waiting = updater.checkNow(now + 3601000);
    updater.reset(); respond(Buffer.from(payload())); await second;
    await expect(waiting).rejects.toThrow(); expect(calls).toBe(2);
  });
  it("never checks on request from a demo candidate", async () => {
    const launch = launchConfiguration(["--demo", "--candidate-profile", temp()], {}), prefs = await Preferences.load(launch);
    let calls = 0; const updater = new Updater(prefs, "0.2.41", () => {}, async () => { calls++; return Buffer.from(payload()); });
    await expect(updater.checkNow()).rejects.toThrow("unavailable"); expect(calls).toBe(0);
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
  it("stages internal bundle links when the temporary root is a symlink", async () => {
    const root = temp(), target = join(root, "actual"), alias = join(root, "alias");
    mkdirSync(target); symlinkSync(target, alias); vi.stubEnv("TMPDIR", alias);
    const archive = readFileSync("tests/fixtures/update-safe.zip");
    const release = parseRelease(payload(undefined, "sha256:" + createHash("sha256").update(archive).digest("hex")));
    try {
      const bundle = await stageUpdate(release, archive, async (binary, args) => {
        if (binary.endsWith("ditto")) {
          const contents = join(args[3], "MeterUsage.app/Contents");
          mkdirSync(contents, { recursive: true }); writeFileSync(join(contents, "Info.plist"), "synthetic");
          symlinkSync("Info.plist", join(contents, "internal-link")); return "";
        }
        if (binary.endsWith("PlistBuddy")) return args[1].endsWith("CFBundleIdentifier") ? "dev.meterusage.app" : args[1].endsWith("CFBundleExecutable") ? "meterusage" : release.version;
        if (binary.endsWith("codesign")) return "";
        throw new Error("unexpected fixture command");
      });
      expect(bundle.startsWith(target + "/")).toBe(true);
    } finally { vi.unstubAllEnvs(); }
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

describe("repository transfer to tilorahdotco", () => {
  const forOwner = (owner: string) => payload(`https://github.com/${owner}/meterusage/releases/download/v0.2.42/MeterUsage-0.2.42.zip`);
  it("accepts assets reported under either the old or the new owner and keeps the reported URL", () => {
    expect(parseRelease(forOwner("pekth")).asset.url).toBe("https://github.com/pekth/meterusage/releases/download/v0.2.42/MeterUsage-0.2.42.zip");
    expect(parseRelease(forOwner("tilorahdotco")).asset.url).toBe("https://github.com/tilorahdotco/meterusage/releases/download/v0.2.42/MeterUsage-0.2.42.zip");
  });
  it("picks a tilorahdotco beta asset from the release list", () => {
    const v = "0.3.0-beta.12", asset = (owner: string) => ({ name: `MeterUsage-${v}-mac-arm64.zip`, browser_download_url: `https://github.com/${owner}/meterusage/releases/download/v${v}/MeterUsage-${v}-mac-arm64.zip`, digest });
    expect(parseReleases(JSON.stringify([{ tag_name: `v${v}`, draft: false, assets: [asset("tilorahdotco")] }])).asset.url).toContain("/tilorahdotco/meterusage/");
    expect(() => parseReleases(JSON.stringify([{ tag_name: `v${v}`, draft: false, assets: [asset("someone-else")] }]))).toThrow();
  });
  it.each(["https://api.github.com/repositories/1318093547/releases?per_page=20", "/repositories/1318093547/releases?per_page=20"])("follows a GitHub API redirect to %s", async location => {
    const seen: string[] = [];
    const fetcher = vi.spyOn(globalThis, "fetch").mockImplementation(async input => {
      const url = String(input); seen.push(url);
      return url === releasesEndpoint ? new Response(null, { status: 301, headers: { location } }) : new Response("[]", { status: 200 });
    });
    try { expect((await fetchUpdate(releasesEndpoint, 1048576)).toString()).toBe("[]"); }
    finally { fetcher.mockRestore(); }
    expect(seen).toEqual([releasesEndpoint, "https://api.github.com/repositories/1318093547/releases?per_page=20"]);
  });
  it("looks up releases at the tilorahdotco repository", () => {
    for (const endpoint of [releaseEndpoint, releasesEndpoint]) expect(endpoint.startsWith("https://api.github.com/repos/tilorahdotco/meterusage/releases")).toBe(true);
  });
  it.each(["someone-else", "tilorahdotco.evil", "PEKTH"])("rejects assets under %s", owner => {
    expect(() => parseRelease(forOwner(owner))).toThrow("Invalid update asset");
  });
});
describe("opt-in automatic install", () => {
  const live = async () => { const root = temp(); return Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture defaults"); return ""; }, "fixture.meterusage"); };
  it("is off by default and offers a release only when opted in, idle and packaged", async () => {
    const prefs = await live(), updater = new Updater(prefs, "0.2.41", () => {}, async () => bytes);
    updater.available = parseRelease(payload());
    expect(prefs.values.updateAutoInstall).toBe(false);
    expect(updater.autoInstallRelease(true, true)).toBeUndefined();
    await prefs.set("updateAutoInstall", true);
    expect(updater.autoInstallRelease(true, true)?.version).toBe("0.2.42");
    expect(updater.autoInstallRelease(false, true)).toBeUndefined();
    expect(updater.autoInstallRelease(true, false)).toBeUndefined();
  });
  it("defers back to idle without staging when MeterUsage comes into use during download", async () => {
    const prefs = await live(); let respond!: (b: Buffer) => void, staged = false, inUse = false;
    const updater = new Updater(prefs, "0.2.41", () => {}, async () => new Promise<Buffer>(r => { respond = r; }));
    const release = parseRelease(payload());
    const installing = updater.install("/tmp/MeterUsage.app", release, async () => { staged = true; return ""; }, () => !inUse);
    const rejected = expect(installing).rejects.toThrow("Update deferred");
    expect(updater.installState).toBe("downloading");
    inUse = true; respond(bytes); await rejected;
    expect(staged).toBe(false); expect(updater.installState).toBe("idle");
    // The manual path stays usable and a later quiet moment can retry.
    await prefs.set("updateAutoInstall", true); updater.available = release;
    expect(updater.autoInstallRelease(true, true)?.version).toBe("0.2.42");
  });
  it.each(["disable", "dismiss"])("defers an automatic download after %s even when the app is idle again", async change => {
    const prefs = await live(); let respond!: (b: Buffer) => void, staged = false;
    const updater = new Updater(prefs, "0.2.41", () => {}, async () => new Promise<Buffer>(r => { respond = r; }));
    await prefs.set("updateAutoInstall", true); updater.available = parseRelease(payload());
    const installing = updater.installAutomatically("/tmp/MeterUsage.app", updater.available, () => true, async () => { staged = true; return ""; });
    const rejected = expect(installing).rejects.toThrow("Update deferred");
    if (change === "disable") await prefs.set("updateAutoInstall", false); else await updater.dismiss();
    respond(bytes); await rejected;
    expect(staged).toBe(false); expect(updater.installState).toBe("idle");
  });
  it("skips dismissed versions, disabled checks and a failed or running install", async () => {
    const prefs = await live(), updater = new Updater(prefs, "0.2.41", () => {}, async () => bytes);
    await prefs.set("updateAutoInstall", true); updater.available = parseRelease(payload());
    updater.installState = "failed"; expect(updater.autoInstallRelease(true, true)).toBeUndefined();
    updater.installState = "downloading"; expect(updater.autoInstallRelease(true, true)).toBeUndefined();
    updater.installState = "idle"; await updater.dismiss(); expect(updater.autoInstallRelease(true, true)).toBeUndefined();
    await prefs.set("updateDismissedVersion", ""); await prefs.set("updateCheckEnabled", false); expect(updater.autoInstallRelease(true, true)).toBeUndefined();
  });
});
describe("beta update channel", () => {
  const beta = (tag: string, extra: Record<string, unknown> = {}) => { const v = tag.slice(1); return { tag_name: tag, draft: false, assets: [{ name: `MeterUsage-${v}-mac-arm64.zip`, browser_download_url: `https://github.com/pekth/meterusage/releases/download/${tag}/MeterUsage-${v}-mac-arm64.zip`, digest }], ...extra }; };
  it("orders betas below their final release", () => {
    expect(newer("0.3.0-beta.5", "0.3.0-beta.4")).toBe(true);
    expect(newer("0.3.0-beta.10", "0.3.0-beta.9")).toBe(true);
    expect(newer("0.3.0", "0.3.0-beta.9")).toBe(true);
    expect(newer("0.3.0-beta.1", "0.3.0")).toBe(false);
    expect(newer("0.2.41", "0.3.0-beta.4")).toBe(false);
    expect(newer("0.3.0-beta.4", "0.3.0-beta.4")).toBe(false);
  });
  it("picks the newest non-draft release with a verified beta asset", () => {
    const list = JSON.stringify([beta("v0.3.0-beta.6", { draft: true }), beta("v0.3.0-beta.5"), beta("v0.3.0-beta.4"), JSON.parse(payload())]);
    const release = parseReleases(list);
    expect(release.version).toBe("0.3.0-beta.5");
    expect(release.asset.url).toBe("https://github.com/pekth/meterusage/releases/download/v0.3.0-beta.5/MeterUsage-0.3.0-beta.5-mac-arm64.zip");
  });
  it("checks the release list from a beta and announces a newer beta once", async () => {
    const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {} }, async (_binary, args) => { if (args[0] !== "write") throw new Error("absent fixture defaults"); return ""; }, "fixture.meterusage");
    await prefs.set("updateCheckEnabled", true);
    let announced = 0, url = "";
    const updater = new Updater(prefs, "0.3.0-beta.4", () => {}, async u => { url = u; return Buffer.from(JSON.stringify([beta("v0.3.0-beta.5")])); }, () => announced++);
    await updater.checkIfDue(Date.now());
    expect(url).toBe(releasesEndpoint);
    expect(updater.visible?.version).toBe("0.3.0-beta.5");
    expect(announced).toBe(1);
  });
});
});
