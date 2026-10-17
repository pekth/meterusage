export function ApiBillingSetup() {
  return <details className="connection-detail api-billing-setup">
    <summary>Set up API billing snapshots</summary>
    <p className="secondary connection-help">Use an organization Admin API key. Project API keys and ChatGPT or Claude subscription sign-in do not grant organization billing access.</p>
    <ul className="secondary connection-help">
      <li>OpenAI: create an Admin key in Platform settings under Organization → Admin keys.</li>
      <li>Anthropic: create an Admin key in Console → Settings → Admin keys.</li>
    </ul>
    <p className="secondary connection-help">Open Terminal on your Mac and paste the matching command below. At the hidden prompt, paste your Admin key and press Return. Your key will not appear on screen or in command history. Do not paste it into the command itself.</p>
    {([['OpenAI', 'OPENAI_ADMIN_KEY', 'openai'], ['Anthropic', 'ANTHROPIC_ADMIN_KEY', 'anthropic']] as const).map(([name, key, provider]) => <div key={provider}><h3>{name}</h3><pre><code>{`(\n  IFS= read -rs '${key}?Paste ${name} Admin key (hidden): ' || exit 1\n  print\n  export ${key}\n  ELECTRON_RUN_AS_NODE=1 /Applications/MeterUsage.app/Contents/MacOS/meterusage \\\n    /Applications/MeterUsage.app/Contents/Resources/api-usage-helper.cjs ${provider}\n)`}</code></pre></div>)}
    <p className="secondary connection-help">These commands contain no key. Only the short-lived helper receives it through its environment. The parent shell and MeterUsage do not store it.</p>
    <p className="secondary connection-help">When Terminal says API billing snapshot updated, click Refresh in MeterUsage. Refresh rereads the snapshot; it does not contact the billing API. Rerun the command to fetch newer billing.</p>
    <p className="secondary connection-help">Authentication failed means the key lacks access or is invalid. Data unavailable means no supported report could be fetched; check your organization billing dashboard.</p>
    <p className="secondary connection-help">OpenRouter account activity and key limits use the existing OpenRouter connection.</p>
  </details>;
}
