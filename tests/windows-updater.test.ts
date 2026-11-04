import { afterEach, describe, expect, it, vi } from "vite-plus/test";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";
import { Updater, inspectWindowsInstaller, removeStagedInstallers, parseRelease, parseReleases, releasesEndpoint, stageWindowsInstaller, windowsInstallation, windowsInstallerArgs, type Release } from "../src/main/updater";
import { Preferences } from "../src/main/preferences";

const roots: string[] = [];
const temp = () => { const root = realpathSync(mkdtempSync(join(tmpdir(), "meterusage-winupdate-fixture-"))); roots.push(root); return root; };
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

// Synthetic bytes shaped like an NSIS installer: DOS header, PE signature, i386 machine, NSIS marker. Not executable.
function installer(machine = 0x14c, marker = "NullsoftInst") {
  const bytes = Buffer.alloc(8192);
  bytes.write("MZ", 0, "latin1"); bytes.writeUInt32LE(0x80, 0x3c); bytes.writeUInt32LE(0x4550, 0x80); bytes.writeUInt16LE(machine, 0x84);
  bytes.write(marker, 0x1000, "latin1");
  return bytes;
}
const sha = (bytes: Buffer) => "sha256:" + createHash("sha256").update(bytes).digest("hex");
const asset = (version: string, name: string, bytes = installer(), owner = "tilorahdotco") => ({ name, browser_download_url: `https://github.com/${owner}/meterusage/releases/download/v${version}/${name}`, digest: sha(bytes) });
const release = (version: string, assets: unknown[], extra: Record<string, unknown> = {}) => ({ tag_name: `v${version}`, draft: false, assets, ...extra });
const winRelease = (version: string, bytes = installer()) => release(version, [asset(version, `MeterUsage-${version}-win-x64.exe`, bytes)]);
const macRelease = (version: string) => release(version, [asset(version, `MeterUsage-${version}-mac-arm64.zip`)]);

async function windowsPrefs() {
  const root = temp(), prefs = await Preferences.load({ demo: false, candidate: false, home: root, data: root, env: {}, platform: "win32" }, async () => { throw new Error("defaults must not run on Windows"); });
  return prefs;
}
function installed() {
  const root = temp();
  writeFileSync(join(root, "MeterUsage.exe"), "synthetic"); writeFileSync(join(root, "Uninstall MeterUsage.exe"), "synthetic");
  return root;
}

describe("Windows release assets", () => {
  it("selects only the Windows installer on Windows and only macOS assets elsewhere", () => {
    const list = JSON.stringify([winRelease("0.3.0-beta.14"), macRelease("0.3.0-beta.13"), release("0.3.0-beta.15", [asset("0.3.0-beta.15", "MeterUsage-0.3.0-beta.15-win-x64.exe")], { draft: true })]);
    expect(parseReleases(list, "win32")).toMatchObject({ version: "0.3.0-beta.14", asset: { url: "https://github.com/tilorahdotco/meterusage/releases/download/v0.3.0-beta.14/MeterUsage-0.3.0-beta.14-win-x64.exe" } });
    expect(parseReleases(list, "darwin").version).toBe("0.3.0-beta.13");
    expect(() => parseRelease(JSON.stringify(macRelease("0.3.1")), "win32")).toThrow("Invalid update asset");
    expect(() => parseRelease(JSON.stringify(winRelease("0.3.1")), "darwin")).toThrow("Invalid update asset");
  });
  it("accepts only the tilorahdotco owner and rejects the retired pekth owner, other owners, portable zips and missing digests", () => {
    const v = "0.3.0-beta.14", name = `MeterUsage-${v}-win-x64.exe`;
    expect(parseRelease(JSON.stringify(release(v, [asset(v, name, installer(), "tilorahdotco")])), "win32").asset.url).toContain("/tilorahdotco/meterusage/");
    for (const assets of [[asset(v, name, installer(), "pekth")], [asset(v, name, installer(), "someone-else")], [asset(v, `MeterUsage-${v}-win-x64.zip`)], [{ ...asset(v, name), digest: undefined }]]) expect(() => parseRelease(JSON.stringify(release(v, assets)), "win32")).toThrow("Invalid update asset");
  });
});

