import type { ApiBillingProvider } from "../domain/api-billing";
import type { Launch } from "./launch";
import { collectApiBilling, writeApiBilling } from "./providers/api-billing";

export const apiBillingFetchErrors = {
  settings: "Open Settings to fetch API billing.",
  profile: "API billing fetch is unavailable in demo or isolated profiles.",
  busy: "API billing fetch is already in progress for this provider.",
  auth: "API billing authentication failed",
  unavailable: "API billing data unavailable",
  savedMissing: "No saved Admin key for this provider. Paste an organization Admin key to fetch billing.",
  savedAccess: "Could not read the saved Admin key. Approve MeterUsage access in macOS Keychain and try again.",
} as const;

export class ApiBillingFetch {
  private readonly busy = new Map<ApiBillingProvider, AbortController>();
  private stopped = false;
  constructor(private readonly launch: Launch, private readonly refresh: () => Promise<void>, private readonly fetcher: typeof fetch = fetch, private readonly savedKey?: (provider: ApiBillingProvider, signal: AbortSignal) => Promise<string>) {}

  async run(provider: ApiBillingProvider, adminKey?: string) {
    if (this.launch.demo || this.launch.candidate || this.launch.profile || this.launch.codexTest || this.launch.claudeTest) throw new Error(apiBillingFetchErrors.profile);
    if (this.stopped) throw new Error(apiBillingFetchErrors.unavailable);
    if (this.busy.has(provider)) throw new Error(apiBillingFetchErrors.busy);
    const controller = new AbortController();
    this.busy.set(provider, controller);
    try {
      if (adminKey === undefined) {
        try { adminKey = (await this.savedKey?.(provider, controller.signal))?.trim(); }
        catch { throw new Error(apiBillingFetchErrors.savedAccess); }
        if (!adminKey) throw new Error(apiBillingFetchErrors.savedMissing);
      }
      if (this.stopped) throw new Error(apiBillingFetchErrors.unavailable);
      const snapshot = await collectApiBilling(provider, adminKey, Date.now(), (url, init) => this.fetcher(url, { ...init, signal: AbortSignal.any([controller.signal, ...(init?.signal ? [init.signal] : [])]) }));
      if (this.stopped) throw new Error(apiBillingFetchErrors.unavailable);
      writeApiBilling(this.launch.home, snapshot, this.launch.data, this.launch.platform);
      await this.refresh();
    } catch (error) {
      throw new Error(!this.stopped && error instanceof Error && [apiBillingFetchErrors.auth, apiBillingFetchErrors.savedMissing, apiBillingFetchErrors.savedAccess].some(message => message === error.message) ? error.message : apiBillingFetchErrors.unavailable);
    } finally { this.busy.delete(provider); }
  }

  stop() { this.stopped = true; for (const controller of this.busy.values()) controller.abort(); }
}
