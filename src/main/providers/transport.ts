import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { constants, accessSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import { Unavailable, failed, type Provider } from "../../domain/models";
import { selectJSON } from "../select-json";
import { object } from "./parsers";

export interface CommandOptions { env?: NodeJS.ProcessEnv; signal?: AbortSignal; timeoutMs?: number; maxBytes?: number }
export type Command = (binary: string, args: string[], options?: CommandOptions) => Promise<string>;
export function cliPath(name: string, home: string, env: NodeJS.ProcessEnv): string {
  const paths = ["/opt/homebrew/bin", "/usr/local/bin", join(home, ".cargo/bin"), ...(name === "opencode" ? [join(home, ".bun/bin")] : []), join(home, ".local/bin"), ...(env.PATH ?? "/usr/bin:/bin").split(":")];
  for (const dir of paths) { const path = join(dir, name); try { accessSync(path, constants.X_OK); return path; } catch { /* Probe common GUI install paths. */ } }
  throw new Unavailable("cliNotFound", name);
}
export function cliEnvironment(home: string, env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ...env, PATH: ["/opt/homebrew/bin", "/usr/local/bin", join(home, ".cargo/bin"), join(home, ".local/bin"), env.PATH ?? "/usr/bin:/bin"].join(":") };
}
// Provider stderr may contain credentials or paths. Drain it, but never retain
// or propagate it. All failures crossing this boundary use fixed messages.
export function boundedChild(binary: string, args: string[], options: CommandOptions, exchange: (child: ChildProcessWithoutNullStreams, finish: (result: string | Error) => void) => void): Promise<string> {
  return new Promise((resolve, reject) => {
    if (options.signal?.aborted) { reject(new Error("Provider request cancelled")); return; }
    const child = spawn(binary, args, { env: options.env, stdio: "pipe", shell: false });
    let outcome: string | Error | undefined, killTimer: ReturnType<typeof setTimeout> | undefined, bytes = 0;
    const stop = () => { if (child.exitCode === null) { child.kill("SIGTERM"); killTimer ??= setTimeout(() => child.kill("SIGKILL"), 250); } };
    const finish = (result: string | Error) => { if (outcome !== undefined) return; outcome = result; stop(); };
    const timer = setTimeout(() => finish(new Error("Provider request timed out")), options.timeoutMs ?? 20000);
    const abort = () => finish(new Error("Provider request cancelled"));
    options.signal?.addEventListener("abort", abort, { once: true });
    child.stderr.resume();
    child.stdout.on("data", (data: Buffer) => { bytes += data.length; if (bytes > (options.maxBytes ?? 16 * 1048576)) finish(new Error("Provider output exceeded limit")); });
    child.stdin.on("error", () => finish(new Error("Provider input closed")));
    child.on("error", () => finish(new Error("Provider process unavailable")));
    child.on("close", () => {
      clearTimeout(timer); if (killTimer) clearTimeout(killTimer); options.signal?.removeEventListener("abort", abort);
      const result = outcome ?? new Error("Provider process exited");
      if (result instanceof Error) reject(result); else resolve(result);
    });
    exchange(child, finish);
  });
}
export class CommandFailure extends Error { constructor(readonly exitCode: number | null) { super("Provider command failed"); } }
export const runCommand: Command = (binary, args, options = {}) => boundedChild(binary, args, options, (child, finish) => {
  const chunks: Buffer[] = [];
  let ended = false, exitCode: number | null | undefined;
  const complete = () => { if (ended && exitCode !== undefined) finish(exitCode === 0 ? Buffer.concat(chunks).toString("utf8") : new CommandFailure(exitCode)); };
  let capturedBytes = 0;
  child.stdout.on("data", (chunk: Buffer) => { capturedBytes += chunk.length; if (capturedBytes <= (options.maxBytes ?? 16 * 1048576)) chunks.push(chunk); });
  child.stdout.on("end", () => { ended = true; complete(); });
  child.on("exit", code => { exitCode = code; complete(); });
  child.stdin.end();
});
export async function codexRPC(binary: string, options: CommandOptions, creditID?: string, configuration: string[] = [], operation: "read" | "logout" | "usage" = "read"): Promise<string> {
  return boundedChild(binary, [...configuration, "app-server", "--listen", "stdio://"], options, (child, finish) => {
    const write = (v: unknown) => child.stdin.write(JSON.stringify(v) + "\n");
    const request = () => write({ jsonrpc: "2.0", id: 2, method: operation === "logout" ? "account/logout" : operation === "usage" ? "account/usage/read" : creditID === undefined ? "account/rateLimits/read" : "account/rateLimitResetCredit/consume", params: creditID === undefined ? {} : { creditId: creditID, idempotencyKey: randomUUID() } });
    let pending = "", initialized = false;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      pending += chunk;
      let newline: number;
      while ((newline = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
        let id: unknown; try { id = object(selectJSON(line, { id: true })).id; } catch { continue; }
        if (id === 1 && !initialized) {
          initialized = true;
          if (object(selectJSON(line, { error: { code: true } })).error) { finish(new Error("Provider initialization failed")); return; }
          write({ jsonrpc: "2.0", method: "initialized", params: {} });
          if (configuration.length) write({ id: 4, method: "config/read", params: { includeLayers: false } }); else request();
        } else if (id === 4 && initialized && configuration.length) {
          try {
            const result = object(selectJSON(line, { result: { config: { cli_auth_credentials_store: true } } }));
            if (object(object(result.result).config).cli_auth_credentials_store !== "keyring") throw new Error();
            request();
          } catch { finish(new Error("Secure credential storage unavailable")); }
        } else if (id === 2 && initialized) finish(line);
      }
    });
    write({ jsonrpc: "2.0", id: 1, method: "initialize", params: { clientInfo: { name: "meterusage", version: "0.2.41" }, capabilities: { experimentalApi: true } } });
  });
}
export const endpoints = {
  openRouterKey: "https://openrouter.ai/api/v1/key",
  openRouterCredits: "https://openrouter.ai/api/v1/credits",
  openRouterActivity: "https://openrouter.ai/api/v1/activity",
  openCodeGo: "https://opencode.ai/zen/go/v1/usage",
  grok: "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
  claudeBootstrap: "https://claude.ai/api/bootstrap",
  cursorIdentity: "https://cursor.com/api/auth/me",
  cursorGrok: "https://cursor.com/api/dashboard/get-sand-usage-status",
  codexStatus: "https://status.openai.com/api/v2/components.json",
  claudeStatus: "https://status.claude.com/api/v2/components.json",
} as const;
const claudeUsagePattern = /^https:\/\/claude\.ai\/api\/organizations\/[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}\/usage$/;
export const isClaudeEndpoint = (url: string): boolean => url === endpoints.claudeBootstrap || claudeUsagePattern.test(url);
export function claudeUsageURL(organization: string): `https://claude.ai/api/organizations/${string}/usage` {
  const url = `https://claude.ai/api/organizations/${organization}/usage` as const;
  if (!claudeUsagePattern.test(url)) throw new Unavailable("notSignedIn", "Claude Desktop");
  return url;
}
export type Endpoint = typeof endpoints[keyof typeof endpoints] | ReturnType<typeof claudeUsageURL>;
export type HTTP = (url: Endpoint, provider: Provider, key?: string, signal?: AbortSignal) => Promise<string>;
export class ClaudeBrowserVerification extends Unavailable {
  constructor() { super("notSignedIn", "Claude Desktop"); }
}
export function httpTransport(fetcher: typeof fetch = fetch): HTTP {
  return async (url, provider, key, signal) => {
    if (!(Object.values(endpoints) as string[]).includes(url) && !claudeUsagePattern.test(url)) throw failed(provider);
    const controller = new AbortController();
    const boundedSignal = AbortSignal.any([controller.signal, ...(signal ? [signal] : []), AbortSignal.timeout(30000)]);
    let response: Response | undefined;
    let reader: ReadableStreamDefaultReader<Uint8Array> | undefined;
    try {
      boundedSignal.throwIfAborted();
      const claude = isClaudeEndpoint(url);
      if (claude && (provider !== "claude" || !key || !/^sessionKey=[A-Za-z0-9._~-]{1,16384}$/.test(key)) || !claude && key?.startsWith("sessionKey=")) throw new Unavailable("notSignedIn", "Claude Desktop");
      const cursor = url === endpoints.cursorIdentity || url === endpoints.cursorGrok;
      if (cursor && (provider !== "grok" || !key || key.length > 17000 || !/^WorkosCursorSessionToken=[A-Za-z0-9._-]+%3A%3A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/.test(key))) throw new Unavailable("notSignedIn", "Grok Bot via Cursor");
      response = await fetcher(url, { signal: boundedSignal, redirect: "error", cache: "no-store", ...(url === endpoints.cursorGrok ? { method: "POST", body: "{}" } : {}), headers: { Accept: "application/json", "User-Agent": "meterusage/0.2.41", ...(url === endpoints.cursorGrok ? { "Content-Type": "application/json", Origin: "https://cursor.com" } : {}), ...(key ? cursor || claude ? { Cookie: key } : { Authorization: `Bearer ${key}` } : {}) } });
      boundedSignal.throwIfAborted();
      if (claude && response.status === 403 && response.headers.get("cf-mitigated") === "challenge") throw new ClaudeBrowserVerification();
      if (cursor && response.status === 403) throw new Unavailable("notSignedIn", "Grok Bot via Cursor");
      if (response.status === 401 || response.status === 403 && claude) throw new Unavailable("notSignedIn", provider === "claude" ? "Claude Desktop" : provider === "openCodeGo" ? "OpenCode Go" : provider === "openRouter" ? "OpenRouter" : "Grok");
      if (response.status === 403 && url === endpoints.openRouterActivity) throw new Unavailable("dataNotFound", "OpenRouter Management Key");
      if (!response.ok || !response.body) throw failed(provider);
      reader = response.body.getReader();
      const chunks: Uint8Array[] = []; let size = 0;
      while (true) { const part = await reader.read(); if (part.done) break; size += part.value.length; if (size > (cursor || claude ? 1048576 : 16 * 1048576)) throw failed(provider); chunks.push(part.value); }
      boundedSignal.throwIfAborted();
      return Buffer.concat(chunks).toString("utf8");
    } catch (error) {
      controller.abort();
      if (error instanceof Unavailable) throw error;
      const code = object(object(error).cause).code;
      if (["ENOTFOUND", "ENETUNREACH", "ECONNRESET", "EHOSTUNREACH"].includes(String(code))) throw new Unavailable("offline");
      throw failed(provider);
    } finally {
      if (reader) await reader.cancel().catch(() => {});
      else if (response?.body && !response.body.locked) await response.body.cancel().catch(() => {});
    }
  };
}
