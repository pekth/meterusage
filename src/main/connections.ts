import { accessSync, constants, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { Launch } from "./launch";
import { Preferences } from "./preferences";
import { boundedChild, cliEnvironment, cliPath, codexRPC, endpoints, httpTransport, runCommand, type Command, type HTTP } from "./providers/transport";
import { object, parseCodex } from "./providers/parsers";
import { desktopQuota, readDesktopCredential } from "./providers/claude-desktop";
import { selectJSON } from "./select-json";
import { Unavailable } from "../domain/models";
import type { ConnectionState, ConnectionProvider } from "../shared/ipc";

const configuration = ["-c", 'cli_auth_credentials_store="keyring"', "-c", 'forced_login_method="chatgpt"', "-c", 'chatgpt_base_url="https://chatgpt.com"'];
export function codexLoginURL(raw: unknown): string {
  if (typeof raw !== "string" || raw.length > 8192) throw new Error("Invalid sign-in address");
  const url = new URL(raw);
  if (url.protocol !== "https:" || !["chatgpt.com", "auth.openai.com"].includes(url.hostname) || url.username || url.password || url.port) throw new Error("Invalid sign-in address");
  return url.href;
}
export function connectCodex(binary: string, env: NodeJS.ProcessEnv, open: (url: string) => Promise<void>, signal?: AbortSignal) {
  return boundedChild(binary, [...configuration, "app-server", "--listen", "stdio://"], { env, signal, timeoutMs: 180000, maxBytes: 1048576 }, (child, finish) => {
    const write = (message: unknown) => child.stdin.write(JSON.stringify(message) + "\n");
    let pending = "", loginID: string | undefined, completion: Record<string, unknown> | undefined;
    const completed = () => {
      if (!loginID || completion?.loginId !== loginID) return;
      if (completion.success !== true) { finish(new Error("Codex sign-in failed")); return; }
      completion = undefined;
      write({ id: 3, method: "account/rateLimits/read", params: {} });
    };
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      pending += chunk;
      let newline: number;
      while ((newline = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
        try {
          const message = object(selectJSON(line, { id: true, error: { code: true }, result: { config: { cli_auth_credentials_store: true }, type: true, loginId: true, authUrl: true }, method: true, params: { loginId: true, success: true } }));
          if (message.error) { finish(new Error("Codex sign-in unavailable")); return; }
          if (message.id === 1) {
            write({ method: "initialized", params: {} });
            write({ id: 4, method: "config/read", params: { includeLayers: false } });
          } else if (message.id === 4) {
            if (object(object(message.result).config).cli_auth_credentials_store !== "keyring") throw new Error();
            write({ id: 2, method: "account/login/start", params: { type: "chatgpt" } });
          } else if (message.id === 2) {
            const result = object(message.result);
            if (result.type !== "chatgpt" || typeof result.loginId !== "string") throw new Error();
            loginID = result.loginId;
            void open(codexLoginURL(result.authUrl)).catch(() => finish(new Error("Could not open sign-in")));
            completed();
          } else if (message.method === "account/login/completed") { completion = object(message.params); completed(); }
          else if (message.id === 3) finish(line);
        } catch { finish(new Error("Codex sign-in unavailable")); return; }
      }
    });
    write({ id: 1, method: "initialize", params: { clientInfo: { name: "meterusage", version: "0.2.41" }, capabilities: { experimentalApi: true } } });
  });
}

