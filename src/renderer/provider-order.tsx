import { useRef, useState, type ReactNode } from "react";
import { providerNames, type Provider } from "../domain/models";
import { moveProvider, normalizeProviderOrder } from "../domain/provider-order";

export function ProviderOrder({ order: stored, save, controls, mark }: { order: unknown; save: (order: Provider[]) => Promise<boolean>; controls: (provider: Provider) => ReactNode; mark?: (provider: Provider) => ReactNode }) {
  const order = normalizeProviderOrder(stored);
  const drag = useRef<Provider | null>(null), busy = useRef(false), handles = useRef(new Map<Provider, HTMLButtonElement>());
  const [cue, setCue] = useState<{ provider: Provider; after: boolean } | null>(null), [saving, setSaving] = useState(false), [message, setMessage] = useState("");
  const focus = (p: Provider) => handles.current.get(p)?.focus();
  const cancel = () => { const p = drag.current; drag.current = null; setCue(null); if (p) focus(p); };
  const commit = async (next: Provider[], p: Provider) => {
    if (busy.current || next.every((item, i) => item === order[i])) return;
    busy.current = true; setSaving(true); focus(p);
    try { if (await save(next)) setMessage(`${providerNames[p]} moved to position ${next.indexOf(p) + 1} of ${next.length}.`); }
    finally { busy.current = false; setSaving(false); focus(p); }
  };
  return <div className="provider-order" onKeyDown={e => { if (e.key === "Escape") { e.preventDefault(); cancel(); } }} onDragLeave={e => { if (!e.currentTarget.contains(e.relatedTarget as Node | null)) setCue(null); }}>
    <div className="provider-setting provider-columns"><span>Provider</span><span>Collect usage</span><span>Show in menu bar and side notch</span></div>
    {order.map((p, i) => <div key={p} className={`provider-setting${cue?.provider === p ? cue.after ? " drop-after" : " drop-before" : ""}`}
      onDragOver={e => { if (!drag.current || busy.current) return; e.preventDefault(); e.dataTransfer.dropEffect = "move"; const rect = e.currentTarget.getBoundingClientRect(); setCue({ provider: p, after: e.clientY >= rect.top + rect.height / 2 }); }}
      onDrop={e => {
        e.preventDefault(); const source = drag.current; if (!source || busy.current) return;
        const rect = e.currentTarget.getBoundingClientRect(), after = e.clientY >= rect.top + rect.height / 2;
        const next = order.filter(item => item !== source), target = next.indexOf(p);
        cancel(); if (source === p || target < 0) return;
        next.splice(target + (after ? 1 : 0), 0, source); void commit(next, source);
      }}>
      <span className="provider-name"><button className="provider-drag" ref={node => { if (node) handles.current.set(p, node); else handles.current.delete(p); }} draggable={!saving} aria-disabled={saving} aria-label={`Reorder ${providerNames[p]}`} aria-describedby="provider-order-help"
        onDragStart={e => { if (busy.current) { e.preventDefault(); return; } drag.current = p; e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", p); }} onDragEnd={cancel}
        onKeyDown={e => { if (e.key === "ArrowUp" || e.key === "ArrowDown") { e.preventDefault(); cancel(); void commit(moveProvider(order, p, e.key === "ArrowUp" ? -1 : 1), p); } }}>↕</button>
        {mark?.(p)}<span>{providerNames[p]}{p === "grok" && <> <span className="badge">Beta</span></>}</span><span className="provider-moves"><button disabled={saving || i === 0} aria-label={`Move ${providerNames[p]} up`} onClick={() => void commit(moveProvider(order, p, -1), p)}>↑</button><button disabled={saving || i === order.length - 1} aria-label={`Move ${providerNames[p]} down`} onClick={() => void commit(moveProvider(order, p, 1), p)}>↓</button></span></span>
      {controls(p)}
    </div>)}
    <p className="secondary provider-order-status" role="status" aria-live="polite">{saving ? "Saving provider order…" : message}</p>
  </div>;
}
