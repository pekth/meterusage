import { userInfo, tmpdir, hostname } from "node:os";
import { mkdtempSync, mkdirSync, realpathSync, existsSync, readdirSync, writeFileSync, lstatSync, readlinkSync } from "node:fs";
import { isAbsolute, join, resolve, relative, dirname } from "node:path";
export interface Launch { demo: boolean; candidate: boolean; home: string; data: string; env: NodeJS.ProcessEnv; profile?: string; codexTest?: boolean }
export function launchConfiguration(args: string[], env: NodeJS.ProcessEnv = process.env, realHome = userInfo().homedir, electronSingletons = false): Launch {
  const demo = args.includes("--demo") || env.METERUSAGE_DEMO === "1", candidateIndex = args.indexOf("--candidate-profile"), codexIndex = args.indexOf("--codex-test-profile"), codexTest = codexIndex >= 0;
  if (codexTest && (demo || candidateIndex >= 0)) throw new Error("Codex test profile flags conflict with demo/candidate mode");
  const index = codexTest ? codexIndex : candidateIndex, profile = index < 0 ? undefined : args[index + 1];
  if (index >= 0 && ((!codexTest && !demo) || !profile || !isAbsolute(profile))) throw new Error("Candidate profile requires an absolute test directory and --demo unless using --codex-test-profile");
  if (profile) {
    const normalized = resolve(profile), liveData = join(realHome, "Library/Application Support/MeterUsage");
    const inside = relative(liveData, normalized);
    if (normalized === "/" || normalized === realHome || inside === "" || (inside !== ".." && !inside.startsWith("../"))) throw new Error("Candidate profile cannot use installed-app storage");
    let ancestor = normalized;
    while (!existsSync(ancestor)) ancestor = dirname(ancestor);
    if (realpathSync(ancestor) !== ancestor) throw new Error("Candidate profile cannot follow a symlink");
    mkdirSync(normalized, { recursive: true, mode: 0o700 });
    const marker = join(normalized, codexTest ? ".meterusage-codex-test" : ".meterusage-candidate");
    if (existsSync(marker) && !lstatSync(marker).isFile()) throw new Error("Candidate profile marker must be a regular file, not a symlink");
    if (!existsSync(marker) && readdirSync(normalized).length) throw new Error("Candidate profile must be an empty test directory");
    // Validate metadata before Electron or the helper can write into this profile.
    const pending = [{ path: normalized, depth: 0 }];
    const singletonPaths = ["SingletonSocket", "SingletonCookie", "SingletonLock"].map(name => join(normalized, "electron", name));
    let singletonLinks = 0;
    let entries = 0;
    while (pending.length) {
      const { path, depth } = pending.pop()!, stat = lstatSync(path);
      if (++entries > 32768 || depth > 24) throw new Error("Candidate profile exceeds inspection limits");
      if (stat.isSymbolicLink()) {
        if (!electronSingletons || !singletonPaths.includes(path)) throw new Error("Candidate profile cannot contain a symlink");
        singletonLinks++; continue;
      }
      if (stat.isDirectory()) for (const name of readdirSync(path)) pending.push({ path: join(path, name), depth: depth + 1 });
      else if (!stat.isFile()) throw new Error("Candidate profile must contain only regular files and directories");
    }
    if (singletonLinks) validateElectronSingletons(singletonPaths);
    if (!existsSync(marker)) writeFileSync(marker, codexTest ? "MeterUsage Codex test profile\n" : "Synthetic MeterUsage candidate profile\n", { mode: 0o600 });
  }
  // Demo always isolates preferences, provider sources, caches and Electron's
  // userData before any provider or coordinator is constructed.
  const isolated = codexTest ? resolve(profile!) : demo ? profile ?? mkdtempSync(join(tmpdir(), "meterusage-demo-")) : undefined;
  return { demo, candidate: index >= 0, ...(codexTest ? { codexTest: true } : {}), home: demo ? isolated! : realHome, data: isolated ?? join(realHome, "Library/Application Support/MeterUsage"), profile: isolated, env: codexTest ? { PATH: env.PATH, TMPDIR: env.TMPDIR } : demo ? {} : { ...env } };
}

function validateElectronSingletons([socketLink, cookieLink, lockLink]: string[]) {
  const invalid = () => { throw new Error("Candidate profile contains invalid Electron singleton metadata"); };
  const uid = process.getuid?.();
  if (uid === undefined) invalid();
  for (const path of [socketLink, cookieLink, lockLink]) {
    const stat = lstatSync(path, { throwIfNoEntry: false });
    if (!stat?.isSymbolicLink() || stat.uid !== uid) invalid();
  }
  const cookie = readlinkSync(cookieLink), lock = readlinkSync(lockLink), socket = readlinkSync(socketLink);
  if (!/^\d{1,32}$/.test(cookie) || !lock.startsWith(`${hostname()}-`) || !/^[1-9]\d{0,9}$/.test(lock.slice(hostname().length + 1))) invalid();
  if (!isAbsolute(socket) || resolve(socket) !== socket || !socket.endsWith("/SingletonSocket")) invalid();
  // Inspect metadata under the trusted temp root without resolving any profile link.
  const tempRoot = realpathSync(tmpdir());
  const inside = relative(socket.startsWith(`${tempRoot}/`) ? tempRoot : resolve(tmpdir()), socket);
  if (inside === ".." || inside.startsWith("../") || isAbsolute(inside)) invalid();
  const target = join(tempRoot, inside), directory = dirname(target);
  let path = tempRoot;
  for (const part of relative(tempRoot, directory).split("/")) {
    path = join(path, part);
    const stat = lstatSync(path, { throwIfNoEntry: false });
    if (!stat?.isDirectory()) invalid();
  }
  const parent = lstatSync(directory), endpoint = lstatSync(target, { throwIfNoEntry: false });
  const remoteCookie = join(directory, "SingletonCookie"), remote = lstatSync(remoteCookie, { throwIfNoEntry: false });
  if (directory === tempRoot || parent.uid !== uid || (parent.mode & 0o077) !== 0 || !endpoint?.isSocket() || endpoint.uid !== uid || !remote?.isSymbolicLink() || remote.uid !== uid || readlinkSync(remoteCookie) !== cookie) invalid();
}