export class DesktopConnections {
  private pending = new Map<ConnectionProvider, { controller: AbortController; done: Promise<void> }>();
  private errors = new Set<ConnectionProvider>();
  private stopped = false;
  private stopping?: Promise<void>;
  private cleanupController = new AbortController();
  constructor(readonly launch: Launch, readonly prefs: Preferences, readonly helper: string, readonly changed: () => void, readonly command: Command = runCommand, readonly http: HTTP = httpTransport(), readonly now = Date.now) {}
  get state(): ConnectionState[] {
    return (["codex", "claude", "grok"] as const).map(provider => ({ provider, status: provider === "grok" || this.launch.codexTest && provider !== "codex" ? "unsupported" : this.pending.has(provider) ? "connecting" : this.enabled(provider) ? "connected" : this.errors.has(provider) ? "failed" : "disconnected" }));
  }
  enabled(provider: "codex" | "claude") { const value = this.prefs.values[provider === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity"]; return (!this.launch.codexTest || provider === "codex") && !this.stopped && !this.pending.has(provider) && !(provider === "codex" && this.prefs.values.desktopCodexCleanup !== "") && typeof value === "string" && value !== "" && value !== "off"; }
  configured(provider: "codex" | "claude") { return this.prefs.values[provider === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity"] !== ""; }
  private binary() {
    for (const root of ["/Applications", join(this.launch.home, "Applications")]) {
      const path = join(root, "Codex.app/Contents/Resources/codex");
      try { accessSync(path, constants.X_OK); return path; } catch { /* Existing command installations remain supported. */ }
    }
    return cliPath("codex", this.launch.home, this.launch.env);
  }
  private env(id: string) {
    const home = join(this.launch.data, "connections", "codex", id);
    mkdirSync(home, { recursive: true, mode: 0o700 });
    return { HOME: this.launch.home, PATH: cliEnvironment(this.launch.home, { PATH: this.launch.env.PATH }).PATH, CODEX_HOME: home, TMPDIR: this.launch.env.TMPDIR };
  }
  private async claude(allowUI: boolean, signal?: AbortSignal) {
    try {
      const password = await this.command(this.helper, allowUI ? ["--allow-ui"] : [], { signal, timeoutMs: allowUI ? 60000 : 5000, maxBytes: 4096 });
      return await readDesktopCredential(this.launch.home, password, this.now());
    } catch { throw new Unavailable("notSignedIn", "Claude Desktop"); }
  }
  async quota(provider: ConnectionProvider, signal?: AbortSignal) {
    if (this.launch.demo || provider === "grok" || !this.enabled(provider)) throw new Unavailable("notSignedIn", provider);
    if (provider === "codex") return parseCodex(await codexRPC(this.binary(), { env: this.env(String(this.prefs.values.desktopCodexConnection)), signal }, undefined, configuration), this.now());
    const credential = await this.claude(false, signal);
    if (credential.identity !== this.prefs.values.desktopClaudeIdentity) throw new Unavailable("notSignedIn", "Claude Desktop");
    let raw: string;
    try { raw = await this.http(endpoints.claudeAllowance, "claude", credential.token, signal); }
    finally {
      // A failed request permits last-known allowance only for a verified account.
      if (this.prefs.values.desktopClaudeIdentity !== credential.identity || !this.enabled("claude")) throw new Unavailable("notSignedIn", "Claude Desktop");
      if ((await this.claude(false, signal)).identity !== credential.identity || this.prefs.values.desktopClaudeIdentity !== credential.identity || !this.enabled("claude")) throw new Unavailable("notSignedIn", "Claude Desktop");
    }
    return desktopQuota(raw, this.now());
  }
  async connect(provider: ConnectionProvider, open: (url: string) => Promise<void>, consent: () => Promise<boolean> = async () => true) {
    if (this.stopped) throw new Error("Connection unavailable");
    if (this.launch.demo) throw new Error("Connections are disabled in demo mode");
    if (this.launch.codexTest && provider !== "codex") throw new Error("Connection unavailable in Codex test mode");
    if (provider === "grok") throw new Error("Automatic Grok connection is unavailable");
    if (this.pending.has(provider) || this.enabled(provider)) throw new Error("Connection already active");
    if (provider === "codex" && this.prefs.values.desktopCodexCleanup !== "") {
      await this.recover();
      if (this.stopped) throw new Error("Connection unavailable");
      if (this.pending.has(provider) || this.enabled(provider)) throw new Error("Connection already active");
    }
    const { controller, finish } = this.begin(provider);
    let candidateID: string | undefined;
    let savedIdentity: string | undefined;
    try {
      if (!await consent()) return false;
      controller.signal.throwIfAborted();
      if (provider === "codex") {
        const binary = this.binary(), id = randomUUID();
        // An unfinished profile permits cleanup, never collection.
        await this.disable("codex");
        await this.prefs.set("desktopCodexCleanup", id); candidateID = id;
        controller.signal.throwIfAborted();
        const q = parseCodex(await connectCodex(binary, this.env(id), open, controller.signal), this.now());
        if (!q.windows.length) throw new Unavailable("noData");
        controller.signal.throwIfAborted();
      } else {
        const credential = await this.claude(true, controller.signal);
        const q = desktopQuota(await this.http(endpoints.claudeAllowance, "claude", credential.token, controller.signal), this.now());
        if (!q.windows.length || (await this.claude(false, controller.signal)).identity !== credential.identity) throw new Unavailable("noData");
        controller.signal.throwIfAborted(); savedIdentity = credential.identity; await this.prefs.set("desktopClaudeIdentity", credential.identity);
      }
      await this.prefs.set(provider === "codex" ? "showProviderCodex" : "showProviderClaude", true);
      controller.signal.throwIfAborted();
      if (candidateID) {
        await this.prefs.set("desktopCodexConnection", candidateID);
        controller.signal.throwIfAborted();
        await this.prefs.set("desktopCodexCleanup", "");
        controller.signal.throwIfAborted();
      }
      return true;
    } catch {
      if (candidateID) {
        await this.disable("codex", candidateID);
        try { await this.cleanup(candidateID); }
        catch { this.errors.add(provider); throw new Error("Could not clear the cancelled Codex connection"); }
      }
      if (savedIdentity && this.prefs.values.desktopClaudeIdentity === savedIdentity) await this.disable("claude");
      this.errors.add(provider); throw new Error(provider === "codex" ? "Open Codex on this Mac, then try connecting again" : "Open Claude Desktop and sign in, then try connecting again");
    }
    finally { finish(); }
  }
  private begin(provider: ConnectionProvider) {
    const controller = new AbortController();
    let settle!: () => void;
    const done = new Promise<void>(resolve => { settle = resolve; });
    this.pending.set(provider, { controller, done }); this.errors.delete(provider); this.changed();
    return { controller, finish: () => { this.pending.delete(provider); if (!this.stopped) this.changed(); settle(); } };
  }
  cancel(provider: ConnectionProvider) { this.pending.get(provider)?.controller.abort(); }
  private async disable(provider: "codex" | "claude", cleanupID?: string) {
    const key = provider === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity";
    this.prefs.values[key] = "off"; if (!this.stopped) this.changed();
    // Save cleanup first so a crash during the disabling write stays fail-closed.
    if (cleanupID) await this.prefs.set("desktopCodexCleanup", cleanupID);
    await this.prefs.set(key, "off");
  }
  private async cleanup(id: string) {
    await this.logout(id);
    if (this.prefs.values.desktopCodexCleanup === id) await this.prefs.set("desktopCodexCleanup", "");
  }
  private async logout(id: string) {
    const raw = await codexRPC(this.binary(), { env: this.env(id), signal: this.cleanupController.signal }, undefined, configuration, "logout");
    if (object(selectJSON(raw, { error: { code: true } })).error) throw new Error("Could not disconnect Codex");
  }
  async disconnect(provider: ConnectionProvider) {
    if (this.stopped) throw new Error("Connection unavailable");
    if (this.launch.demo) throw new Error("Connections are disabled in demo mode");
    if (this.launch.codexTest && provider !== "codex") throw new Error("Connection unavailable in Codex test mode");
    if (provider === "grok" || this.pending.has(provider)) throw new Error("Connection unavailable");
    const id = String(this.prefs.values.desktopCodexCleanup || this.prefs.values.desktopCodexConnection);
    const { finish } = this.begin(provider);
    try {
      await this.disable(provider, provider === "codex" && id !== "" && id !== "off" ? id : undefined);
      if (provider === "codex" && id !== "" && id !== "off") await this.cleanup(id);
      this.errors.delete(provider);
    } catch { this.errors.add(provider); throw new Error(provider === "codex" ? "Could not disconnect Codex" : "Could not disconnect Claude Desktop");
    } finally { finish(); }
  }
  async recover() {
    const id = String(this.prefs.values.desktopCodexCleanup);
    if (this.launch.demo || !id) return;
    if (this.stopped || this.pending.has("codex")) throw new Error("Connection unavailable");
    const { finish } = this.begin("codex");
    try { await this.disable("codex", id); await this.cleanup(id); }
    catch { this.errors.add("codex"); throw new Error("Could not clear the cancelled Codex connection"); }
    finally { finish(); }
  }
  stop(timeoutMs = 5000): Promise<void> {
    if (this.stopping) return this.stopping;
    this.stopped = true;
    for (const pending of this.pending.values()) pending.controller.abort();
    let timer: ReturnType<typeof setTimeout>;
    const expired = new Promise<void>(resolve => { timer = setTimeout(() => { this.cleanupController.abort(); resolve(); }, timeoutMs); });
    this.stopping = Promise.race([Promise.all([...this.pending.values()].map(p => p.done)).then(() => {}), expired]).finally(() => clearTimeout(timer));
    return this.stopping;
  }
}
