import { userInfo } from "node:os";
import { collectApiBilling, writeApiBilling } from "./providers/api-billing";

export async function runApiUsageHelper(args: string[], env: NodeJS.ProcessEnv = process.env, home = userInfo().homedir, fetcher: typeof fetch = fetch) {
  const provider = args[0];
  if (args.length !== 1 || provider !== "openai" && provider !== "anthropic") throw new Error("Usage: api-usage-helper openai|anthropic");
  const name = provider === "openai" ? "OPENAI_ADMIN_KEY" : "ANTHROPIC_ADMIN_KEY", key = env[name];
  // The one-run helper owns the key; MeterUsage reads only the projected file.
  delete env[name];
  if (!key) throw new Error("API billing admin key missing from helper environment");
  const snapshot = await collectApiBilling(provider, key, Date.now(), fetcher);
  writeApiBilling(home, snapshot);
}

if (process.argv[1]?.endsWith("api-usage-helper.cjs")) {
  runApiUsageHelper(process.argv.slice(2)).then(() => process.stdout.write("API billing snapshot updated\n"), error => {
    const allowed = ["Usage: api-usage-helper openai|anthropic", "API billing admin key missing from helper environment", "API billing authentication failed"];
    process.stderr.write((error instanceof Error && allowed.includes(error.message) ? error.message : "API billing data unavailable") + "\n"); process.exitCode = 1;
  });
}
