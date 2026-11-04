import { createHash } from "node:crypto";
import { mkdtemp, writeFile, readdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, basename, dirname, isAbsolute } from "node:path";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { inspectUpdateArchive } from "./update-archive";
import { selectJSON } from "./select-json";
import { Preferences } from "./preferences";
import { runCommand, type Command } from "./providers/transport";
import { type Platform } from "./platform";
export interface Release { version: string; tag: string; asset: { url: string; digest: string } }
export type InstallState = "idle" | "downloading" | "installing" | "failed";
export const releaseEndpoint = "https://api.github.com/repos/tilorahdotco/meterusage/releases/latest";
/** Beta builds read the release list: GitHub's "latest" never includes prereleases. */
export const releasesEndpoint = "https://api.github.com/repos/tilorahdotco/meterusage/releases?per_page=20";
const versionPattern = /^v?(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?$/i;
export const isPrerelease = (version: string) => /-beta\.\d+$/i.test(version);
/** Semantic order for x.y.z and x.y.z-beta.n; a final release outranks its betas. */
export function newer(candidate: string, current: string) {
  const parse = (v: string) => { const m = v.trim().match(versionPattern); return m ? [Number(m[1]), Number(m[2]), Number(m[3]), m[4] === undefined ? Infinity : Number(m[4])] : undefined; };
  const a = parse(candidate), b = parse(current);
  if (!a || !b) return false;
  for (let i = 0; i < 4; i++) if (a[i] !== b[i]) return a[i] > b[i];
  return false;
}
type RawRelease = { tag_name?: unknown; draft?: unknown; assets?: { name?: unknown; browser_download_url?: unknown; digest?: unknown }[] };
const releaseShape = { tag_name: true, draft: true, assets: { '*': { name: true, browser_download_url: true, digest: true } } } as const;
// The repository was transferred from pekth to tilorahdotco on 2026-11-01. GitHub reports asset URLs under the
// new owner; pekth stays accepted for the same repository's old URLs. Accept exactly these two and nothing else.
const releaseOwners = ["tilorahdotco", "pekth"] as const;
function releaseFrom(data: RawRelease, platform: Platform): Release {
  if (typeof data.tag_name !== "string" || !versionPattern.test(data.tag_name) || data.draft === true) throw new Error("Invalid release");
  const version = data.tag_name.replace(/^v/i, "");
  // Stable Swift assets are MeterUsage-<v>.zip; Electron betas add -mac-arm64. Windows uses the NSIS installer only.
  for (const expected of platform === "win32" ? [`MeterUsage-${version}-win-x64.exe`] : [`MeterUsage-${version}.zip`, `MeterUsage-${version}-mac-arm64.zip`]) {
    const asset = data.assets?.find(a => a.name === expected);
    const url = releaseOwners.map(owner => `https://github.com/${owner}/meterusage/releases/download/${data.tag_name}/${expected}`).find(candidate => asset?.browser_download_url === candidate);
    if (asset && url && typeof asset.digest === "string" && /^sha256:[a-f\d]{64}$/i.test(asset.digest)) return { version, tag: data.tag_name, asset: { url, digest: asset.digest.toLowerCase() } };
  }
  throw new Error("Invalid update asset");
}
export function parseRelease(raw: string, platform: Platform = process.platform): Release {
  return releaseFrom(selectJSON(raw, releaseShape) as RawRelease, platform);
}
/** The newest valid, non-draft release in a GitHub release list. */
export function parseReleases(raw: string, platform: Platform = process.platform): Release {
  const list = selectJSON(raw, { '*': releaseShape }) as RawRelease[] | undefined;
  if (!Array.isArray(list)) throw new Error("Invalid release list");
  let best: Release | undefined;
  for (const data of list) { try { const release = releaseFrom(data, platform); if (!best || newer(release.version, best.version)) best = release; } catch { /* Skip drafts and unusable releases. */ } }
  if (!best) throw new Error("No usable release");
  return best;
}
export function verifyDigest(data: Uint8Array, expected: string) {
  if (!/^sha256:[a-f\d]{64}$/i.test(expected) || createHash("sha256").update(data).digest("hex") !== expected.slice(7).toLowerCase()) throw new Error("Invalid update digest");
}
export async function fetchUpdate(url: string, maxBytes: number, signal?: AbortSignal): Promise<Buffer> {
  const allowed = (u: URL) => u.protocol === "https:" && !u.username && !u.password && !u.port && ["api.github.com", "github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"].includes(u.hostname);
  let target = new URL(url); const controller = new AbortController(), timer = setTimeout(() => controller.abort(), 120000);
  const abort = () => controller.abort(); signal?.addEventListener("abort", abort, { once: true }); if (signal?.aborted) abort();
  try {
    for (let redirects = 0; redirects <= 3; redirects++) {
      if (!allowed(target)) throw new Error("Invalid update host");
      const response = await fetch(target, { redirect: "manual", signal: controller.signal, headers: { Accept: "application/json", "User-Agent": "meterusage/0.2.41" } });
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        await response.body?.cancel(); const next = response.headers.get("location"); if (!next) throw new Error("Invalid redirect"); target = new URL(next, target); continue;
      }
      if (response.status !== 200 || !response.body || Number(response.headers.get("content-length") ?? 0) > maxBytes) { await response.body?.cancel(); throw new Error("Update download failed"); }
      const chunks: Uint8Array[] = []; let size = 0;
      for await (const chunk of response.body) { size += chunk.byteLength; if (size > maxBytes) { controller.abort(); throw new Error("Update too large"); } chunks.push(chunk); }
      return Buffer.concat(chunks, size);
    }
    throw new Error("Too many update redirects");
  } finally { clearTimeout(timer); signal?.removeEventListener("abort", abort); }
}
export async function stageUpdate(release: Release, data: Uint8Array, command: Command = runCommand, signal?: AbortSignal): Promise<string> {
  verifyDigest(data, release.asset.digest);
  await inspectUpdateArchive(Buffer.from(data)); signal?.throwIfAborted();
  const run: Command = (binary, args, options) => command(binary, args, { ...options, signal });
  const directory = await mkdtemp(join(await realpath(tmpdir()), "MeterUsageUpdate-")), zip = join(directory, `MeterUsage-${release.version}.zip`), bundle = join(directory, "MeterUsage.app");
  try {
  await writeFile(zip, data, { mode: 0o600 });
  await run("/usr/bin/ditto", ["-x", "-k", zip, directory], { timeoutMs: 30000 });
  async function checkLinks(root: string) {
    for (const entry of await readdir(root, { withFileTypes: true })) {
      const path = join(root, entry.name);
      if (entry.isSymbolicLink()) { const resolved = relative(bundle, await realpath(path)); if (resolved === ".." || resolved.startsWith("../")) throw new Error("Invalid bundle link"); }
      else if (entry.isDirectory()) await checkLinks(path);
    }
  }
  await checkLinks(bundle);
  const plist = join(bundle, "Contents/Info.plist");
  for (const [key, expected] of [["CFBundleIdentifier", "dev.meterusage.app"], ["CFBundleExecutable", "meterusage"], ["CFBundleShortVersionString", release.version]]) {
    const actual = await run("/usr/libexec/PlistBuddy", ["-c", `Print :${key}`, plist], { timeoutMs: 5000 }); if (actual.trim() !== expected) throw new Error("Invalid update bundle");
  }
  await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle], { timeoutMs: 30000 });
  signal?.throwIfAborted(); return bundle;
  } catch (e) { await rm(directory, { recursive: true, force: true }); throw e; }
}
/** Silent per-user NSIS update that relaunches the app, as electron-builder's installer expects. */
export const windowsInstallerArgs = ["/S", "--updated", "--force-run"] as const;
/** Structure check for the unsigned Windows installer: a PE executable carrying an NSIS payload. Not a signature. */
export function inspectWindowsInstaller(data: Uint8Array) {
  const bytes = Buffer.from(data.buffer, data.byteOffset, data.byteLength), invalid = () => new Error("Invalid update installer");
  if (bytes.length < 4096 || bytes.readUInt16LE(0) !== 0x5a4d) throw invalid();
  const header = bytes.readUInt32LE(0x3c);
  if (header + 6 > bytes.length || bytes.readUInt32LE(header) !== 0x4550 || ![0x14c, 0x8664].includes(bytes.readUInt16LE(header + 4))) throw invalid();
  if (!bytes.includes("NullsoftInst")) throw invalid();
}
/** An NSIS install keeps its uninstaller beside the executable; zip and portable copies cannot be updated in place. */
export const windowsInstallation = (directory: string) => existsSync(join(directory, "MeterUsage.exe")) && existsSync(join(directory, "Uninstall MeterUsage.exe"));
/** Removes installers staged by earlier Windows updates; one still running stays locked and is skipped. */
export async function removeStagedInstallers(root = tmpdir()) {
  const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
  for (const entry of entries) if (entry.isDirectory() && /^MeterUsageUpdate-[A-Za-z0-9]{6}$/.test(entry.name)) await rm(join(root, entry.name), { recursive: true, force: true }).catch(() => {});
}
export async function stageWindowsInstaller(release: Release, data: Uint8Array, signal?: AbortSignal): Promise<string> {
  verifyDigest(data, release.asset.digest);
  inspectWindowsInstaller(data); signal?.throwIfAborted();
  const directory = await mkdtemp(join(tmpdir(), "MeterUsageUpdate-")), installer = join(directory, `MeterUsage-${release.version}-win-x64.exe`);
  try { await writeFile(installer, data, { flag: "wx" }); signal?.throwIfAborted(); return installer; }
  catch (error) { await rm(directory, { recursive: true, force: true }); throw error; }
}
const quote = (s: string) => "'" + s.replace(/'/g, "'\\''") + "'";
export function installScript(current: string, staged: string, pid: number): string {
  // Copy on the destination filesystem before moving the current bundle.
  // An incomplete copy never removes the user's working application.
  if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error("Invalid process");
  return `#!/bin/zsh\nset -eu\ncurrent=${quote(current)}\nstaged=${quote(staged)}\nreplacement="$current.replacement.$$"\nbackup="$current.backup.$$"\nstage="${'${staged:h}'}"\nhelper="${'${0:h}'}"\ntrap '/bin/rm -rf "$replacement" "$stage" "$helper"' EXIT\nfor attempt in {1..30}; do\n  if ! /bin/kill -0 ${pid} 2>/dev/null; then break; fi\n  /bin/sleep 1\ndone\nif /bin/kill -0 ${pid} 2>/dev/null; then exit 1; fi\n/usr/bin/ditto "$staged" "$replacement"\n/usr/bin/codesign --verify --deep --strict "$replacement"\n/bin/mv "$current" "$backup"\nif ! /bin/mv "$replacement" "$current"; then\n  /bin/mv "$backup" "$current"\n  exit 1\nfi\n/usr/bin/open "$current"\n/bin/rm -rf "$backup"\n`;
}
export class Updater {
  available?: Release;
  installState: InstallState = "idle";
  /** A verified Windows installer that starts only after MeterUsage has finished quitting. */
  private pendingInstaller?: string;
  private check?: Promise<Release | undefined>;
  /** Set while a user-requested check waits on a scheduled one, so that check posts no notification. */
  private quiet = false;
  private generation = 0;
  private checkController?: AbortController;
  private installController?: AbortController;
  constructor(readonly prefs: Preferences, readonly currentVersion: string, readonly changed: () => void, readonly download = fetchUpdate, readonly announce: (release: Release) => void = () => {}) {}
  get visible() { return !this.prefs.launch.demo && !this.prefs.launch.candidate && this.prefs.values.updateCheckEnabled === true && this.available?.version !== this.prefs.values.updateDismissedVersion ? this.available : undefined; }
  private get platform() { return this.prefs.launch.platform ?? process.platform; }
  checkIfDue(now = Date.now()) {
    if (this.prefs.launch.demo || this.prefs.launch.candidate || this.prefs.values.updateCheckEnabled !== true || this.check || now - Number(this.prefs.values.updateLastCheckDate ?? 0) < 3600000) return;
    return this.start(now, true).then(() => {}, () => { /* A release lookup failure stays separate from usage. */ });
  }
  /**
   * A check the user asked for. It skips the hourly limit and does not post a notification. It resolves with a newer
   * release, even one the user dismissed, or undefined when this version is current, and rejects when the lookup fails
   * or is cancelled. A scheduled check already in progress is reused, without its notification.
   */
  async checkNow(now = Date.now()) {
    if (this.prefs.launch.demo || this.prefs.launch.candidate || this.prefs.values.updateCheckEnabled !== true) throw new Error("Update checks unavailable");
    if (!this.check) return this.start(now, false);
    this.quiet = true;
    try { return await this.check; } finally { this.quiet = false; }
  }
  private start(now: number, announce: boolean) {
    const generation = this.generation, controller = new AbortController(); this.checkController = controller;
    const cancelled = () => generation !== this.generation || this.prefs.values.updateCheckEnabled !== true;
    const pending: Promise<Release | undefined> = (async () => {
      await this.prefs.set("updateLastCheckDate", now);
      if (cancelled()) throw new Error("Update check cancelled");
      const beta = isPrerelease(this.currentVersion);
      const raw = (await this.download(beta ? releasesEndpoint : releaseEndpoint, 1048576, controller.signal)).toString("utf8");
      const release = beta ? parseReleases(raw, this.platform) : parseRelease(raw, this.platform);
      if (cancelled()) throw new Error("Update check cancelled");
      if (!newer(release.version, this.currentVersion)) return undefined;
      this.available = release;
      // Announce first, with no await since the last cancellation check, then record the version. A quiet manual check
      // records nothing, so a later scheduled check still announces.
      if (announce && !this.quiet && this.prefs.values.updateAnnouncedVersion !== release.version) {
        this.announce(release);
        await this.prefs.set("updateAnnouncedVersion", release.version); if (cancelled()) throw new Error("Update check cancelled");
      }
      this.changed(); return release;
    })().finally(() => { if (this.check === pending) { this.check = undefined; this.checkController = undefined; } });
    this.check = pending; return pending;
  }
  /** The release to install without a prompt, only when opted in, idle, packaged and not previously failed or dismissed. */
  autoInstallRelease(idle: boolean, packaged: boolean) {
    return this.prefs.values.updateAutoInstall === true && idle && packaged && this.installState === "idle" ? this.visible : undefined;
  }
  // Leaves pendingInstaller alone: quit calls reset() first and launchPendingInstaller() at its end.
  reset() { this.generation++; this.checkController?.abort(); this.installController?.abort(); this.checkController = undefined; this.check = undefined; this.available = undefined; this.changed(); }
  async dismiss() { if (this.available) await this.prefs.set("updateDismissedVersion", this.available.version); this.changed(); }
  installAutomatically(current: string, release: Release, notInUse: () => boolean, command: Command = runCommand) {
    return this.install(current, release, command, () => this.prefs.values.updateAutoInstall === true && this.visible?.version === release.version && notInUse());
  }
  /**
   * `allowed` is rechecked after download and immediately before the installer starts; when it turns false the
   * install is cancelled back to "idle" (not "failed") so an automatic install can retry at the next quiet moment.
   */
  async install(current: string, release: Release | undefined, command: Command = runCommand, allowed: () => boolean = () => true) {
    const windows = this.platform === "win32";
    if (this.prefs.launch.demo || this.prefs.launch.candidate || this.prefs.values.updateCheckEnabled !== true || (windows ? !windowsInstallation(current) : basename(current) !== "MeterUsage.app") || !release || ["downloading", "installing"].includes(this.installState)) throw new Error("Update installation unavailable");
    const generation = this.generation, controller = new AbortController(); this.installController = controller;
    let deferred = false;
    const guard = () => { controller.signal.throwIfAborted(); if (generation !== this.generation || this.prefs.values.updateCheckEnabled !== true) throw new Error("Update cancelled"); };
    const proceed = () => { guard(); if (!allowed()) { deferred = true; throw new Error("Update deferred"); } };
    this.installState = "downloading"; this.changed();
    let stage: string | undefined, helper: string | undefined;
    try {
      const bytes = await this.download(release.asset.url, 512 * 1048576, controller.signal); proceed();
      if (windows) {
        // The installer replaces files MeterUsage holds open, so it starts from launchPendingInstaller once quit finishes.
        const installer = await stageWindowsInstaller(release, bytes, controller.signal); stage = dirname(installer);
        proceed(); this.pendingInstaller = installer;
        this.installState = "installing"; this.changed(); return;
      }
      const staged = await stageUpdate(release, bytes, command, controller.signal);
      stage = dirname(staged); guard(); helper = await mkdtemp(join(tmpdir(), "MeterUsageUpdateInstall-"));
      const script = join(helper, "install.zsh"); await writeFile(script, installScript(current, staged, process.pid), { mode: 0o700 });
      proceed(); const child = spawn("/bin/zsh", [script], { detached: true, stdio: "ignore" });
      await new Promise<void>((resolve, reject) => { child.once("spawn", resolve); child.once("error", reject); });
      try { guard(); } catch (error) { child.kill(); throw error; } child.unref();
      this.installState = "installing"; this.changed();
    } catch {
      if (stage) await rm(stage, { recursive: true, force: true }); if (helper) await rm(helper, { recursive: true, force: true });
      this.installState = deferred ? "idle" : "failed"; this.changed(); throw new Error(deferred ? "Update deferred" : "Could not install update");
    }
    finally { if (this.installController === controller) this.installController = undefined; }
  }
  /** Called once at the end of quit. Starts the staged Windows installer detached; it relaunches MeterUsage. */
  launchPendingInstaller(start: typeof spawn = spawn) {
    const installer = this.pendingInstaller; this.pendingInstaller = undefined;
    if (!installer || !isAbsolute(installer)) return false;
    try { start(installer, [...windowsInstallerArgs], { cwd: dirname(installer), detached: true, stdio: "ignore", windowsHide: true }).on("error", () => { /* The current app stays installed. */ }).unref(); return true; }
    catch { return false; }
  }
}
