import { userInfo, tmpdir, hostname } from "node:os";
import { mkdtempSync, mkdirSync, realpathSync, existsSync, readdirSync, writeFileSync, lstatSync, readlinkSync } from "node:fs";
import { isAbsolute, join, resolve, relative, dirname, parse, sep } from "node:path";
import { applicationData } from "./platform";
export interface Launch { demo: boolean; candidate: boolean; home: string; data: string; env: NodeJS.ProcessEnv; profile?: string; codexTest?: boolean; claudeTest?: boolean; platform?: NodeJS.Platform }
export function launchConfiguration(args: string[], env: NodeJS.ProcessEnv = process.env, realHome = userInfo().homedir, electronSingletons = false): Launch {
  const demo = args.includes("--demo") || env.METERUSAGE_DEMO === "1", candidateIndex = args.indexOf("--candidate-profile"), codexIndex = args.indexOf("--codex-test-profile"), claudeIndex = args.indexOf("--claude-test-profile"), codexTest = codexIndex >= 0, claudeTest = claudeIndex >= 0;
  const liveTest = codexTest || claudeTest;
  if (liveTest && (demo || candidateIndex >= 0) || codexTest && claudeTest) throw new Error("Provider test profile flags conflict with demo/candidate or another provider test mode");
  const index = codexTest ? codexIndex : claudeTest ? claudeIndex : candidateIndex, profile = index < 0 ? undefined : args[index + 1];
  if (index >= 0 && ((!liveTest && !demo) || !profile || !isAbsolute(profile))) throw new Error("Candidate profile requires an absolute test directory and --demo unless using --codex-test-profile or --claude-test-profile");
  if (profile) {
    const normalized = resolve(profile), liveData = applicationData(realHome, process.platform, env);
    const inside = relative(liveData, normalized);
    if (normalized === parse(normalized).root || normalized === realHome || inside === "" || (!isAbsolute(inside) && inside !== ".." && !inside.startsWith(`..${sep}`))) throw new Error("Candidate profile cannot use installed-app storage");
    let ancestor = normalized;
    while (!existsSync(ancestor)) ancestor = dirname(ancestor);
    if (realpathSync(ancestor) !== ancestor) throw new Error("Candidate profile cannot follow a symlink");
    mkdirSync(normalized, { recursive: true, mode: 0o700 });
    const marker = join(normalized, codexTest ? ".meterusage-codex-test" : claudeTest ? ".meterusage-claude-test" : ".meterusage-candidate");
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
    if (!existsSync(marker)) writeFileSync(marker, liveTest ? `MeterUsage ${codexTest ? "Codex" : "Claude"} test profile\n` : "Synthetic MeterUsage candidate profile\n", { mode: 0o600 });
  }
  // Demo always isolates preferences, provider sources, caches and Electron's
  // userData before any provider or coordinator is constructed.
  const isolated = liveTest ? resolve(profile!) : demo ? profile ?? mkdtempSync(join(tmpdir(), "meterusage-demo-")) : undefined;
  return { demo, candidate: index >= 0, ...(process.platform === "win32" ? { platform: "win32" as const } : {}), ...(codexTest ? { codexTest: true } : {}), ...(claudeTest ? { claudeTest: true } : {}), home: demo ? isolated! : realHome, data: isolated ?? applicationData(realHome, process.platform, env), profile: isolated, env: liveTest ? { PATH: env.PATH, TMPDIR: env.TMPDIR, ...(process.platform === "win32" ? Object.fromEntries(Object.entries(env).filter(([key]) => ["systemroot", "comspec", "userprofile", "localappdata", "appdata", "pathext", "temp", "tmp"].includes(key.toLowerCase()))) : {}) } : demo ? {} : { ...env } };
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
