import { accessSync, constants, mkdirSync } from "node:fs";
import { join } from "node:path";
import { randomUUID } from "node:crypto";
import type { Launch } from "./launch";
import { Preferences } from "./preferences";
import { ClaudeBrowserVerification, boundedChild, cliEnvironment, cliPath, codexRPC, endpoints, claudeUsageURL, httpTransport, runCommand, type Command, type HTTP } from "./providers/transport";
import { object, parseCodex } from "./providers/parsers";
import { parseCodexAccountUsage } from "./providers/codex-account-usage";
import { desktopQuota, readDesktopCredential, desktopReadErrors, validClaudeIdentity, verifyDesktopAccount } from "./providers/claude-desktop";
import { readAntigravityDesktop, antigravityRPC, type AntigravityRPC } from "./providers/antigravity-desktop";
import { cursorGrokQuota, cursorIdentity, readCursorCredential } from "./providers/cursor-grok";
import { readGrokBotCredential, grokBotQuota, grokBotTransport, grokBotConnectionErrors, GrokBotFailure, type GrokBotRPC } from "./providers/grok-bot-desktop";
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
  private pending = new Map<ConnectionProvider, { controller: AbortController; done: Promise<void>; settleBeforeQuit: boolean }>();
  private errors = new Set<ConnectionProvider>();
  private stopped = false;
  private antigravityController = new AbortController();
  private resetController?: AbortController;
  private stopping?: Promise<void>;
  private cleanupController = new AbortController();
  private claudeController = new AbortController();
  private grokController = new AbortController();
  constructor(readonly launch: Launch, readonly prefs: Preferences, readonly helper: string, readonly changed: () => void, readonly command: Command = runCommand, readonly http: HTTP = httpTransport(), readonly now = Date.now, readonly antigravity: AntigravityRPC = antigravityRPC, readonly grokBot: GrokBotRPC = grokBotTransport()) {}
  get state(): ConnectionState[] {
    return (["codex", "claude", "antigravity", "grok"] as const).map(provider => ({ provider, status: this.launch.codexTest && provider !== "codex" || this.launch.claudeTest && provider !== "claude" ? "unsupported" : this.pending.has(provider) ? "connecting" : this.enabled(provider) ? "connected" : this.errors.has(provider) ? "failed" : "disconnected", source: this.configured(provider) ? "account" : "cli", ...(provider === "grok" && /^[a-f\d]{64}$/.test(String(this.prefs.values.desktopGrokIdentity)) ? { accountMethod: this.prefs.values.desktopGrokSource === "bot" ? "bot" as const : "cursor" as const } : {}), localAvailable: !this.launch.demo && !this.launch.codexTest && !this.launch.claudeTest }));
  }
  enabled(provider: ConnectionProvider) { const value = this.prefs.values[this.key(provider)]; return (!this.launch.codexTest || provider === "codex") && (!this.launch.claudeTest || provider === "claude") && !this.stopped && !this.pending.has(provider) && !(provider === "codex" && this.prefs.values.desktopCodexCleanup !== "") && (provider !== "claude" || validClaudeIdentity(value)) && typeof value === "string" && value !== "" && value !== "off"; }
  configured(provider: ConnectionProvider) { return this.prefs.values[this.key(provider)] !== ""; }
  private key(provider: ConnectionProvider) { return provider === "codex" ? "desktopCodexConnection" : provider === "claude" ? "desktopClaudeIdentity" : provider === "antigravity" ? "desktopAntigravityIdentity" : "desktopGrokIdentity"; }
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
  private async claudePassword(allowUI: boolean, signal?: AbortSignal, guard: () => void = () => {}) {
    try {
      guard(); signal?.throwIfAborted();
      const password = await this.command(this.helper, allowUI ? ["--allow-ui"] : [], { signal, timeoutMs: allowUI ? 60000 : 5000, maxBytes: 4096 });
      guard(); signal?.throwIfAborted();
      return password;
    } catch { throw new Unavailable("notSignedIn", "Claude Desktop"); }
  }
  private async claudeQuota(allowUI: boolean, signal: AbortSignal, guard: () => void, expected?: string, reading?: (stage: keyof typeof desktopReadErrors) => void) {
    const check = () => { guard(); signal.throwIfAborted(); };
    check();
    const password = await this.claudePassword(allowUI, signal, check);
    check();
    const credential = await readDesktopCredential(this.launch.home, password, this.now(), reading, this.command, signal);
    check();
    if (expected && credential.identity !== expected) throw new Unavailable("notSignedIn", "Claude Desktop");
    let raw: string, verified = false;
    const verify = async () => {
      check();
      try { verifyDesktopAccount(await this.http(endpoints.claudeBootstrap, "claude", credential.cookie, signal), credential); }
      catch (error) { throw error instanceof ClaudeBrowserVerification ? error : new Unavailable("notSignedIn", "Claude Desktop"); }
      check();
    };
    try {
      reading?.("request");
      await verify(); verified = true;
      check();
      raw = await this.http(claudeUsageURL(credential.organization), "claude", credential.cookie, signal);
      check();
    } finally {
      reading?.("verification");
      // Revoked consent or cancellation must prevent another private read.
      check();
      try { if (verified) await verify(); }
      finally {
        check();
        const after = await readDesktopCredential(this.launch.home, password, this.now(), undefined, this.command, signal);
        check();
        if (after.identity !== credential.identity || after.cookie !== credential.cookie) throw new Unavailable("notSignedIn", "Claude Desktop");
      }
      reading?.("request");
    }
    reading?.("response");
    return { identity: credential.identity, quota: desktopQuota(raw, this.now()) };
  }
  private checkCodexProfile(profile: string) {
    if (this.launch.demo || !this.enabled("codex") || this.prefs.values.desktopCodexConnection !== profile) throw new Unavailable("notSignedIn", "codex");
  }
  private async cursor(signal: AbortSignal, guard: () => void, expected?: string) {
    guard(); signal.throwIfAborted();
    const credential = await readCursorCredential(this.launch.home, this.now(), this.command, signal);
    const check = () => {
      guard(); signal.throwIfAborted();
      if (credential.expiresAt <= this.now() + 60000) throw new Unavailable("notSignedIn", "Grok Bot via Cursor");
    };
    check();
    if (expected && credential.identity !== expected) throw new Unavailable("notSignedIn", "Grok Bot via Cursor");
    let raw: string;
    try {
      cursorIdentity(await this.http(endpoints.cursorIdentity, "grok", credential.cookie, signal), credential);
      check();
      const verified = await readCursorCredential(this.launch.home, this.now(), this.command, signal);
      check();
      if (verified.identity !== credential.identity || verified.store !== credential.store) throw new Unavailable("notSignedIn", "Grok Bot via Cursor");
      raw = await this.http(endpoints.cursorGrok, "grok", credential.cookie, signal);
    } finally {
      // Never reread a private store after cancellation or consent revocation.
      check();
      const after = await readCursorCredential(this.launch.home, this.now(), this.command, signal);
      if (after.identity !== credential.identity || after.store !== credential.store) throw new Unavailable("notSignedIn", "Grok Bot via Cursor");
      check();
    }
    return { identity: credential.identity, quota: cursorGrokQuota(raw, this.now()) };
  }
  private async bot(allowUI: boolean, signal: AbortSignal, guard: () => void, expected?: string) {
    const check = () => { guard(); signal.throwIfAborted(); };
    check();
    const credential = await readGrokBotCredential(this.launch.home, this.helper, this.command, this.now(), allowUI, signal, check);
    const current = () => { check(); if (credential.expiresAt <= this.now() + 60000) throw new GrokBotFailure("credentials"); };
    current();
    if (expected && credential.identity !== expected) throw new GrokBotFailure("credentials");
    let raw: string;
    try { current(); raw = await this.grokBot(credential.token, credential.team, signal); }
    catch (error) { throw error instanceof GrokBotFailure ? error : new GrokBotFailure("request", error instanceof Unavailable ? error.code : "failed"); }
    finally {
      try {
        current();
        const after = await readGrokBotCredential(this.launch.home, this.helper, this.command, this.now(), false, signal, current);
        current();
        if (after.identity !== credential.identity || after.store !== credential.store) throw new GrokBotFailure("verification");
      } catch { throw new GrokBotFailure("verification"); }
    }
    return { identity: credential.identity, quota: grokBotQuota(raw, this.now()) };
  }
  async quota(provider: ConnectionProvider, signal?: AbortSignal, profile = String(this.prefs.values[provider === "antigravity" ? "desktopAntigravityIdentity" : provider === "grok" ? "desktopGrokIdentity" : provider === "claude" ? "desktopClaudeIdentity" : "desktopCodexConnection"])) {
    if (this.launch.demo || !this.enabled(provider)) throw new Unavailable("notSignedIn", provider);
    if (provider === "grok") {
      const generation = this.grokController;
      const guard = () => { if (!this.enabled("grok") || this.grokController !== generation || this.prefs.values.desktopGrokIdentity !== profile) throw new Unavailable("notSignedIn", "Grok Bot"); };
      const source = this.prefs.values.desktopGrokSource;
      const read = source === "bot" ? this.bot.bind(this, false) : this.cursor.bind(this);
      const result = await read(signal ? AbortSignal.any([signal, generation.signal]) : generation.signal, () => { guard(); if (this.prefs.values.desktopGrokSource !== source) throw new Unavailable("notSignedIn", "Grok Bot Desktop"); }, profile);
      guard(); return result.quota;
    }
    if (provider === "codex") {
      this.checkCodexProfile(profile);
      const raw = await codexRPC(this.binary(), { env: this.env(profile), signal }, undefined, configuration);
      this.checkCodexProfile(profile); signal?.throwIfAborted();
      return parseCodex(raw, this.now());
    }
    if (provider === "antigravity") {
      const controller = this.antigravityController;
      const active = signal ? AbortSignal.any([signal, controller.signal]) : controller.signal;
      if (this.prefs.values.desktopAntigravityIdentity !== profile) throw new Unavailable("notSignedIn", "Antigravity Desktop");
      const result = await readAntigravityDesktop(this.command, this.antigravity, this.now(), active, profile);
      active.throwIfAborted();
      if (!this.enabled(provider) || this.prefs.values.desktopAntigravityIdentity !== profile) throw new Unavailable("notSignedIn", "Antigravity Desktop");
      return result.quota;
    }
    const generation = this.claudeController;
    const guard = () => { if (!this.enabled("claude") || this.claudeController !== generation || this.prefs.values.desktopClaudeIdentity !== profile) throw new Unavailable("notSignedIn", "Claude Desktop"); };
    const active = signal ? AbortSignal.any([signal, generation.signal]) : generation.signal;
    return (await this.claudeQuota(false, active, guard, profile)).quota;
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
  async connect(provider: ConnectionProvider, open: (url: string) => Promise<void>, consent: () => Promise<boolean> = async () => provider === "codex" || provider === "antigravity") {
    if (this.stopped) throw new Error("Connection unavailable");
    if (this.launch.demo) throw new Error("Connections are disabled in demo mode");
    if (this.launch.codexTest && provider !== "codex") throw new Error("Connection unavailable in Codex test mode");
    if (this.launch.claudeTest && provider !== "claude") throw new Error("Connection unavailable in Claude test mode");
    if (this.pending.has(provider) || this.enabled(provider)) throw new Error("Connection already active");
    if (provider === "codex" && this.prefs.values.desktopCodexCleanup !== "") {
      await this.recover();
      if (this.stopped) throw new Error("Connection unavailable");
      if (this.pending.has(provider) || this.enabled(provider)) throw new Error("Connection already active");
    }
    const { controller, finish } = this.begin(provider);
    let candidateID: string | undefined;
    let savedIdentity: string | undefined;
    const previousClaudeIdentity = this.prefs.values.desktopClaudeIdentity;
    const previousClaudeVisible = this.prefs.values.showProviderClaude;
    const previousGrokSource = this.prefs.values.desktopGrokSource;
    let grokSourceSaved = false;
    let grokError = "Could not connect Grok Bot Desktop. Sign in to Grok Bot, check allowance and Keychain access, then reconnect.";
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
      } else if (provider === "antigravity") {
        const result = await readAntigravityDesktop(this.command, this.antigravity, this.now(), controller.signal);
        controller.signal.throwIfAborted(); savedIdentity = result.identity;
        await this.prefs.set("desktopAntigravityIdentity", result.identity);
        controller.signal.throwIfAborted();
      } else if (provider === "grok") {
        const result = await this.bot(true, controller.signal, () => { if (this.stopped || this.pending.get("grok")?.controller !== controller) throw new Unavailable("notSignedIn", "Grok Bot Desktop"); });
        controller.signal.throwIfAborted(); savedIdentity = result.identity;
        grokError = grokBotConnectionErrors.preferences;
        grokSourceSaved = true; await this.prefs.set("desktopGrokSource", "bot");
        controller.signal.throwIfAborted();
        await this.prefs.set("desktopGrokIdentity", result.identity);
        controller.signal.throwIfAborted();
      } else {
        claudeError = "Could not access Claude Desktop through macOS Keychain. Check the access prompt, then try connecting again.";
        const result = await this.claudeQuota(true, controller.signal, () => {
          if (this.stopped || this.pending.get("claude")?.controller !== controller) throw new Unavailable("notSignedIn", "Claude Desktop");
        }, undefined, stage => { claudeError = desktopReadErrors[stage]; });
        claudeError = "Could not save the Claude Desktop connection preferences. Try connecting again.";
        controller.signal.throwIfAborted(); savedIdentity = result.identity;
        await this.prefs.set("desktopClaudeIdentity", result.identity);
        controller.signal.throwIfAborted();
      }
      await this.prefs.set(providerKey(provider), true);
      controller.signal.throwIfAborted();
      if (candidateID) {
        await this.prefs.set("desktopCodexConnection", candidateID);
        controller.signal.throwIfAborted();
        await this.prefs.set("desktopCodexCleanup", "");
        controller.signal.throwIfAborted();
      }
      return true;
    } catch (error) {
      if (provider === "claude" && !controller.signal.aborted && error instanceof ClaudeBrowserVerification) claudeError = desktopReadErrors.challenge;
      if (provider === "grok" && !controller.signal.aborted && error instanceof GrokBotFailure) grokError = grokBotConnectionErrors[error.stage];
      if (candidateID) {
        await this.disable("codex", candidateID);
        try { await this.cleanup(candidateID); }
        catch { this.errors.add(provider); throw new Error("Could not clear the cancelled Codex connection"); }
      }
      if (provider === "claude" && savedIdentity) {
        for (const [key, value] of [["desktopClaudeIdentity", previousClaudeIdentity], ["showProviderClaude", previousClaudeVisible]] as const) {
          this.prefs.values[key] = value;
          try { await this.prefs.set(key, value); } catch { this.prefs.values[key] = value; }
        }
        if (!this.stopped) this.changed();
      }
      if (provider !== "claude" && savedIdentity && this.prefs.values[this.key(provider)] === savedIdentity) {
        // Disabling clears consent in memory first; keep a failed rollback write private.
        try { await this.disable(provider); } catch { /* Report the fixed preference-save message. */ }
      }
      if (provider === "grok" && grokSourceSaved) {
        try { await this.prefs.set("desktopGrokSource", previousGrokSource); }
        catch { this.prefs.values.desktopGrokSource = previousGrokSource; }
      }
      this.errors.add(provider); throw new Error(provider === "codex" ? "Open Codex on this Mac, then try connecting again" : provider === "antigravity" ? "Open one Antigravity Desktop account and sign in, then try connecting again" : provider === "grok" ? grokError : controller.signal.aborted ? "Open Claude Desktop and sign in, then try connecting again" : claudeError);
    }
    finally { finish(); }
  }
  private begin(provider: ConnectionProvider, local = false) {
    if (provider === "claude") { this.claudeController.abort(); this.claudeController = new AbortController(); }
    if (provider === "grok") { this.grokController.abort(); this.grokController = new AbortController(); }
    if (provider === "codex") this.resetController?.abort();
    if (provider === "antigravity") { this.antigravityController.abort(); this.antigravityController = new AbortController(); }
    const controller = new AbortController();
    let settle!: () => void;
    const done = new Promise<void>(resolve => { settle = resolve; });
    this.pending.set(provider, { controller, done, settleBeforeQuit: local || provider === "claude" || provider === "antigravity" || provider === "grok" }); this.errors.delete(provider); this.changed();
    return { controller, finish: () => { this.pending.delete(provider); if (!this.stopped) this.changed(); settle(); } };
  }
  cancel(provider: ConnectionProvider) { this.pending.get(provider)?.controller.abort(); }
  private async disable(provider: ConnectionProvider, cleanupID?: string) {
    const key = this.key(provider);
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
    if ((provider === "grok" || provider === "claude") && this.pending.has(provider)) { const operation = this.pending.get(provider)!; operation.controller.abort(); await operation.done; }
    if (this.stopped || this.pending.has(provider)) throw new Error("Connection unavailable");
    const wasVisible = this.prefs.values[providerKey(provider)] === true;
    const id = String(this.prefs.values.desktopCodexCleanup || this.prefs.values.desktopCodexConnection);
    const { controller, finish } = this.begin(provider, local);
    try {
      await this.disable(provider, provider === "codex" && id !== "" && id !== "off" ? id : undefined);
      if (provider === "codex" && id !== "" && id !== "off") await this.cleanup(id);
      if (local) {
        controller.signal.throwIfAborted();
        await this.prefs.set(providerKey(provider), true);
        controller.signal.throwIfAborted();
        await this.prefs.set(this.key(provider), "");
        controller.signal.throwIfAborted();
      }
      this.errors.delete(provider);
    } catch {
      if (local && provider === "grok" && controller.signal.aborted) {
        try { await this.prefs.set(providerKey(provider), wasVisible); }
        catch { this.prefs.values[providerKey(provider)] = wasVisible; }
      }
      if (local && !this.configured(provider)) {
        try { await this.disable(provider); } catch { /* Disabling in memory keeps a failed rollback private. */ }
      }
      this.errors.add(provider); throw new Error(provider === "codex" ? "Could not disconnect Codex" : provider === "claude" ? "Could not disconnect Claude Desktop" : provider === "antigravity" ? "Could not disconnect Antigravity Desktop" : local ? "Could not select Grok CLI" : "Could not disconnect Grok Bot Desktop");
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
    this.stopped = true; this.resetController?.abort(); this.grokController.abort(); this.claudeController.abort(); this.antigravityController.abort();
    const pending = [...this.pending.values()];
    for (const operation of pending) operation.controller.abort();
    let timer: ReturnType<typeof setTimeout>;
    const expired = new Promise<void>(resolve => { timer = setTimeout(() => { this.cleanupController.abort(); resolve(); }, timeoutMs); });
    // The helper deadline must not cut off a queued source or desktop-consent rollback.
    this.stopping = Promise.race([Promise.all(pending.map(p => p.done)).then(() => {}), expired])
      .then(() => Promise.all(pending.filter(p => p.settleBeforeQuit).map(p => p.done))).then(() => {})
      .finally(() => clearTimeout(timer));
    return this.stopping;
  }
}
