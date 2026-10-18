import { useRef, useState } from "react";
import { apiBillingNames, type ApiBillingProvider } from "../domain/api-billing";
import type { Request } from "../shared/ipc";

export function ApiBillingSetup({ provider, disabled, action, savedKeyAvailable = true }: { provider: ApiBillingProvider; disabled: boolean; savedKeyAvailable?: boolean; action: (request: Request) => Promise<void> }) {
  const input = useRef<HTMLInputElement>(null), pending = useRef(false);
  const [busy, setBusy] = useState(false);
  const fetchBilling = async (saved: boolean) => {
    if (disabled || pending.current) return;
    const adminKey = input.current?.value.trim();
    if (input.current) input.current.value = "";
    if (!saved && !adminKey) return;
    pending.current = true; setBusy(true);
    try { await action(saved ? { action: "apiBillingFetchSaved", provider } : { action: "apiBillingFetch", provider, adminKey: adminKey! }); }
    finally { pending.current = false; setBusy(false); }
  };
  return <form className="api-billing-setup" onSubmit={async event => { event.preventDefault(); await fetchBilling(false); }}>
    {savedKeyAvailable && <button type="button" disabled={disabled || busy} onClick={() => fetchBilling(true)}>{busy ? "Fetching…" : "Use saved key"}</button>}
    {savedKeyAvailable && <p className="secondary connection-help">Reuse this provider's Admin key saved by the previous MeterUsage. Approve macOS Keychain access if asked.</p>}
    <p className="secondary connection-help">{provider === "openai" ? "OpenAI Platform → Organization settings → Admin keys." : "Anthropic Console → Settings → Admin keys."}</p>
    <label className="api-key-field"><span className="secondary">{savedKeyAvailable ? "Or use a one-time Admin key" : "Use a one-time Admin key"}</span><input ref={input} aria-label={`${apiBillingNames[provider]} Admin key`} type="password" autoComplete="off" autoCapitalize="none" spellCheck={false} maxLength={8192} required disabled={disabled || busy} placeholder="Paste Admin key" /></label>
    <button type="submit" disabled={disabled || busy}>{busy ? "Fetching…" : "Fetch billing"}</button>
  </form>;
}
