import { userInfo, tmpdir } from "node:os";
import { mkdtempSync, mkdirSync, realpathSync, existsSync, readdirSync, writeFileSync } from "node:fs";
import { isAbsolute, join, resolve, relative } from "node:path";
export interface Launch { demo: boolean; candidate: boolean; home: string; data: string; env: NodeJS.ProcessEnv; profile?: string }
export function launchConfiguration(args: string[], env: NodeJS.ProcessEnv = process.env, realHome = userInfo().homedir): Launch {
  const demo = args.includes("--demo") || env.METERUSAGE_DEMO === "1", index = args.indexOf("--candidate-profile"), profile = index < 0 ? undefined : args[index + 1];
  if (index >= 0 && (!demo || !profile || !isAbsolute(profile))) throw new Error("Candidate profile requires --demo and an absolute test directory");
  if (profile) {
    const normalized = resolve(profile), liveData = join(realHome, "Library/Application Support/MeterUsage");
    const inside = relative(liveData, normalized);
    if (normalized === "/" || normalized === realHome || inside === "" || (inside !== ".." && !inside.startsWith("../"))) throw new Error("Candidate profile cannot use installed-app storage");
    mkdirSync(normalized, { recursive: true });
    if (realpathSync(normalized) !== normalized) throw new Error("Candidate profile cannot follow a symlink");
    const marker = join(normalized, ".meterusage-candidate");
    if (!existsSync(marker) && readdirSync(normalized).length) throw new Error("Candidate profile must be an empty test directory");
    if (!existsSync(marker)) writeFileSync(marker, "Synthetic MeterUsage candidate profile\n", { mode: 0o600 });
  }
  // Demo always isolates preferences, provider sources, caches and Electron's
  // userData before any provider or coordinator is constructed.
  const isolated = demo ? profile ?? mkdtempSync(join(tmpdir(), "meterusage-demo-")) : undefined;
  return { demo, candidate: index >= 0, home: isolated ?? realHome, data: isolated ?? join(realHome, "Library/Application Support/MeterUsage"), profile: isolated, env: demo ? {} : { ...env } };
}