describe("Windows installer staging", () => {
  it("accepts a PE executable with an NSIS payload and rejects anything else", () => {
    expect(() => inspectWindowsInstaller(installer())).not.toThrow();
    expect(() => inspectWindowsInstaller(installer(0x8664))).not.toThrow();
    for (const bytes of [installer(0x1c0), installer(0x14c, "NotAnInstaller"), Buffer.from("PK\x03\x04 zip archive".padEnd(8192, "\0")), installer().subarray(0, 1024)]) expect(() => inspectWindowsInstaller(bytes)).toThrow("Invalid update installer");
  });
  it("verifies the digest before writing and stages the exact bytes", async () => {
    const bytes = installer(), target: Release = { version: "0.3.0-beta.14", tag: "v0.3.0-beta.14", asset: { url: "https://github.com/tilorahdotco/meterusage/releases/download/v0.3.0-beta.14/MeterUsage-0.3.0-beta.14-win-x64.exe", digest: sha(bytes) } };
    await expect(stageWindowsInstaller({ ...target, asset: { ...target.asset, digest: sha(installer(0x8664)) } }, bytes)).rejects.toThrow("Invalid update digest");
    const path = await stageWindowsInstaller(target, bytes); roots.push(dirname(path));
    expect(path.endsWith("MeterUsage-0.3.0-beta.14-win-x64.exe")).toBe(true); expect(readFileSync(path).equals(bytes)).toBe(true);
  });
  it("removes only stale MeterUsage installer folders from the temporary root", async () => {
    const root = temp();
    for (const name of ["MeterUsageUpdate-Ab12Cd", "MeterUsageUpdate-other-name", "Unrelated-Ab12Cd"]) { mkdirSync(join(root, name)); writeFileSync(join(root, name, "file"), "synthetic"); }
    writeFileSync(join(root, "MeterUsageUpdate-File01"), "synthetic file, not a folder");
    await removeStagedInstallers(root);
    expect(["MeterUsageUpdate-Ab12Cd", "MeterUsageUpdate-other-name", "Unrelated-Ab12Cd", "MeterUsageUpdate-File01"].map(name => existsSync(join(root, name)))).toEqual([false, true, true, true]);
  });
  it("recognizes only an NSIS installation folder", () => {
    const portable = temp(); writeFileSync(join(portable, "MeterUsage.exe"), "synthetic");
    expect(windowsInstallation(installed())).toBe(true); expect(windowsInstallation(portable)).toBe(false);
  });
});

describe("Windows update install", () => {
  const offered = (bytes = installer()) => parseRelease(JSON.stringify(winRelease("0.3.0-beta.14", bytes)), "win32");
  it("checks the release list from a Windows beta and offers the Windows installer", async () => {
    const prefs = await windowsPrefs(); let url = "";
    const updater = new Updater(prefs, "0.3.0-beta.13", () => {}, async u => { url = u; return Buffer.from(JSON.stringify([macRelease("0.3.0-beta.15"), winRelease("0.3.0-beta.14")])); });
    await updater.checkIfDue(Date.now());
    expect(url).toBe(releasesEndpoint); expect(updater.visible?.version).toBe("0.3.0-beta.14");
  });
  it("stages the verified installer and starts it detached only when quit finishes", async () => {
    const prefs = await windowsPrefs(), bytes = installer(), updater = new Updater(prefs, "0.3.0-beta.13", () => {}, async () => bytes);
    const start = vi.fn(() => ({ on() { return this; }, unref() {} }));
    await updater.install(installed(), offered(bytes));
    expect(updater.installState).toBe("installing"); expect(start).not.toHaveBeenCalled();
    expect(updater.launchPendingInstaller(start as never)).toBe(true);
    const [file, args, options] = (start.mock.calls[0] as unknown[]) as [string, string[], Record<string, unknown>]; roots.push(dirname(file));
    expect(readFileSync(file).equals(bytes)).toBe(true); expect(args).toEqual([...windowsInstallerArgs]); expect(options).toMatchObject({ detached: true, stdio: "ignore", windowsHide: true });
    expect(updater.launchPendingInstaller(start as never)).toBe(false); expect(start).toHaveBeenCalledTimes(1);
  });
  it("refuses portable copies and fails without a pending installer on changed bytes", async () => {
    const prefs = await windowsPrefs(), portable = temp(); writeFileSync(join(portable, "MeterUsage.exe"), "synthetic");
    const updater = new Updater(prefs, "0.3.0-beta.13", () => {}, async () => installer(0x8664));
    await expect(updater.install(portable, offered())).rejects.toThrow("Update installation unavailable");
    await expect(updater.install(installed(), offered())).rejects.toThrow("Could not install update");
    expect(updater.installState).toBe("failed"); expect(updater.launchPendingInstaller(vi.fn() as never)).toBe(false);
  });
  it("defers an automatic install to idle without leaving a staged installer when MeterUsage comes into use", async () => {
    const prefs = await windowsPrefs(), bytes = installer(); let respond!: (b: Buffer) => void, inUse = false;
    const updater = new Updater(prefs, "0.3.0-beta.13", () => {}, async () => new Promise<Buffer>(r => { respond = r; }));
    await prefs.set("updateAutoInstall", true); updater.available = offered(bytes);
    const installing = updater.installAutomatically(installed(), updater.available, () => !inUse);
    const rejected = expect(installing).rejects.toThrow("Update deferred");
    inUse = true; respond(bytes); await rejected;
    expect(updater.installState).toBe("idle"); expect(updater.launchPendingInstaller(vi.fn() as never)).toBe(false);
  });
});
