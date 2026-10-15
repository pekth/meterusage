import { accessSync, constants, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { Launch } from "./launch";
import { Preferences } from "./preferences";
import { boundedChild, cliEnvironment, cliPath, codexRPC, endpoints, httpTransport, runCommand, type Command, type HTTP } from "./providers/transport";
import { object, parseCodex } from "./providers/parsers";
import { parseCodexAccountUsage } from "./providers/codex-account-usage";
import { desktopQuota, readDesktopCredential, desktopReadErrors } from "./providers/claude-desktop";
import { selectJSON } from "./select-json";
import { Unavailable, failed, resetCreditAvailable } from "../domain/models";
import { providerKey, type ConnectionState, type ConnectionProvider } from "../shared/ipc";

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
  private pending = new Map<ConnectionProvider, { controller: AbortController; done: Promise<void>; local: boolean }>();
  private errors = new Set<ConnectionProvider>();
  private stopped = false;
  private resetController?: AbortController;
  private stopping?: Promise<void>;
  private cleanupController = new AbortController();
  constructor(readonly launch: Launch, readonly prefs: Preferences, readonly helper: string, readonly changed: () => void, readonly command: Command = runCommand, readonly http: HTTP = httpTransport(), readonly now = Date.now) {}
  get state(): ConnectionState[] {
    return (["codex", "claude", "grok"] as const).map(provider => ({ provider, status: provider === "grok" || this.launch.codexTest && provider !== "codex" || this.launch.claudeTest && provider !== "claude" ? "unsupported" : this.pending.has(provider) ? "connecting" : this.enabled(provider) ? "connected" : this.errors.has(provider) ? "failed" : "disconnected", source: provider !== "grok" && this.configured(provider) ? "account" : "cli", localAvailable: !this.launch.demo && !this.launch.codexTest && !this.launch.claudeTest }));
  }
  enabled(provider: "codex" | "claude") { const value = this.prefs.values[provider === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity"]; return (!this.launch.codexTest || provider === "codex") && (!this.launch.claudeTest || provider === "claude") && !this.stopped && !this.pending.has(provider) && !(provider === "codex" && this.prefs.values.desktopCodexCleanup !== "") && typeof value === "string" && value !== "" && value !== "off"; }
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
  private async claude(allowUI: boolean, signal?: AbortSignal, readingCache?: (stage: keyof typeof desktopReadErrors) => void) {
    try {
      const password = await this.command(this.helper, allowUI ? ["--allow-ui"] : [], { signal, timeoutMs: allowUI ? 60000 : 5000, maxBytes: 4096 });
      return await readDesktopCredential(this.launch.home, password, this.now(), readingCache);
    } catch { throw new Unavailable("notSignedIn", "Claude Desktop"); }
  }
  private checkCodexProfile(profile: string) {
    if (this.launch.demo || !this.enabled("codex") || this.prefs.values.desktopCodexConnection !== profile) throw new Unavailable("notSignedIn", "codex");
  }
  async quota(provider: ConnectionProvider, signal?: AbortSignal, profile = String(this.prefs.values.desktopCodexConnection)) {
    if (this.launch.demo || provider === "grok" || !this.enabled(provider)) throw new Unavailable("notSignedIn", provider);
    if (provider === "codex") {
      this.checkCodexProfile(profile);
      const raw = await codexRPC(this.binary(), { env: this.env(profile), signal }, undefined, configuration);
      this.checkCodexProfile(profile); signal?.throwIfAborted();
      return parseCodex(raw, this.now());
    }
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
  async accountActivity(signal?: AbortSignal, profile = String(this.prefs.values.desktopCodexConnection)) {
    this.checkCodexProfile(profile);
    const raw = await codexRPC(this.binary(), { env: this.env(profile), signal }, undefined, configuration, "usage");
    this.checkCodexProfile(profile); signal?.throwIfAborted();
    return parseCodexAccountUsage(raw, this.now());
  }
  async consumeReset(profile: string, id: string, signal?: AbortSignal) {
    this.checkCodexProfile(profile);
    if (!id || id.length > 200 || this.resetController) throw failed("codex");
    const controller = new AbortController(); this.resetController = controller;
    const resetSignal = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
    try {
      const q = await this.quota("codex", resetSignal, profile);
      if (!q.resetCredits.some(c => c.id === id && resetCreditAvailable(c, this.now()))) throw failed("codex");
      this.checkCodexProfile(profile); resetSignal.throwIfAborted();
      const raw = await codexRPC(this.binary(), { env: this.env(profile), signal: resetSignal }, id, configuration);
      this.checkCodexProfile(profile); resetSignal.throwIfAborted();
      const root = object(selectJSON(raw, { result: { outcome: true }, error: { code: true, message: true } }));
      if (root.error) { parseCodex(raw, this.now()); throw failed("codex"); }
      return object(root.result).outcome === "reset";
    } finally { this.resetController = undefined; }
  }
  async connect(provider: ConnectionProvider, open: (url: string) => Promise<void>, consent: () => Promise<boolean> = async () => provider !== "claude") {
    if (this.stopped) throw new Error("Connection unavailable");
    if (this.launch.demo) throw new Error("Connections are disabled in demo mode");
    if (this.launch.codexTest && provider !== "codex") throw new Error("Connection unavailable in Codex test mode");
    if (this.launch.claudeTest && provider !== "claude") throw new Error("Connection unavailable in Claude test mode");
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
    let claudeError = "Open Claude Desktop and sign in, then try connecting again";
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
        claudeError = "Could not access Claude Desktop through macOS Keychain. Check the access prompt, then try connecting again.";
        const credential = await this.claude(true, controller.signal, stage => {
          claudeError = desktopReadErrors[stage];
        });
        claudeError = "Could not read Claude account allowance. Try connecting again later.";
        const q = desktopQuota(await this.http(endpoints.claudeAllowance, "claude", credential.token, controller.signal), this.now());
        if (!q.windows.length) throw new Unavailable("noData");
        claudeError = "Could not verify the same Claude Desktop account after the allowance request. Try connecting again.";
        if ((await this.claude(false, controller.signal)).identity !== credential.identity) throw new Unavailable("noData");
        claudeError = "Could not save the Claude Desktop connection preferences. Try connecting again.";
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
      if (savedIdentity && this.prefs.values.desktopClaudeIdentity === savedIdentity) {
        // Disabling clears consent in memory first; keep a failed rollback write private.
        try { await this.disable("claude"); } catch { /* Report the fixed preference-save message. */ }
      }
      this.errors.add(provider); throw new Error(provider === "codex" ? "Open Codex on this Mac, then try connecting again" : controller.signal.aborted ? "Open Claude Desktop and sign in, then try connecting again" : claudeError);
    }
    finally { finish(); }
  }
  private begin(provider: ConnectionProvider, local = false) {
    if (provider === "codex") this.resetController?.abort();
    const controller = new AbortController();
    let settle!: () => void;
    const done = new Promise<void>(resolve => { settle = resolve; });
    this.pending.set(provider, { controller, done, local }); this.errors.delete(provider); this.changed();
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
  disconnect(provider: ConnectionProvider) { return this.clearConnection(provider, false); }
  async useLocal(provider: ConnectionProvider) {
    if (this.launch.codexTest || this.launch.claudeTest) throw new Error("Connection unavailable in test mode");
    await this.clearConnection(provider, true);
  }
  private async clearConnection(provider: ConnectionProvider, local: boolean) {
    if (this.stopped) throw new Error("Connection unavailable");
    if (this.launch.demo) throw new Error("Connections are disabled in demo mode");
    if (this.launch.codexTest && provider !== "codex") throw new Error("Connection unavailable in Codex test mode");
    if (this.launch.claudeTest && provider !== "claude") throw new Error("Connection unavailable in Claude test mode");
    if (provider === "grok" && !local || this.pending.has(provider)) throw new Error("Connection unavailable");
    const wasVisible = this.prefs.values[providerKey(provider)] === true;
    const id = String(this.prefs.values.desktopCodexCleanup || this.prefs.values.desktopCodexConnection);
    const { controller, finish } = this.begin(provider, local);
    try {
      if (provider !== "grok") await this.disable(provider, provider === "codex" && id !== "" && id !== "off" ? id : undefined);
      if (provider === "codex" && id !== "" && id !== "off") await this.cleanup(id);
      if (local) {
        controller.signal.throwIfAborted();
        await this.prefs.set(providerKey(provider), true);
        controller.signal.throwIfAborted();
        if (provider !== "grok") {
          await this.prefs.set(provider === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity", "");
          controller.signal.throwIfAborted();
        }
      }
      this.errors.delete(provider);
    } catch {
      if (local && provider === "grok" && controller.signal.aborted) {
        try { await this.prefs.set(providerKey(provider), wasVisible); }
        catch { this.prefs.values[providerKey(provider)] = wasVisible; }
      }
      if (local && provider !== "grok" && !this.configured(provider)) {
        try { await this.disable(provider); } catch { /* Disabling in memory keeps a failed rollback private. */ }
      }
      this.errors.add(provider); throw new Error(provider === "codex" ? "Could not disconnect Codex" : provider === "claude" ? "Could not disconnect Claude Desktop" : "Could not select Grok CLI");
    } finally { finish(); }
  }
  async recover() {
    const id = String(this.prefs.values.desktopCodexCleanup);
    if (this.launch.demo || this.launch.claudeTest || !id) return;
    if (this.stopped || this.pending.has("codex")) throw new Error("Connection unavailable");
    const { finish } = this.begin("codex");
    try { await this.disable("codex", id); await this.cleanup(id); }
    catch { this.errors.add("codex"); throw new Error("Could not clear the cancelled Codex connection"); }
    finally { finish(); }
  }
  stop(timeoutMs = 5000): Promise<void> {
    if (this.stopping) return this.stopping;
    this.stopped = true; this.resetController?.abort();
    const pending = [...this.pending.values()];
    for (const operation of pending) operation.controller.abort();
    let timer: ReturnType<typeof setTimeout>;
    const expired = new Promise<void>(resolve => { timer = setTimeout(() => { this.cleanupController.abort(); resolve(); }, timeoutMs); });
    // The helper deadline must not cut off a queued source-selection rollback.
    this.stopping = Promise.race([Promise.all(pending.map(p => p.done)).then(() => {}), expired])
      .then(() => Promise.all(pending.filter(p => p.local).map(p => p.done))).then(() => {})
      .finally(() => clearTimeout(timer));
    return this.stopping;
  }
}
