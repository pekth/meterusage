import { join } from "node:path";
import { readdir, unlink } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import { type Loaded, type Quota, type Activity, type Usage, type ServiceStatus, type Slot, type Provider, providers, primary, slotKey, lastBurn, totalTokens, utcDay, value, missing, Unavailable } from "../domain/models";
import { AlertEvaluator, type Alert } from "../domain/alerts";
import { telemetry } from "../domain/telemetry";
import { resetPacing } from "../domain/pacing";
import { type Snapshot } from "../shared/state";
import { Preferences, trayPreference } from "./preferences";
import { type Launch } from "./launch";
import { type Source, compose, accountHome } from "./composition";
import { HistoryStore, readArchive, saveArchive } from "./history";
import { limitsReport, canonicalJSON } from "../domain/report";
type Kind = "quota" | "activity" | "usage" | "plan" | "status";
export const backoffDelay = (failures: number) => Math.min(2 ** (Math.min(Math.max(failures, 1), 6) - 1), 30) * 60000;
export class Coordinator {
  quotas: Record<string, Loaded<Quota>> = Object.create(null);
  activities: Record<string, Loaded<Activity>> = Object.create(null);
  usages: Record<string, Loaded<Usage>> = Object.create(null);
  plans: Record<string, Loaded<string>> = Object.create(null);
  statuses: Partial<Record<Provider, Loaded<ServiceStatus>>> = Object.create(null);
  archived: Record<string, Quota>;
  readonly history: HistoryStore;
  archiveWriteFailed = false;
  clearingCache = false;
  lastRefreshedAt?: number;
  private inflight?: Promise<void>;
  private pendingForced = false;
  private backoffs = new Map<string, { failures: number; next: number }>();
  private observers = new Set<(state: Snapshot) => void>();
  private evaluator = new AlertEvaluator();
  private timer?: ReturnType<typeof setInterval>;
  private stopped = false;
  private controllers = new Set<AbortController>();
  private confirmations = new Map<string, { key: string; creditID: string; expires: number; source: Source }>();
  private resets = new Set<string>();
  constructor(readonly launch: Launch, readonly preferences: Preferences, public sources: Source[], readonly now: () => number = Date.now, readonly notify: (alert: Alert) => void = () => {}) {
    this.history = new HistoryStore(join(launch.data, "durable-daily-history.json")); this.archived = readArchive(join(launch.data, "quota-archive.json"));
  }
  visible(source: Source) {
    const s = source.slot;
    if (!s.slotID) return this.preferences.enabled(s.provider);
    if (this.launch.demo && s.slotID === "demo-second") return true;
    return this.preferences.accounts.some(a => a.id === s.slotID && a.provider === s.provider && a.enabled && accountHome(a, this.launch.home) !== undefined);
  }
  get slots(): Slot[] {
    const byKey = new Map(this.sources.filter(s => this.visible(s)).map(s => [slotKey(s.slot), s.slot]));
    return [...providers.map(primary), ...this.sources.filter(s => s.slot.slotID).map(s => s.slot)].filter(s => byKey.has(slotKey(s))).map(s => byKey.get(slotKey(s))!);
  }
  get burns() { return Object.fromEntries(Object.entries(this.activities).flatMap(([key, state]) => { const at = state.status === "value" ? lastBurn(state.value.sessions) : undefined; return at === undefined ? [] : [[key, at]]; })); }
  snapshot(): Snapshot {
    const p = this.preferences.values, slots = this.slots, tray = slots.filter(s => p[trayPreference(s.provider)] === true);
    return structuredClone({ demo: this.launch.demo, refreshing: !!this.inflight, clock: this.now(), lastRefreshedAt: this.lastRefreshedAt, slots, traySlots: tray.filter(s => s.provider !== "openRouter"), notchSlots: tray, quotas: this.quotas, archived: this.archived, activities: this.activities, usages: this.usages, plans: this.plans, statuses: this.statuses, appearance: { theme: p.appearanceTheme as string, accent: p.accentTheme as string, heatmap: p.showHeatmap === true, claudeHeatmap: p.showClaudeHeatmap === true, codexHeatmap: p.showCodexHeatmap === true, pacing: p.showPacingBurnRate === true, telemetry: p.showActivityTelemetry === true, chart: p.showDailyActivityChart === true, resetButton: p.showSideNotchResetButton === true, compactTray: p.menuBarCompactEnabled === true, notch: p.sideNotchPanelEnabled === true, pinned: p.sideNotchPanelPinned === true, onboarding: p.onboardingCompleted === true }, historyError: this.history.error, archiveWriteFailed: this.archiveWriteFailed, clearingCache: this.clearingCache });
  }
  subscribe(observer: (state: Snapshot) => void) { this.observers.add(observer); return () => this.observers.delete(observer); }
  publish() { const state = this.snapshot(); for (const observe of this.observers) observe(state); }
  start() { this.stopped = false; this.restartTimer(); return this.refresh(); }
  restartTimer() { if (this.timer) clearInterval(this.timer); this.timer = setInterval(() => { void this.refresh(true); }, this.preferences.refreshInterval * 1000); }
  stop() { this.stopped = true; if (this.timer) clearInterval(this.timer); this.timer = undefined; this.pendingForced = false; for (const c of this.controllers) c.abort(); this.confirmations.clear(); }
  refreshIfStale() { return this.lastRefreshedAt === undefined || this.now() - this.lastRefreshedAt > 20000 ? this.refresh() : Promise.resolve(); }
  refresh(scheduled = false, onlyKey?: string): Promise<void> {
    if (this.stopped) return Promise.resolve();
    if (onlyKey && !this.sources.some(s => slotKey(s.slot) === onlyKey && this.visible(s))) return Promise.reject(new Error("Unknown account"));
    if (this.inflight) { if (!scheduled) this.pendingForced = true; return this.inflight; }
    this.inflight = Promise.resolve().then(async () => {
      let force = !scheduled, key = onlyKey;
      do {
        this.pendingForced = false;
        await this.sweep(force, key); force = true; key = undefined;
      } while (this.pendingForced && !this.stopped);
    }).finally(() => { this.inflight = undefined; this.publish(); });
    this.publish(); return this.inflight;
  }
  private async sweep(force: boolean, onlyKey?: string) {
    const tasks: Promise<void>[] = [];
    for (const source of this.sources) {
      const key = slotKey(source.slot); if (onlyKey && key !== onlyKey) continue;
      if (this.visible(source)) {
        if (source.quota) tasks.push(this.load("quota", source, force, source.quota, this.quotas));
        if (source.activity) tasks.push(this.load("activity", source, force, source.activity, this.activities));
        if (source.usage) tasks.push(this.load("usage", source, force, source.usage, this.usages));
        if (source.plan) tasks.push(this.load("plan", source, force, source.plan, this.plans));
      }
      if (source.status) tasks.push(this.load("status", source, force, source.status, this.statuses as Record<string, Loaded<ServiceStatus>>));
    }
    await Promise.all(tasks);
    if (this.stopped) return;
    for (const source of this.sources.filter(s => this.visible(s))) {
      const key = slotKey(source.slot), q = this.quotas[key], a = this.activities[key];
      if (q?.status === "value") this.archived[key] = q.value;
      if (a?.status === "value") {
        this.history.record(key, a.value.daily, q?.status === "value" ? Math.max(0, ...q.value.windows.map(w => w.usedPercent)) : undefined);
        const durable = this.history.records(key);
        if (durable.length) {
          const merged = new Map(durable.map(d => [utcDay(d.day), d]));
          for (const d of a.value.daily) { const key = utcDay(d.day), old = merged.get(key); if (!old || totalTokens(old.tokens) <= totalTokens(d.tokens)) merged.set(key, d); }
          a.value.daily = [...merged.values()].sort((a, b) => a.day - b.day); a.value.telemetry = telemetry(a.value.sessions.map(s => ({ startedAt: s.startedAt, tokens: s.tokens.input + s.tokens.output + s.tokens.reasoning + s.tokens.cacheRead + s.tokens.cacheWrite, messageCount: s.messageCount })), a.value.daily, this.now());
        }
        if (!a.value.sessions.length && !a.value.daily.length) this.activities[key] = missing(new Unavailable("noData"), source.slot.provider);
      }
    }
    this.persistArchive();
    this.lastRefreshedAt = this.now();
    if (this.preferences.values.quotaAlertsEnabled === true) for (const alert of this.evaluator.events(this.slots, this.quotas, this.burns, this.now())) this.notify(alert);
    this.publish();
  }
  private persistArchive() {
    try {
      const slotMap = new Map(this.sources.map(s => [slotKey(s.slot), s.slot]));
      saveArchive(join(this.launch.data, "quota-archive.json"), Object.entries(this.archived).map(([key, quota]) => ({ quota, slot: slotMap.get(key) ?? { provider: quota.provider, slotID: key.includes("#") ? key.slice(key.indexOf("#") + 1) : "", label: "" } })));
      this.archiveWriteFailed = false;
    } catch { this.archiveWriteFailed = true; }
  }
  private async load<T>(kind: Kind, source: Source, force: boolean, read: (signal?: AbortSignal) => Promise<T>, target: Record<string, Loaded<T>>) {
    const key = kind === "status" ? source.slot.provider : slotKey(source.slot), backoffKey = `${kind}-${key}`, prior = this.backoffs.get(backoffKey);
    if (!force && prior && this.now() < prior.next) return;
    const resetAtStart = this.archived[key]?.resetPacingSince;
    const controller = new AbortController(); this.controllers.add(controller);
    const timeout = setTimeout(() => controller.abort(), 30000);
    const aborted = new Promise<never>((_resolve, reject) => controller.signal.addEventListener("abort", () => reject(new Error("Source cancelled")), { once: true }));
    let result: Loaded<T>;
    try { result = value(await Promise.race([read(controller.signal), aborted])); }
    catch (e) { result = missing(e, source.slot.provider); }
    finally { clearTimeout(timeout); this.controllers.delete(controller); }
    if (this.stopped) return;
    if (kind === "quota") {
      const previous = this.archived[key];
      if (previous?.resetPacingSince !== resetAtStart) return;
      if (result.status === "value" && previous?.resetPacingSince !== undefined) {
        const q = result.value as Quota;
        if (q.capturedAt <= previous.resetPacingSince || q.capturedAt <= previous.capturedAt) return;
        result = value(resetPacing(q, previous, previous.resetPacingSince, q.capturedAt) as T);
      }
    }
    target[key] = result;
    if (result.status === "missing" && ["failed", "offline"].includes(result.code)) { const failures = (prior?.failures ?? 0) + 1; this.backoffs.set(backoffKey, { failures, next: this.now() + backoffDelay(failures) }); }
    else this.backoffs.delete(backoffKey);
  }
  prepareReset(key: string, creditID: string): { token: string; account: string; title: string } {
    const source = this.sources.find(s => slotKey(s.slot) === key && this.visible(s)), q = this.quotas[key], credit = q?.status === "value" ? q.value.resetCredits.find(c => c.id === creditID) : undefined;
    if (!source?.consumeReset || !credit || (credit.expiresAt !== undefined && credit.expiresAt <= this.now())) throw new Error("Reset credit unavailable");
    for (const [token, prior] of this.confirmations) if (prior.key === key || prior.expires <= this.now()) this.confirmations.delete(token);
    const token = randomUUID(); this.confirmations.set(token, { key, creditID, expires: this.now() + 60000, source });
    return { token, account: source.slot.label || "Codex", title: credit.title };
  }
  cancelReset(token: string) { this.confirmations.delete(token); }
  async confirmReset(token: string) {
    const intent = this.confirmations.get(token); this.confirmations.delete(token);
    if (!intent || intent.expires <= this.now() || this.resets.has(intent.key)) throw new Error("Reset confirmation expired");
    const source = this.sources.find(s => slotKey(s.slot) === intent.key && this.visible(s)); const q = this.quotas[intent.key];
    if (source !== intent.source || !source?.consumeReset || q?.status !== "value" || !q.value.resetCredits.some(c => c.id === intent.creditID && (c.expiresAt === undefined || c.expiresAt > this.now()))) throw new Error("Reset credit unavailable");
    this.resets.add(intent.key);
    try {
      if (!await source.consumeReset(intent.creditID)) throw new Unavailable("failed", "Codex");
      const acceptedAt = this.now();
      const latest = this.quotas[intent.key];
      this.archived[intent.key] = resetPacing(latest?.status === "value" ? latest.value : this.archived[intent.key] ?? q.value, undefined, acceptedAt, undefined, intent.creditID);
      this.quotas[intent.key] = { status: "missing", code: "noData", reason: "Collecting usage after reset" };
      this.persistArchive();
      this.publish(); await this.refresh(false, intent.key);
    }
    catch { throw new Error("Couldn't redeem Codex reset"); }
    finally { this.resets.delete(intent.key); }
  }
  async clearCache() {
    if (this.clearingCache) return; this.clearingCache = true; this.publish();
    try {
      if (this.inflight) await this.inflight;
      const entries = await readdir(this.launch.data, { withFileTypes: true }).catch(() => []);
      for (const entry of entries) if (entry.isFile() && /^claude-local-scan-cache(?:-[A-Za-z0-9-]{1,80})?\.json$/.test(entry.name)) await unlink(join(this.launch.data, entry.name));
      this.sources = compose(this.launch, this.preferences); this.backoffs.clear(); await this.refresh();
    } finally { this.clearingCache = false; this.publish(); }
  }
  diagnostics(): string {
    const describe = <T>(s: Loaded<T> | undefined) => !s || s.status === "idle" ? "not checked yet" : s.status === "value" ? "ok" : `unavailable (${s.code})`;
    const slots = this.slots, lines = ["MeterUsage 0.2.41", `mode: ${this.launch.demo ? "demo" : "live"}`, `refresh interval: ${this.preferences.refreshInterval}s`, `last refresh: ${this.lastRefreshedAt === undefined ? "never" : Math.max(0, Math.trunc((this.now() - this.lastRefreshedAt) / 1000)) + "s ago"}`, `enabled: ${slots.map(s => s.provider + (s.slotID ? "#additional" : "")).join(", ")}`];
    if (this.history.error) lines.push(`history: ${this.history.error}`);
    if (this.archiveWriteFailed) lines.push("archive: writeFailed");
    for (const [index, s] of slots.entries()) { const key = slotKey(s); lines.push(`\n[${s.provider}${s.slotID ? ` account ${index + 1}` : ""}]`, `  quota: ${describe(this.quotas[key])}`, `  activity: ${describe(this.activities[key])}`, `  usage: ${describe(this.usages[key])}`, `  status: ${describe(this.statuses[s.provider])}`, `  plan: ${describe(this.plans[key])}`); }
    return lines.join("\n");
  }
  json() { return canonicalJSON(limitsReport(this.slots.filter(s => this.sources.some(src => src.quota && slotKey(src.slot) === slotKey(s))), this.quotas, this.burns, this.now())); }
}
