import { validClaudeIdentity } from "./providers/claude-desktop";
import { readFileSync, existsSync, statSync } from "node:fs";
import { join, isAbsolute, resolve } from "node:path";
import { type Quota, type AccountActivity, type Activity, type Usage, type ServiceStatus, type Slot, type ManagedAccount, primary, accountSlot, Unavailable, failed } from "../domain/models";
import { selectJSON } from "./select-json";
import { type Launch } from "./launch";
import { Preferences } from "./preferences";
import { ClaudeActivitySource, scanCodex } from "./providers/activity";
import { parseCodex, parseClaudeQuota, parseClaudePlan, parseLocalQuota, parseOpenRouter, parseOpenCode, parseGrok, parseStatus, object, text } from "./providers/parsers";
import { cliPath, cliEnvironment, codexRPC, runCommand, httpTransport, endpoints, type Command, type HTTP } from "./providers/transport";
import { AntigravityRuntime, runtimeCandidates } from "./providers/antigravity";
import { scanGrok, openRouterUsage, openCodeUsage, parseOpenCodeRows, openCodeQuery } from "./providers/usage";
import { demoSources } from "./demo";
import { museCodeQuota, museCodeRPC } from "./providers/muse-code";
import type { DesktopConnections } from "./connections";
export interface Source {
  accountBound?: boolean;
  accountActivity?: (signal?: AbortSignal) => Promise<AccountActivity>;
  slot: Slot;
  quota?: (signal?: AbortSignal) => Promise<Quota>;
  activity?: (signal?: AbortSignal) => Promise<Activity>;
  usage?: (signal?: AbortSignal) => Promise<Usage>;
  plan?: (signal?: AbortSignal) => Promise<string>;
  status?: (signal?: AbortSignal) => Promise<ServiceStatus>;
  consumeReset?: (id: string, signal?: AbortSignal) => Promise<boolean>;
}
export function accountHome(account: ManagedAccount, home: string): string | undefined {
  const raw = account.path.trim(); if (!raw) return;
  const path = raw === "~" ? home : raw.startsWith("~/") ? join(home, raw.slice(2)) : resolve(raw);
  try { return statSync(path).isDirectory() ? path : undefined; } catch { return; }
}
function read(path: string): string | undefined { try { return readFileSync(path, "utf8"); } catch { return; } }
function firstFile(paths: string[]): string | undefined { const path = paths.find(existsSync); return path && read(path); }
export function openRouterKey(launch: Launch, management = false): string | undefined {
  if (launch.demo) throw new Error("Live key discovery is disabled in demo mode");
  const keyName = management ? "OPENROUTER_MANAGEMENT_KEY" : "OPENROUTER_API_KEY", filename = management ? "management-key" : "api-key";
  const key = text(launch.env[keyName]) ?? [`.cli-proxy-api/openrouter-${filename}`, `.openrouter/${filename}`, `.config/openrouter/${filename}`].map(p => text(read(join(launch.home, p)))).find(Boolean);
  return key ?? (management ? openRouterKey(launch) : undefined);
}
function grokToken(launch: Launch): string | undefined {
  const raw = read(join(launch.home, ".grok/auth.json")); if (!raw) return;
  try { const root = object(selectJSON(raw, { '*': { key: true } })); for (const [scope, value] of Object.entries(root)) if (scope.includes("auth.x.ai")) return text(object(value).key); } catch { return; }
}
function openCodeKey(launch: Launch): string | undefined {
  const raw = read(join(launch.home, ".local/share/opencode/auth.json")); if (!raw) return;
  try { return text(object(object(selectJSON(raw, { "opencode-go": { key: true } }))["opencode-go"]).key); } catch { return; }
}
export function compose(launch: Launch, prefs: Preferences, options: { command?: Command; http?: HTTP; now?: () => number; connections?: DesktopConnections } = {}): Source[] {
  const now = options.now ?? Date.now;
  if (launch.claudeTest) return [{ slot: primary("claude"), accountBound: true, quota: signal => options.connections ? options.connections.quota("claude", signal) : Promise.reject(new Unavailable("notSignedIn", "claude")) }];
  const http = options.http ?? httpTransport();
  const connectedCodex = (): Source => {
    const profile = String(prefs.values.desktopCodexConnection), connections = options.connections;
    return { slot: primary("codex"), accountBound: true,
      accountActivity: signal => connections ? connections.accountActivity(signal, profile) : Promise.reject(new Unavailable("notSignedIn", "codex")),
      quota: signal => connections ? connections.quota("codex", signal, profile) : Promise.reject(new Unavailable("notSignedIn", "codex")),
      ...(connections?.enabled("codex") ? { consumeReset: (id: string, signal?: AbortSignal) => connections.consumeReset(profile, id, signal) } : {}),
    };
  };
  if (launch.codexTest) return [{ ...connectedCodex(), status: async signal => parseStatus("codex", await http(endpoints.codexStatus, "codex", undefined, signal), now()) }];
  if (launch.demo) return demoSources(now, prefs.accounts);
  const command = options.command ?? runCommand, env = cliEnvironment(launch.home, launch.env);
  const runtime = new AntigravityRuntime(runtimeCandidates(env), command, env);
  const makeCodex = (slot: Slot, home?: string): Source => {
    const rpc = (signal?: AbortSignal, id?: string) => codexRPC(cliPath("codex", launch.home, env), { env: { ...env, ...(home ? { CODEX_HOME: home } : {}) }, signal }, id);
    return { slot, quota: async signal => parseCodex(await rpc(signal), now()), activity: async signal => scanCodex(join(home ?? join(launch.home, ".codex"), "sessions"), now(), signal), consumeReset: async (id, signal) => {
      if (!id || id.length > 200) throw failed("codex");
      const raw = await rpc(signal, id), root = object(selectJSON(raw, { result: { outcome: true }, error: { code: true, message: true } }));
      if (root.error) { parseCodex(raw, now()); throw failed("codex"); }
      return object(root.result).outcome === "reset";
    } };
  };
  const makeClaude = (slot: Slot, home: string, alternate = false): Source => {
    const activity = new ClaudeActivitySource(join(home, "projects"), join(launch.data, alternate ? `claude-local-scan-cache-${slot.slotID}.json` : "claude-local-scan-cache.json"));
    return { slot, quota: async () => {
      const paths = alternate ? [join(home, "meterusage-usage.json"), join(home, "claudewatch-usage.json")] : [join(launch.data, "claude-usage.json"), join(home, "claudewatch-usage.json"), join(home, "meterusage-usage.json")];
      const path = paths.find(existsSync), raw = path && read(path); if (!raw) throw new Unavailable("noData");
      let capturedAt = now(); try { capturedAt = statSync(path!).mtimeMs; } catch { /* Swift falls back to polling time only when file metadata is unavailable. */ }
      try { return parseClaudeQuota(raw, capturedAt); } catch { throw new Unavailable("noData"); }
    }, activity: async signal => activity.scan(now(), signal), plan: async () => { const raw = read(alternate ? join(home, ".claude.json") : join(launch.home, ".claude.json")); if (!raw) throw new Unavailable("noData"); try { return parseClaudePlan(raw); } catch { throw new Unavailable("noData"); } } };
  };
  const codex = prefs.values.desktopCodexConnection !== "" ? connectedCodex() : makeCodex(primary("codex")), claude = makeClaude(primary("claude"), join(launch.home, ".claude"));
  if (prefs.values.desktopClaudeIdentity !== "") {
    claude.accountBound = true;
    claude.quota = signal => validClaudeIdentity(prefs.values.desktopClaudeIdentity) && options.connections ? options.connections.quota("claude", signal) : Promise.reject(new Unavailable("notSignedIn", "claude"));
    // Local CLI activity cannot be attributed to a separately connected account.
    delete claude.activity; delete claude.plan;
  }
  codex.status = async signal => parseStatus("codex", await http(endpoints.codexStatus, "codex", undefined, signal), now());
  if (prefs.values.desktopClaudeIdentity === "" || prefs.values.desktopClaudeIdentity === "off" || validClaudeIdentity(prefs.values.desktopClaudeIdentity)) claude.status = async signal => parseStatus("claude", await http(endpoints.claudeStatus, "claude", undefined, signal), now());
  const antigravityIdentity = String(prefs.values.desktopAntigravityIdentity);
  const antigravity: Source = antigravityIdentity !== "" ? {
    slot: primary("antigravity"), accountBound: true,
    quota: signal => options.connections ? options.connections.quota("antigravity", signal, antigravityIdentity) : Promise.reject(new Unavailable("notSignedIn", "Antigravity Desktop")),
  } : { slot: primary("antigravity"), quota: signal => runtime.quota(now(), signal), usage: signal => runtime.usage(join(launch.home, ".gemini/antigravity-cli"), now(), signal) };
  const grokIdentity = String(prefs.values.desktopGrokIdentity);
  const muse: Source[] = prefs.enabled("muse") ? [{
    slot: primary("muse"), accountBound: true, quota: async signal => museCodeQuota(await museCodeRPC(cliPath("muse", launch.home, env), { env, signal }), now()),
  }] : [];
  const sources: Source[] = [codex, ...muse, {
    slot: primary("openRouter"), quota: async signal => {
      const key = openRouterKey(launch); if (!key) throw new Unavailable("dataNotFound", "OpenRouter API key");
      // Start the optional deadline with the required request, inside its 30s budget.
      const controller = new AbortController(), creditsSignal = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
      const timeout = setTimeout(() => controller.abort(), 5000);
      const aborted = new Promise<undefined>(resolve => { if (creditsSignal.aborted) resolve(undefined); else creditsSignal.addEventListener("abort", () => resolve(undefined), { once: true }); });
      try {
        const [raw, supplement] = await Promise.all([http(endpoints.openRouterKey, "openRouter", key, signal), Promise.race([http(endpoints.openRouterCredits, "openRouter", key, creditsSignal).catch(() => undefined), aborted])]);
        return parseOpenRouter(raw, supplement, now());
      } finally { clearTimeout(timeout); controller.abort(); }
    },
    usage: async signal => { const key = openRouterKey(launch, true); if (!key) throw new Unavailable("dataNotFound", "OpenRouter Management Key"); return openRouterUsage(await http(endpoints.openRouterActivity, "openRouter", key, signal), now()); },
  }, {
    slot: primary("openCodeGo"), quota: async signal => { const key = openCodeKey(launch); if (!key) throw new Unavailable("dataNotFound", "OpenCode Go API key"); return parseOpenCode(await http(endpoints.openCodeGo, "openCodeGo", key, signal), now()); },
    usage: async signal => {
      const path = join(launch.home, ".local/share/opencode/opencode.db");
      if (existsSync(path)) { try { const { DatabaseSync } = await import("node:sqlite"), db = new DatabaseSync(path, { readOnly: true }); try { const rows = parseOpenCodeRows(JSON.stringify(db.prepare(openCodeQuery).all())); if (rows.length) return openCodeUsage(rows, now()); } finally { db.close(); } } catch { /* The supported CLI is the existing fallback. */ } }
      return openCodeUsage(parseOpenCodeRows(await command(cliPath("opencode", launch.home, env), ["db", "--format", "json", openCodeQuery], { env, signal })), now());
    },
  }, antigravity, grokIdentity !== "" ? {
    slot: primary("grok"), accountBound: true,
    quota: signal => options.connections ? options.connections.quota("grok", signal, grokIdentity) : Promise.reject(new Unavailable("notSignedIn", "Grok Bot")),
  } : {
    slot: primary("grok"), quota: async signal => { const key = grokToken(launch); if (!key) throw new Unavailable("dataNotFound", "Grok credentials"); return parseGrok(await http(endpoints.grok, "grok", key, signal), now()); }, usage: async signal => { const configured = text(env.GROK_HOME), root = configured ? isAbsolute(configured) ? configured : join(launch.home, configured) : join(launch.home, ".grok"); return scanGrok(join(root, "sessions"), now(), signal); },
  }, claude];
  for (const p of ["cursor", "copilot", "gemini"] as const) {
    const root = join(launch.home, `.${p}`), fallback = p === "cursor" ? join(launch.home, "Library/Application Support/Cursor") : join(launch.home, `.config/${p === "copilot" ? "github-copilot" : "gemini"}`);
    sources.push({ slot: primary(p), quota: async () => {
      const raw = firstFile([join(root, "quota.json"), join(root, "usage.json"), join(fallback, "quota.json")]);
      if (raw) { try { return parseLocalQuota(p, raw, now()); } catch { /* Match the local presence classification. */ } }
      const present = p === "cursor" ? existsSync(root) || existsSync(fallback) : p === "copilot" ? existsSync(join(root, "config.json")) || existsSync(join(fallback, "hosts.json")) : existsSync(join(root, "google_accounts.json")) || existsSync(join(root, "oauth_creds.json"));
      throw present ? new Unavailable("dataNotFound", `${p === "cursor" ? "Cursor" : p === "copilot" ? "Copilot" : "Gemini"} credentials`) : new Unavailable("cliNotFound", p === "cursor" ? "Cursor" : p === "copilot" ? "Copilot CLI" : "Gemini CLI");
    } });
  }
  for (const account of prefs.accounts.filter(a => a.enabled)) {
    const home = accountHome(account, launch.home); if (!home) continue;
    sources.push(account.provider === "codex" ? makeCodex(accountSlot(account), home) : makeClaude(accountSlot(account), home, true));
  }
  return sources;
}
