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
  const paths = ["/opt/homebrew/bin", "/usr/local/bin", join(home, ".cargo/bin"), join(home, ".local/bin"), ...(env.PATH ?? "/usr/bin:/bin").split(":")];
  for (const dir of paths) { const path = join(dir, name); try { accessSync(path, constants.X_OK); return path; } catch { /* Probe common GUI install paths. */ } }
  throw new Unavailable("cliNotFound", name);
}
export function cliEnvironment(home: string, env: NodeJS.ProcessEnv): NodeJS.ProcessEnv {
  return { ...env, PATH: ["/opt/homebrew/bin", "/usr/local/bin", join(home, ".cargo/bin"), join(home, ".local/bin"), env.PATH ?? "/usr/bin:/bin"].join(":") };
}
// Provider stderr may contain credentials or paths. Drain it, but never retain
// or propagate it. All failures crossing this boundary use fixed messages.
function boundedChild(binary: string, args: string[], options: CommandOptions, exchange: (child: ChildProcessWithoutNullStreams, finish: (result: string | Error) => void) => void): Promise<string> {
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
export const runCommand: Command = (binary, args, options = {}) => boundedChild(binary, args, options, (child, finish) => {
  const chunks: Buffer[] = [];
  let ended = false, exitCode: number | null | undefined;
  const complete = () => { if (ended && exitCode !== undefined) finish(exitCode === 0 ? Buffer.concat(chunks).toString("utf8") : new Error("Provider command failed")); };
  child.stdout.on("data", (chunk: Buffer) => chunks.push(chunk));
  child.stdout.on("end", () => { ended = true; complete(); });
  child.on("exit", code => { exitCode = code; complete(); });
  child.stdin.end();
});
export async function codexRPC(binary: string, options: CommandOptions, creditID?: string): Promise<string> {
  return boundedChild(binary, ["app-server", "--stdio"], options, (child, finish) => {
    const write = (v: unknown) => child.stdin.write(JSON.stringify(v) + "\n");
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
          write({ jsonrpc: "2.0", method: "initialized", params: {} });
          write({ jsonrpc: "2.0", id: 2, method: creditID === undefined ? "account/rateLimits/read" : "account/rateLimitResetCredit/consume", params: creditID === undefined ? {} : { creditId: creditID, idempotencyKey: randomUUID() } });
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
  codexStatus: "https://status.openai.com/api/v2/components.json",
  claudeStatus: "https://status.claude.com/api/v2/components.json",
} as const;
export type Endpoint = typeof endpoints[keyof typeof endpoints];
export type HTTP = (url: Endpoint, provider: Provider, key?: string, signal?: AbortSignal) => Promise<string>;
export function httpTransport(fetcher: typeof fetch = fetch): HTTP {
  return async (url, provider, key, signal) => {
    if (!(Object.values(endpoints) as string[]).includes(url)) throw failed(provider);
    const boundedSignal = signal ? AbortSignal.any([signal, AbortSignal.timeout(30000)]) : AbortSignal.timeout(30000);
    try {
      const response = await fetcher(url, { signal: boundedSignal, redirect: "error", cache: "no-store", headers: { Accept: "application/json", "User-Agent": "meterusage/0.2.41", ...(key ? { Authorization: `Bearer ${key}` } : {}) } });
      if (response.status === 401) throw new Unavailable("notSignedIn", provider === "openCodeGo" ? "OpenCode Go" : provider === "openRouter" ? "OpenRouter" : "Grok");
      if (response.status === 403 && url === endpoints.openRouterActivity) throw new Unavailable("dataNotFound", "OpenRouter Management Key");
      if (!response.ok || !response.body) throw failed(provider);
      const reader = response.body.getReader(), chunks: Uint8Array[] = []; let size = 0;
      try {
        while (true) { const part = await reader.read(); if (part.done) break; size += part.value.length; if (size > 16 * 1048576) throw failed(provider); chunks.push(part.value); }
      } finally { await reader.cancel(); }
      return Buffer.concat(chunks).toString("utf8");
    } catch (error) {
      if (error instanceof Unavailable) throw error;
      const code = object(object(error).cause).code;
      if (["ENOTFOUND", "ENETUNREACH", "ECONNRESET", "EHOSTUNREACH"].includes(String(code))) throw new Unavailable("offline");
      throw failed(provider);
    }
  };
}
