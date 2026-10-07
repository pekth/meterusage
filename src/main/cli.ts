import { launchConfiguration } from "./launch";
import { Preferences } from "./preferences";
import { compose, type Source } from "./composition";
import { limitsReport, canonicalJSON } from "../domain/report";
import { type Loaded, type Quota, slotKey, value, missing, lastBurn } from "../domain/models";
export async function jsonReport(sources: Source[], now = Date.now()): Promise<ReturnType<typeof limitsReport>> {
  const quotas: Record<string, Loaded<Quota>> = Object.create(null), burns: Record<string, number> = Object.create(null);
  await Promise.all(sources.map(async source => {
    const key = slotKey(source.slot), controller = new AbortController(), timeout = setTimeout(() => controller.abort(), 30000);
    const aborted = new Promise<never>((_resolve, reject) => controller.signal.addEventListener("abort", () => reject(new Error("Source timeout")), { once: true }));
    try {
      await Promise.all([
        source.quota ? Promise.race([source.quota(controller.signal), aborted]).then(q => { quotas[key] = value(q); }, e => { quotas[key] = missing(e, source.slot.provider); }) : Promise.resolve(),
        source.activity ? Promise.race([source.activity(controller.signal), aborted]).then(a => { const at = lastBurn(a.sessions); if (at !== undefined) burns[key] = at; }, () => {}) : Promise.resolve(),
      ]);
    } finally { clearTimeout(timeout); }
  }));
  return limitsReport(sources.filter(s => s.quota).map(s => s.slot), quotas, burns, now);
}
export async function runJSON(args: string[], env: NodeJS.ProcessEnv = process.env): Promise<string> {
  const launch = launchConfiguration(args, env), preferences = await Preferences.load(launch);
  return canonicalJSON(await jsonReport(compose(launch, preferences)));
}
// Bundled CLI entry. Importing this module for fixtures never launches it.
if (process.argv[1]?.endsWith("cli.cjs")) {
  if (!process.argv.slice(2).some(a => a === "json" || a === "--json")) { process.stderr.write("Usage: meterusage json [--force] [--demo] [--candidate-profile DIR]\n"); process.exitCode = 1; }
  else runJSON(process.argv.slice(2)).then(json => process.stdout.write(json + "\n"), () => { process.stderr.write("meterusage: could not read report\n"); process.exitCode = 1; });
}
