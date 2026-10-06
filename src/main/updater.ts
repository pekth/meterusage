import { createHash } from "node:crypto";
import { mkdtemp, writeFile, readdir, realpath, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join, relative, basename, dirname } from "node:path";
import { spawn } from "node:child_process";
import { inspectUpdateArchive } from "./update-archive";
import { selectJSON } from "./select-json";
import { Preferences } from "./preferences";
import { runCommand, type Command } from "./providers/transport";
export interface Release { version: string; tag: string; asset: { url: string; digest: string } }
export type InstallState = "idle" | "downloading" | "installing" | "failed";
export const releaseEndpoint = "https://api.github.com/repos/pekth/meterusage/releases/latest";
export function newer(candidate: string, current: string) {
  const parts = (v: string) => v.replace(/^v/i, "").split(".").map(s => Number(s.match(/^\d+/)?.[0] ?? 0));
  const a = parts(candidate), b = parts(current);
  for (let i = 0; i < Math.max(a.length, b.length); i++) if ((a[i] ?? 0) !== (b[i] ?? 0)) return (a[i] ?? 0) > (b[i] ?? 0);
  return false;
}
export function parseRelease(raw: string): Release {
  const data = selectJSON(raw, { tag_name: true, assets: { '*': { name: true, browser_download_url: true, digest: true } } }) as { tag_name?: unknown; assets?: { name?: unknown; browser_download_url?: unknown; digest?: unknown }[] };
  if (typeof data.tag_name !== "string" || !/^v?\d+\.\d+\.\d+$/i.test(data.tag_name)) throw new Error("Invalid release");
  const version = data.tag_name.replace(/^v/i, ""), expected = `MeterUsage-${version}.zip`, asset = data.assets?.find(a => a.name === expected);
  const url = `https://github.com/pekth/meterusage/releases/download/${data.tag_name}/${expected}`;
  if (!asset || asset.browser_download_url !== url || typeof asset.digest !== "string" || !/^sha256:[a-f\d]{64}$/i.test(asset.digest)) throw new Error("Invalid update asset");
  return { version, tag: data.tag_name, asset: { url, digest: asset.digest.toLowerCase() } };
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
  const directory = await mkdtemp(join(tmpdir(), "MeterUsageUpdate-")), zip = join(directory, `MeterUsage-${release.version}.zip`), bundle = join(directory, "MeterUsage.app");
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
  private check?: Promise<void>;
  private generation = 0;
  private checkController?: AbortController;
  private installController?: AbortController;
  constructor(readonly prefs: Preferences, readonly currentVersion: string, readonly changed: () => void, readonly download = fetchUpdate, readonly announce: (release: Release) => void = () => {}) {}
  get visible() { return this.prefs.values.updateCheckEnabled === true && this.available?.version !== this.prefs.values.updateDismissedVersion ? this.available : undefined; }
  checkIfDue(now = Date.now()) {
    if (this.prefs.launch.demo || this.prefs.values.updateCheckEnabled !== true || this.check || now - Number(this.prefs.values.updateLastCheckDate ?? 0) < 3600000) return;
    const generation = this.generation, controller = new AbortController(); this.checkController = controller;
    const pending: Promise<void> = (async () => {
      await this.prefs.set("updateLastCheckDate", now);
      if (generation !== this.generation || this.prefs.values.updateCheckEnabled !== true) return;
      const release = parseRelease((await this.download(releaseEndpoint, 1048576, controller.signal)).toString("utf8"));
      if (generation !== this.generation || this.prefs.values.updateCheckEnabled !== true || !newer(release.version, this.currentVersion)) return;
      this.available = release;
      if (this.prefs.values.updateAnnouncedVersion !== release.version) { await this.prefs.set("updateAnnouncedVersion", release.version); if (generation !== this.generation || this.prefs.values.updateCheckEnabled !== true) return; this.announce(release); }
      this.changed();
    })().catch(() => { /* A release lookup failure stays separate from usage. */ }).finally(() => { if (this.check === pending) { this.check = undefined; this.checkController = undefined; } });
    this.check = pending; return pending;
  }
  reset() { this.generation++; this.checkController?.abort(); this.installController?.abort(); this.checkController = undefined; this.check = undefined; this.available = undefined; this.changed(); }
  async dismiss() { if (this.available) await this.prefs.set("updateDismissedVersion", this.available.version); this.changed(); }
  async install(current: string, release: Release | undefined, command: Command = runCommand) {
    if (this.prefs.launch.demo || this.prefs.values.updateCheckEnabled !== true || basename(current) !== "MeterUsage.app" || !release || ["downloading", "installing"].includes(this.installState)) throw new Error("Update installation unavailable");
    const generation = this.generation, controller = new AbortController(); this.installController = controller;
    const guard = () => { controller.signal.throwIfAborted(); if (generation !== this.generation || this.prefs.values.updateCheckEnabled !== true) throw new Error("Update cancelled"); };
    this.installState = "downloading"; this.changed();
    let stage: string | undefined, helper: string | undefined;
    try {
      const bytes = await this.download(release.asset.url, 512 * 1048576, controller.signal); guard();
      const staged = await stageUpdate(release, bytes, command, controller.signal);
      stage = dirname(staged); guard(); helper = await mkdtemp(join(tmpdir(), "MeterUsageUpdateInstall-"));
      const script = join(helper, "install.zsh"); await writeFile(script, installScript(current, staged, process.pid), { mode: 0o700 });
      guard(); const child = spawn("/bin/zsh", [script], { detached: true, stdio: "ignore" });
      await new Promise<void>((resolve, reject) => { child.once("spawn", resolve); child.once("error", reject); });
      try { guard(); } catch (error) { child.kill(); throw error; } child.unref();
      this.installState = "installing"; this.changed();
    } catch { if (stage) await rm(stage, { recursive: true, force: true }); if (helper) await rm(helper, { recursive: true, force: true }); this.installState = "failed"; this.changed(); throw new Error("Could not install update"); }
    finally { if (this.installController === controller) this.installController = undefined; }
  }
}
