import { apiBillingProviders, apiBillingNames, type ApiBillingReading } from "../domain/api-billing";
import { normalizeProviderOrder } from "../domain/provider-order";
import { ProviderOrder } from "./provider-order";
import { ApiBillingBalanceLine, ApiBillingSetup, PrepaidCreditSetup } from "./api-billing-setup";
import { Children, createContext, isValidElement, useContext, useEffect, useId, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import { interfaceStyles, styleInfo, styleOf, type ChartKind, type GaugeKind, type InterfaceStyle, type MeterKind } from "../shared/styles";
import { type Bridge, type ViewState, type Request, type Surface, type ConnectionState, PanelSize, panelScales, providerKey, trayKey, statusPages } from "../shared/ipc";
import { type AccountActivity, type Slot, type Provider, type QuotaWindow, type Telemetry, type Daily, type Loaded, type Session, type UsageWindow, clamp, providerNames, primary, slotKey, slotName, headlineWindow, lastBurn, totalTokens, localDay, shiftDay, utcDay, tokens, resetCreditAvailable, severityNames } from "../domain/models";
import { pace, measuredBurn, durationMins, burnActive, etaSeconds, formatETA, paceText } from "../domain/pacing";
import { Badge } from "@/renderer/components/ui/badge";
import { Button } from "@/renderer/components/ui/button";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/renderer/components/ui/collapsible";
import { ScrollArea } from "@/renderer/components/ui/scroll-area";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/renderer/components/ui/tabs";
import { ToggleGroup, ToggleGroupItem } from "@/renderer/components/ui/toggle-group";
import { ChevronRight } from "lucide-react";
import { attributionSessions, stripTotals, failoverNudge, heatmapCells, quotaHeatmapCells, type HeatmapMode } from "../domain/overview";
import { effectiveWindows, notchEntries } from "../domain/notch";
import { burnBreakdown } from "../domain/telemetry";
import { pricingSnapshot } from "../domain/pricing";
const accents: Record<string, string> = { blue: "#0a84ff", violet: "#a78bfa", teal: "#2dd4bf", amber: "#fbbf24", rose: "#fb7185", graphite: "#aeaeb2" };
const colours: Record<Provider, string> = { codex: "var(--brand)", claude: "var(--claude)", antigravity: "var(--antigravity)", grok: "var(--grok)", openCodeGo: "var(--opencode)", openRouter: "var(--openrouter)", cursor: "#1ab3e6", copilot: "#6699ff", gemini: "#4d80f2", muse: "#588cf5" };
const logos: Partial<Record<Provider, string>> = { codex: "codex-logo.png", grok: "grok-logo.png", antigravity: "antigravity-logo.png", openCodeGo: "opencode-logo.png", muse: "muse-code-logo.svg" };
const n = (x: number) => new Intl.NumberFormat("en", { notation: x >= 1000 ? "compact" : "standard", maximumFractionDigits: 1 }).format(x);
const money = (x: number) => new Intl.NumberFormat("en", { style: "currency", currency: "USD", maximumFractionDigits: 2 }).format(x);
const extract = <T,>(s?: Loaded<T>) => s?.status === "value" ? s.value : undefined;
const reason = (s?: Loaded<unknown>) => s?.status === "missing" ? s.reason : "Not checked yet";
const headroom = (used: number) => used >= 95 ? "var(--alert)" : used >= 80 ? "var(--warn)" : "var(--good)";
/** Local-activity scope label: Windows says "this PC". */
const deviceName = (state: ViewState) => state.platform === "win32" ? "this PC" : "this Mac";
function Mark({ slot, state }: { slot: Slot; state: ViewState }) {
  const id = useId();
  const status = extract(state.snapshot.statuses[slot.provider])?.severity;
  const tint = status === undefined || status === "operational" ? colours[slot.provider] : status === "degraded" ? "var(--warn)" : status === "unknown" ? "var(--text-muted)" : "var(--alert)";
  if (logos[slot.provider]) return <span aria-hidden="true" className="mark" data-provider={slot.provider} style={{ background: tint, maskImage: `url(./${logos[slot.provider]})`, WebkitMaskImage: `url(./${logos[slot.provider]})` }} />;
  if (slot.provider === "claude") return <svg aria-hidden="true" className="mark" viewBox="0 0 1 1" style={{ color: tint }}><defs><mask id={`eyes-${id}`}><rect width="1" height="1" fill="white" /><rect x=".27" y=".28" width=".15" height=".20" fill="black" /><rect x=".58" y=".28" width=".15" height=".20" fill="black" /></mask></defs><g fill="currentColor" mask={`url(#eyes-${id})`}><rect x=".08" y=".10" width=".84" height=".60" rx=".16" />{[.16, .35, .54, .73].map((x, i) => <rect key={x} x={x} y=".66" width=".11" height={i === 0 || i === 3 ? .22 : .24} />)}</g></svg>;
  return <span aria-hidden="true" className="mark" style={{ background: tint, maskImage: `url(./${slot.provider}-symbol.png)`, WebkitMaskImage: `url(./${slot.provider}-symbol.png)` }} />;
}
function ServiceStatuses({ state, action }: { state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  const rows = normalizeProviderOrder(state.settings.providerOrder).flatMap(provider => { const status = state.snapshot.statuses[provider]; return status ? [{ provider, status }] : []; });
  // Healthy providers share one compact line; incidents, stale readings and failures get their own line with details.
  return <section className="service-status" aria-label="Service status">{rows.length ? rows.map(({ provider, status: loaded }) => {
    const name = <span className="service-name"><Mark slot={primary(provider)} state={state} /><strong>{providerNames[provider]}</strong></span>;
    if (loaded.status !== "value") return <div className="service-row service-row-detail" key={provider}>{name}<span className="secondary">{state.snapshot.refreshing ? "Checking…" : loaded.status === "idle" ? "Not checked yet" : loaded.reason}</span></div>;
    const status = loaded.value, age = `${status.stale ? "Last known" : "Checked"} ${formatETA((state.snapshot.clock - status.checkedAt) / 1000, true)} ago`;
    const page = Object.hasOwn(statusPages, provider) ? provider as keyof typeof statusPages : undefined;
    const quiet = status.severity === "operational" && !status.stale && !status.refreshError;
    const label = severityNames[status.severity], title = `${status.description} · ${age}`;
    const badge = page ? <Button variant="outline" size="xs" className="service-badge h-5 min-h-0 rounded-full px-2 text-[10px]" data-severity={status.severity} title={title} aria-label={`${providerNames[provider]} status: ${label}. Open status page`} onClick={() => void action({ action: "statusPage", provider: page })}>{label}</Button> : <Badge variant="outline" className="service-badge text-[10px]" data-severity={status.severity} title={title}>{label}</Badge>;
    return <div className={`service-row${quiet ? "" : " service-row-detail"}`} key={provider}>{name}{badge}{!quiet && <span className="secondary">{status.severity !== "operational" || status.stale ? `${status.description} · ` : ""}{age}{status.refreshError && ` · ${status.refreshError}`}</span>}</div>;
  }) : <p className="secondary">Not checked yet</p>}</section>;
}
const heatmapModes = [["daily", "Day", "Daily"], ["weekly", "Week", "Weekly"], ["cumulative", "Total", "Cumulative"]] as const;
function HeatmapModeToggle({ label, mode, setMode }: { label: string; mode: HeatmapMode; setMode: (mode: HeatmapMode) => void }) {
  return <ToggleGroup aria-label={label} variant="outline" size="sm" spacing={0} value={[mode]} onValueChange={value => { if (value[0]) setMode(value[0] as HeatmapMode); }}>{heatmapModes.map(([value, short, full]) => <ToggleGroupItem key={value} value={value} aria-label={full} title={full} className="h-5 min-h-0 min-w-0 px-1.5 text-[10px] aria-pressed:border-primary/60 aria-pressed:bg-primary/15 aria-pressed:font-semibold aria-pressed:text-foreground">{short}</ToggleGroupItem>)}</ToggleGroup>;
}
/** Sunday-first labels matching the heatmap rows; alternate rows stay blank to keep the column narrow. */
const weekdayLabels = Array.from({ length: 7 }, (_, i) => i % 2 ? new Date(2026, 0, 4 + i).toLocaleDateString([], { weekday: "short" }) : "");
/** The active interface style. Components outside a provider render Classic. */
export const StyleContext = createContext<InterfaceStyle>("classic");
const useStyle = () => styleInfo[useContext(StyleContext)];
/** Where even pacing would put usage now: the needle drawn on style meters and gauges. */
const paceMarker = (w: QuotaWindow, now: number) => { const p = pace(w, now); return p ? clamp(p.usedPercent - p.deficitPercent) : undefined; };
const segments = (count: number, lit: number, hotFrom?: number) => Array.from({ length: count }, (_, i) => { const at = (i + .5) / count * 100; return <i key={i} className={at < lit ? hotFrom !== undefined && at > hotFrom ? "hot" : "on" : undefined} />; });
const asciiBar = (used: number, marker: number | undefined, cells: number) => Array.from({ length: cells }, (_, i) => { const at = (i + .5) / cells * 100; return at < used ? marker !== undefined && at > marker ? "▓" : "█" : "░"; }).join("");
const hpColour = (left: number) => left > 50 ? "var(--good)" : left > 20 ? "var(--warn)" : "var(--alert)";
function Flap({ text, label }: { text: string; label?: string }) {
  return <span className="flap-digits" role={label ? "img" : undefined} aria-label={label} aria-hidden={label ? undefined : true}>{[...text].map((ch, i) => <span key={i} className="flap" aria-hidden="true">{ch}</span>)}</span>;
}
function MeterVisual({ kind, used, marker, colour }: { kind: MeterKind; used: number; marker?: number; colour: string }) {
  if (kind === "tape") return <>{segments(30, used, marker)}{marker !== undefined && <b className="meter-pace" style={{ left: `${marker}%` }} />}</>;
  if (kind === "rule") return <><span className="meter-fill" style={{ width: `${used}%`, background: used >= 80 ? colour : undefined }} />{marker !== undefined && <b className="meter-pace" style={{ left: `${marker}%` }} />}</>;
  if (kind === "orbit") return <>{marker !== undefined && <span className="meter-time" style={{ width: `${marker}%` }} />}<span className="meter-fill" style={{ width: `${used}%`, background: marker !== undefined && used > marker + 10 ? "var(--alert)" : undefined }} /></>;
  if (kind === "ascii") return <span className="meter-ascii" aria-hidden="true">[{asciiBar(used, marker, 24)}]</span>;
  if (kind === "flap") return <>{segments(12, used, marker)}</>;
  if (kind === "hp") { const left = 100 - used; return <><span className="hp-label" aria-hidden="true">HP</span>{Array.from({ length: 10 }, (_, i) => <i key={i} style={(i + .5) * 10 < left ? { background: hpColour(left) } : undefined} />)}</>; }
  return <span style={{ width: `${used}%`, background: colour }} />;
}
export function Meter({ w, now, activityAt, pacing, quotaBurn = false }: { w: QuotaWindow; now: number; activityAt?: number; pacing: boolean; quotaBurn?: boolean }) {
  const style = useStyle();
  const raw = pacing ? pace(w, now) : undefined, eta = raw && etaSeconds(raw, w.resetsAt, now);
  const burn = pacing && quotaBurn ? measuredBurn(w, now) : undefined;
  const text = quotaBurn ? burn ? `Quota burn · ${burn.percentPerHour > 0 && burn.percentPerHour < .1 ? "<0.1" : new Intl.NumberFormat("en", { maximumFractionDigits: 1 }).format(burn.percentPerHour)} pp/h` : "Collecting quota burn rate" : raw ? paceText(raw) : w.pacingBaseline && durationMins(w) ? "Collecting usage after reset" : undefined;
  const burnETA = burn?.projectedExhaustion;
  const reset = w.resetsAt !== undefined ? `Resets ${new Date(w.resetsAt).toLocaleString([], { month: "short", day: "numeric", hour: "numeric", minute: "2-digit" })}` : "Reset not reported";
  const used = clamp(w.usedPercent), rounded = Math.round(w.usedPercent), colour = headroom(w.usedPercent);
  const marker = raw ? clamp(raw.usedPercent - raw.deficitPercent) : undefined;
  const figure = style.meter === "flap" ? <Flap text={`${rounded}%`} label={`${rounded}% used`} /> : style.meter === "hp" ? <strong style={{ color: hpColour(100 - rounded) }}><span aria-hidden="true">{Math.max(0, 100 - rounded)} HP</span><span className="sr-only">{rounded}% used</span></strong> : <strong style={{ color: colour }}>{rounded}% used</strong>;
  return <div className={`quota-window meter-${style.meter}`}><div className="row"><span>{w.label}</span>{figure}</div><div className={`meter meter-${style.meter}`} role="progressbar" aria-label={`${w.label} quota used`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={used} aria-valuetext={`${rounded}% used`}><MeterVisual kind={style.meter} used={used} marker={marker} colour={colour} /></div><div className="row secondary"><span title={quotaBurn ? "Percentage points of quota used per hour, measured while MeterUsage is running. Not tokens or cost." : undefined}>{pacing && text}</span><span title={reset}>{burnETA !== undefined ? `Est. ${formatETA((burnETA - now) / 1000)}` : eta !== undefined ? formatETA(eta) : reset}</span></div>{(burnETA !== undefined || eta !== undefined) && <div className="row secondary"><span>{reset}</span></div>}</div>;
}
interface StripCell { amount?: number; peak: number; readout: string; label: string }
/** Sparse-aware daily strip: a leading run of quiet days collapses into one labelled block. */
function ActivityStrip({ kind, cells, label }: { kind: Exclude<ChartKind, "grid">; cells: StripCell[]; label: string }) {
  const [active, setActive] = useState<number>();
  // Only recorded zero days count as quiet. Unavailable days stay visible.
  const firstActive = cells.findIndex(c => (c.amount ?? 0) > 0), leadingZero = cells.findIndex(c => c.amount !== 0);
  const quiet = firstActive < 0 ? 0 : Math.min(firstActive, leadingZero < 0 ? cells.length : leadingZero);
  const collapsed = quiet >= 7, shown = collapsed ? cells.slice(quiet) : cells;
  // The label accounts for every collapsed day: whole weeks plus any remainder.
  const weeks = Math.floor(quiet / 7), days = quiet % 7;
  const quietLabel = quiet < 14 ? `${quiet} quiet days` : days ? `${weeks} weeks ${days} days quiet` : `${weeks} quiet weeks`;
  const peak = Math.max(0.0001, ...shown.map(c => c.amount ?? 0)), level = (c: StripCell) => (c.amount ?? 0) / peak;
  const current = active ?? shown.length - 1, readout = active !== undefined ? shown[active]?.readout : undefined;
  const move = (e: KeyboardEvent<HTMLDivElement>) => {
    const step = e.key === "ArrowLeft" || e.key === "ArrowDown" ? -1 : e.key === "ArrowRight" || e.key === "ArrowUp" ? 1 : 0;
    if (!step && e.key !== "Home" && e.key !== "End") return;
    e.preventDefault();
    setActive(e.key === "Home" ? 0 : e.key === "End" ? shown.length - 1 : Math.min(shown.length - 1, Math.max(0, current + step)));
  };
  if (!cells.length || cells.every(c => c.amount === undefined)) return <p className="heatmap-empty secondary">Activity unavailable</p>;
  if (firstActive < 0) return <p className="heatmap-empty secondary">No activity recorded yet</p>;
  const quietBlock = collapsed && <span className="strip-quiet" title={`${quietLabel} before the first recorded activity`}>{quietLabel}</span>;
  let body: ReactNode;
  if (kind === "spark") body = <span className="strip-spark">{collapsed && <span className="strip-quiet">·· {quietLabel} ··</span>}{shown.map((c, i) => <span key={i} className={i === active ? "active" : undefined} title={c.label} onPointerEnter={() => setActive(i)}>{c.amount === undefined ? "·" : "▁▂▃▄▅▆▇█"[Math.min(7, Math.round(level(c) * 7))]}</span>)}</span>;
  else if (kind === "trace") {
    // Each day owns an equal slice, so the latest day is drawn and the cursor sits over its hit area.
    const width = 300, height = 60, slice = width / shown.length, y = (c: StripCell) => height - 3 - level(c) * (height - 8);
    const path = `M0 ${y(shown[0]).toFixed(1)}` + shown.map((c, i) => `V${y(c).toFixed(1)}H${((i + 1) * slice).toFixed(1)}`).join("");
    body = <>{quietBlock}<span className="strip-plot"><svg className="strip-trace" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" aria-hidden="true"><path className="trace-area" d={`${path}V${height}H0Z`} /><path className="trace-line" d={path} vectorEffect="non-scaling-stroke" />{active !== undefined && <line className="trace-cursor" x1={(active + .5) * slice} x2={(active + .5) * slice} y1="0" y2={height} vectorEffect="non-scaling-stroke" />}</svg><span className="strip-hits">{shown.map((c, i) => <span key={i} title={c.label} onPointerEnter={() => setActive(i)} />)}</span></span></>;
  } else body = <>{quietBlock}<span className="strip-bars" style={{ gap: shown.length > 40 ? 0 : 2 }}>{shown.map((c, i) => <span key={i} title={c.label} className={`${c.amount === undefined ? "unavailable-day" : ""}${i === active ? " active" : ""}${i === shown.length - 1 ? " latest" : ""}`} onPointerEnter={() => setActive(i)}><i style={{ height: `${c.amount ? Math.max(4, level(c) * 100) : 0}%` }} /></span>)}</span></>;
  // A slider reads one day at a time in screen readers' focus mode; the visual readout repeats it for pointer users.
  return <><div className={`activity-strip strip-${kind}`} role="slider" tabIndex={0} aria-label={`${label}${collapsed ? `, ${quietLabel} collapsed` : ""}`} aria-valuemin={1} aria-valuemax={shown.length} aria-valuenow={current + 1} aria-valuetext={shown[current]?.label} onKeyDown={move} onPointerLeave={() => setActive(undefined)} onBlur={() => setActive(undefined)}>{body}</div><div className="heatmap-readout" aria-hidden="true">{readout ? <span>{readout}</span> : <span className="secondary">{shown.length} days shown{collapsed ? ` · ${quietLabel} collapsed` : ""}</span>}</div></>;
}
type HeatmapProps = { title: string; scope: string; period?: string; label: string; fullHistory?: boolean; weeks?: number; weekdays?: boolean; unavailable?: boolean; controls?: ReactNode; children?: ReactNode; chart?: ChartKind };
/** Renders a heatmap in the active style's chart. */
function StyledHeatmap(props: HeatmapProps) { return <ActivityHeatmap {...props} chart={useStyle().chart} />; }
export function ActivityHeatmap({ title, scope, period, label, fullHistory, weeks, weekdays = false, unavailable = false, controls, children, chart = "grid" }: HeatmapProps) {
  const grid = useRef<HTMLDivElement>(null);
  const [hovered, setHovered] = useState<string>(), [focused, setFocused] = useState<string>();
  const readout = hovered ?? focused;
  useEffect(() => {
    const node = grid.current; if (!node) return;
    const cells = Array.from(node.querySelectorAll<HTMLElement>(".heatmap-cell[tabindex]"));
    const selected = cells.find(cell => cell === node.ownerDocument.activeElement) ?? cells.find(cell => cell.tabIndex === 0) ?? cells[0];
    cells.forEach(cell => { cell.tabIndex = cell === selected ? 0 : -1; });
    setFocused(cells.find(cell => cell === node.ownerDocument.activeElement)?.dataset.readout);
    setHovered(node.querySelector<HTMLElement>(".heatmap-cell[tabindex]:hover")?.dataset.readout);
  }, [children]);
  if (chart !== "grid" && children) {
    const cells = Children.toArray(children).flatMap(child => isValidElement<HeatmapCellProps>(child) && child.type === HeatmapCell ? [child.props] : []);
    return <section className="activity-heatmap"><div className="heatmap-heading"><h3>{title}</h3>{controls}</div><p className="heatmap-caption secondary">{scope}{period && <> · {period}</>}</p><ActivityStrip kind={chart} cells={cells} label={label} /></section>;
  }
  return <section className="activity-heatmap"><div className="heatmap-heading"><h3>{title}</h3>{controls}</div><p className="heatmap-caption secondary">{scope}{period && <> · {period}</>}</p>{children ? <><div className={weekdays ? "heatmap-body" : "contents"}>{weekdays && <div className="heatmap-weekdays" aria-hidden="true">{weekdayLabels.map((day, i) => <span key={i}>{day}</span>)}</div>}<div ref={grid} className={`heatmap${fullHistory ? " full-history" : ""}`} style={weeks ? { "--weeks": weeks } as CSSProperties : undefined} aria-label={label} onPointerOver={e => setHovered((e.target as HTMLElement).closest<HTMLElement>(".heatmap-cell[tabindex]")?.dataset.readout)} onPointerLeave={() => setHovered(undefined)} onBlur={() => setFocused(undefined)} onFocus={e => {
    const target = e.target as HTMLElement;
    if (!target.classList.contains("heatmap-cell")) return;
    setFocused(target.dataset.readout);
    e.currentTarget.querySelectorAll<HTMLElement>(".heatmap-cell").forEach(cell => { cell.tabIndex = cell === target ? 0 : -1; });
  }} onKeyDown={e => {
    const cells = Array.from(e.currentTarget.children).filter((node): node is HTMLElement => node.tagName === "SPAN"), target = e.target as HTMLElement;
    const index = cells.indexOf(target); if (index < 0) return;
    const step = e.key === "ArrowUp" ? fullHistory ? -1 : -15 : e.key === "ArrowDown" ? fullHistory ? 1 : 15 : e.key === "ArrowLeft" ? fullHistory ? -7 : -1 : e.key === "ArrowRight" ? fullHistory ? 7 : 1 : 0;
    if (!step && e.key !== "Home" && e.key !== "End") return;
    e.preventDefault();
    let next = e.key === "Home" ? 0 : e.key === "End" ? cells.length - 1 : index + step;
    const direction = e.key === "End" ? -1 : step || 1;
    while (next >= 0 && next < cells.length && !cells[next].classList.contains("heatmap-cell")) next += direction;
    if (next >= 0 && next < cells.length) cells[next].focus();
  }}>{children}</div></div><div className="heatmap-readout" aria-hidden="true">{readout ? <span>{readout}</span> : <div className="heatmap-legend secondary"><span className="heatmap-scale" aria-label="Usage intensity from less to more">Less{[0, .3, .65, 1].map(level => <i key={level} aria-hidden="true" style={{ background: level ? "var(--brand)" : "var(--well)", opacity: level || 1 }} />)}More</span>{unavailable && <span className="heatmap-missing"><i aria-hidden="true" />Unavailable</span>}</div>}</div></> : <p className="heatmap-empty secondary">Account history unavailable</p>}</section>;
}
interface HeatmapCellProps { label: string; readout: string; amount?: number; peak: number; first?: boolean; staticExport?: boolean }
export function HeatmapCell({ label, readout, amount, peak, first = false, staticExport = false }: HeatmapCellProps) {
  return <span className={`heatmap-cell${amount === undefined ? " unavailable-day" : ""}`} tabIndex={staticExport ? undefined : first ? 0 : -1} role="img" aria-label={label} title={label} data-readout={readout}><span aria-hidden="true" style={{ background: amount === undefined ? "transparent" : amount > 0 ? "var(--brand)" : "var(--well)", opacity: amount ? .3 + .7 * amount / peak : 1 }} /></span>;
}
function TelemetryView({ provider, t, stats, chart, heatmap, daily, now, staticExport, device }: { provider: Provider; t: Telemetry; stats: boolean; chart: boolean; heatmap: boolean; daily?: Daily[]; now: number; staticExport: boolean; device: string }) {
  const [mode, setMode] = useState<HeatmapMode>("daily");
  const today = provider === "openRouter" ? utcDay(now) : localDay(now), offset = 25 * 7 + new Date(today).getUTCDay();
  const history = new Map(t.dailyHistory.map(d => [d.day, d]));
  const cells: ({ day: number; tokens: number; sessionCount: number; available?: boolean } | null)[] = daily ? heatmapCells(daily, now, mode) : Array.from({ length: 182 }, (_, i) => {
    const day = provider === "openRouter" ? today + (i - offset) * 86400000 : shiftDay(today, i - (25 * 7 + new Date(today).getDay()));
    return day > today ? null : history.get(day) ?? { day, tokens: 0, sessionCount: 0, available: false };
  });
  const measured = t.lifetimeTokens !== undefined;
  const amount = (d: { tokens: number; sessionCount: number }) => measured ? d.tokens : d.sessionCount;
  const metrics = [["Today tokens", t.todayTokens], ["Last 30 days", t.last30DaysTokens], ["Lifetime tokens", t.lifetimeTokens], ["Peak day", t.peakDailyTokens], ["Current streak", `${t.currentStreakDays} days`], ["Longest streak", `${t.longestStreakDays} days`], ["Recorded sessions", t.totalSessions], ["Recorded messages", t.totalMessages], ["Longest chat", t.longestChatSeconds === undefined ? undefined : formatETA(t.longestChatSeconds, true)]] as const;
  const availableMetrics = metrics.filter(([, v]) => v !== undefined);
  const metricRows = (rows: typeof availableMetrics) => <dl className="metrics">{rows.map(([k, v]) => <div key={k}><dt>{k}</dt><dd>{typeof v === "number" ? n(v) : v}</dd></div>)}</dl>;
  const peak = Math.max(1, ...t.dailyHistory.map(amount)), cellPeak = Math.max(1, ...cells.flatMap(d => d ? [amount(d)] : []));
  const exact = new Intl.NumberFormat(), date = (day: number) => new Date(day).toLocaleDateString([], { year: "numeric", month: "short", day: "numeric", ...(provider === "openRouter" ? { timeZone: "UTC" } : {}) });
  return <section className="telemetry">{stats && <><h3>Recorded activity</h3>{metricRows(staticExport ? availableMetrics : availableMetrics.slice(0, 2))}{!staticExport && availableMetrics.length > 2 && <details className="activity-details"><summary>More activity</summary>{metricRows(availableMetrics.slice(2))}</details>}</>}{chart && <svg className="sparkline" role="img" aria-label={`${measured ? "Token" : "Session"} usage in the last 30 days`} viewBox="0 0 300 50" preserveAspectRatio="none"><polyline points={t.dailyHistory.map((d, i) => `${i * 300 / 29},${48 - amount(d) / peak * 45}`).join(" ")} fill="none" stroke="var(--brand)" strokeWidth="2" /></svg>}{heatmap && <StyledHeatmap title={measured ? "Token activity" : "Session activity"} scope={provider === "openRouter" ? "Provider account" : device[0].toUpperCase() + device.slice(1)} period="26 weeks" label="Usage over 26 weeks" fullHistory weekdays unavailable={cells.some(d => d?.available === false)} controls={daily && !staticExport && <HeatmapModeToggle label="Heatmap view" mode={mode} setMode={setMode} />}>{cells.map((d, i) => {
    if (!d) return <span key={`future-${i}`} />;
    const scope = !daily || mode === "daily" ? date(d.day) : mode === "weekly" ? `Week of ${date(shiftDay(d.day, -new Date(d.day).getDay()))}` : `Through ${date(d.day)}`;
    const label = `${scope}: ${d.available === false ? "Unavailable" : measured ? `${exact.format(d.tokens)} tokens, ${exact.format(d.sessionCount)} sessions` : `${exact.format(d.sessionCount)} sessions, token totals unavailable`}`;
    const readout = `${scope} · ${d.available === false ? "Unavailable" : measured ? `${n(d.tokens)} tokens · ${n(d.sessionCount)} sessions` : `${n(d.sessionCount)} sessions · token totals unavailable`}`;
    return <HeatmapCell key={d.day} first={i === 0} staticExport={staticExport} label={label} readout={readout} amount={d.available === false ? undefined : amount(d)} peak={cellPeak} />;
  })}</StyledHeatmap>}</section>;
}
function QuotaHeatmap({ provider, days, local, now, staticExport, device }: { provider: Provider; days: { day: number; percent: number; estimated?: boolean }[]; local?: Daily[]; now: number; staticExport: boolean; device: string }) {
  const [mode, setMode] = useState<HeatmapMode>("daily");
  // Measured tokens from this device's transcripts, matched by aggregated cell.
  const tokenCells = local?.length ? heatmapCells(local, now, mode) : undefined;
  // Quota history starts when MeterUsage first reads the account; skip whole weeks before it, keeping at least 12.
  const all = quotaHeatmapCells(days, now, mode), first = days.length ? Math.min(...days.map(d => localDay(d.day))) : localDay(now);
  const skip = 7 * Math.min(26 - 12, Math.floor(Math.max(0, all.findIndex(c => c !== null && c.day >= first)) / 7)), weeks = 26 - skip / 7;
  const cells = all.slice(skip), peak = Math.max(0.0001, ...cells.flatMap(c => c ? [c.percent] : []));
  const pct = (v: number) => v === 0 ? "0%" : v < 1 ? "<1%" : `${Math.round(v)}%`;
  const date = (day: number) => new Date(day).toLocaleDateString([], { year: "numeric", month: "short", day: "numeric" });
  return <section className="telemetry"><StyledHeatmap title="Quota activity" scope={`${providerNames[provider]} account · all devices`} period={days.length ? `${weeks} weeks` : "fills in as usage rises"} label={`Daily quota used over ${weeks} weeks`} fullHistory weeks={weeks} weekdays controls={!staticExport && <HeatmapModeToggle label="Quota heatmap view" mode={mode} setMode={setMode} />}>{cells.map((c, i) => {
    if (!c) return <span key={`future-${i}`} />;
    const scope = mode === "daily" ? date(c.day) : mode === "weekly" ? `Week of ${date(shiftDay(c.day, -new Date(c.day).getDay()))}` : `Through ${date(c.day)}`;
    const tokens = tokenCells?.[skip + i]?.tokens ?? 0, exact = tokens ? `, ${new Intl.NumberFormat().format(tokens)} tokens on ${device}` : "", compact = tokens ? ` · ${n(tokens)} tokens on ${device}` : "";
    return <HeatmapCell key={c.day} first={i === 0} staticExport={staticExport} label={`${scope}: ${c.estimated ? "about " : ""}${pct(c.percent)} of quota used${c.estimated ? " (estimated)" : ""}${exact}`} readout={`${scope} · ${c.estimated ? "≈" : ""}${pct(c.percent)} of quota used${c.estimated ? " · estimated" : ""}${compact}`} amount={c.percent} peak={peak} />;
  })}</StyledHeatmap></section>;
}
function AccountHeatmap({ reading, staticExport }: { reading: Loaded<AccountActivity>; staticExport: boolean }) {
  const buckets = extract(reading)?.dailyUsageBuckets;
  if (!buckets?.length) return <section className="telemetry"><StyledHeatmap title="Account token activity" scope="Provider account" label="Account daily tokens" /></section>;
  const sorted = [...buckets].sort((a, b) => a.startDate.localeCompare(b.startDate));
  const end = Date.parse(sorted[sorted.length - 1].startDate), byDate = new Map(sorted.map(b => [b.startDate, b.tokens]));
  const cells = Array.from({ length: 182 }, (_, i) => {
    const date = new Date(end - (181 - i) * 86400000).toISOString().slice(0, 10);
    return { date, tokens: byDate.get(date) };
  });
  const peak = Math.max(1, ...cells.map(c => c.tokens ?? 0));
  return <section className="telemetry"><StyledHeatmap title="Account token activity" scope="Provider account" period={`26 weeks through ${sorted[sorted.length - 1].startDate}`} label="Account daily tokens over 26 weeks" fullHistory unavailable={cells.some(c => c.tokens === undefined)}>{cells.map((c, i) => <HeatmapCell key={c.date} first={i === 0} staticExport={staticExport} label={`${c.date}: ${c.tokens === undefined ? "Unavailable" : `${new Intl.NumberFormat("en").format(c.tokens)} tokens`}`} readout={`${new Date(c.date).toLocaleDateString([], { year: "numeric", month: "short", day: "numeric", timeZone: "UTC" })} · ${c.tokens === undefined ? "Unavailable" : `${n(c.tokens)} tokens`}`} amount={c.tokens} peak={peak} />)}</StyledHeatmap></section>;
}
export function ProviderCard({ slot, state, action, detail = false, staticExport = false }: { slot: Slot; state: ViewState; action: (r: Request) => Promise<boolean | void>; detail?: boolean; staticExport?: boolean }) {
  const s = state.snapshot, key = slotKey(slot), fresh = extract(s.quotas[key]), q = fresh ?? s.archived[key], activity = extract(s.activities[key]), usage = extract(s.usages[key]), plan = extract(s.plans[key]) ?? q?.planType, accountActivity = s.accountActivities?.[key];
  const t = activity?.telemetry ?? usage?.telemetry, at = activity && lastBurn(activity.sessions), status = extract(s.statuses[slot.provider]);
  const activeWindow = detail && q && activity ? headlineWindow(slot.provider, effectiveWindows(q)) : undefined;
  const heatmap = s.appearance.heatmap && (slot.provider !== "claude" || s.appearance.claudeHeatmap) && (slot.provider !== "codex" || s.appearance.codexHeatmap);
  return <article className={`provider-card usage-card ${detail ? "detail-card" : ""}`} aria-label={slotName(slot)}><header className="row"><div className="provider-heading"><Mark slot={slot} state={state} /><h2>{slotName(slot)}{slot.provider === "grok" && <> <span className="badge">Beta</span></>}</h2></div>{plan && <span className="badge">{plan}</span>}</header>{status && <p className="secondary status">{status.stale ? `Last known ${status.severity === "operational" ? "Operational" : status.description} · ${formatETA((s.clock - status.checkedAt) / 1000, true)} ago · ${status.refreshError}` : status.severity === "operational" ? "Operational" : status.description}</p>}{q ? <>{fresh && slot.provider === "muse" && <p className="secondary">Observed {new Date(q.capturedAt).toLocaleString()} · CLI subscription allowance</p>}{fresh?.observedFrom === "grokBotCache" && <p className="secondary grok-cached">Observed {new Date(q.capturedAt).toLocaleString()} · Grok Bot's cached reading</p>}{!fresh && <p className="stale quota-stale">Last known · {new Date(q.capturedAt).toLocaleString()}{q.observedFrom === "grokBotCache" && " · Grok Bot's cached reading"}<br />{reason(s.quotas[key])}</p>}{q.groups.length ? q.groups.map(g => <section key={g.id}><h3>{g.title}</h3>{g.windows.map((w, index) => <Meter key={index} w={w} now={s.clock} activityAt={at} pacing={s.appearance.pacing} quotaBurn={!!fresh && !fresh.observedFrom && slot.provider === "grok" && state.connections?.some(c => c.provider === "grok" && c.source === "account" && c.accountMethod === "bot")} />)}</section>) : (detail ? effectiveWindows(q) : q.windows).map((w, index) => <Meter key={index} w={w} now={s.clock} activityAt={at} pacing={s.appearance.pacing} quotaBurn={!!fresh && !fresh.observedFrom && slot.provider === "grok" && state.connections?.some(c => c.provider === "grok" && c.source === "account" && c.accountMethod === "bot")} />)}{q.credits && <div className="credit well"><div className="row"><span>{q.credits.unit === "dollars" ? "Balance" : "Credits"}</span><strong>{q.credits.unlimited ? "Unlimited" : q.credits.unit === "dollars" ? money(q.credits.balance) : n(q.credits.balance)}</strong></div>{q.credits.dollarBalance !== undefined && <p className="secondary">≈ {money(q.credits.dollarBalance)} equivalent</p>}{q.credits.usedDollars !== undefined && <p className="secondary">{money(q.credits.usedDollars)} used{q.credits.limitDollars === undefined ? "" : ` of ${money(q.credits.limitDollars)}`}</p>}</div>}{q.resetCreditCount !== undefined && <section className="reset-credits"><h3>{q.resetCreditCount} earned reset credits</h3>{q.resetCredits.map(c => <div key={c.id} className="reset-credit"><div className="row"><span>{c.title}</span>{!staticExport && fresh?.canConsumeReset === true && (!detail || s.appearance.resetButton) && resetCreditAvailable(c, s.clock) && <button aria-label={`Use reset: ${c.title} for ${slotName(slot)}`} onClick={() => void action({ action: "reset", key, creditID: c.id })}>Use reset</button>}</div><p className="secondary">{c.status ?? "Status not reported"}{c.expiresAt !== undefined && c.expiresAt <= s.clock ? " · expired" : ""} · {c.expiresAt === undefined ? "Expiry not reported" : `Expires ${new Date(c.expiresAt).toLocaleDateString()}`}</p></div>)}</section>}</> : <p className="empty">{reason(s.quotas[key])}</p>}{usage && <section><h3>{slot.provider === "openRouter" ? "Account activity" : `Activity on ${deviceName(state)}`}</h3><dl className="metrics"><div><dt>Sessions</dt><dd>{n(usage.sessionCount)}</dd></div><div><dt>Messages</dt><dd>{n(usage.messageCount)}</dd></div>{usage.tokens !== undefined && <div><dt>Measured tokens</dt><dd>{n(totalTokens(usage.tokens))}</dd></div>}{usage.estimatedCostUSD !== undefined && <div><dt>Estimated cost</dt><dd>{money(usage.estimatedCostUSD)}</dd></div>}</dl><p className="secondary">{usage.todayMessageCount > 0 || usage.todaySessionCount > 0 ? `Today: ${n(usage.todaySessionCount)} session${usage.todaySessionCount === 1 ? "" : "s"} · ${n(usage.todayMessageCount)} messages · updated ${formatETA((s.clock - usage.capturedAt) / 1000, true)} ago` : `Updated ${formatETA((s.clock - usage.capturedAt) / 1000, true)} ago · ${usage.tokens !== undefined ? "measured token totals" : "token totals unavailable"}`}</p>{usage.usageWindows && (staticExport ? <RollingUsage windows={usage.usageWindows} provider={slot.provider} /> : <details className="rolling-details"><summary>Usage by period</summary><RollingUsage windows={usage.usageWindows} provider={slot.provider} /></details>)}</section>}{accountActivity && heatmap && <AccountHeatmap reading={accountActivity} staticExport={staticExport} />}{heatmap && q && !s.demo && !extract(accountActivity)?.dailyUsageBuckets?.length && <QuotaHeatmap provider={slot.provider} days={s.quotaActivity?.[key] ?? []} local={activity?.daily} now={s.clock} staticExport={staticExport} device={deviceName(state)} />}{t && (s.appearance.telemetry || s.appearance.chart || heatmap) && <TelemetryView provider={slot.provider} t={t} stats={s.appearance.telemetry} chart={s.appearance.chart} heatmap={heatmap} daily={activity?.daily} now={s.clock} staticExport={staticExport} device={deviceName(state)} />}{activeWindow && activity && (staticExport ? <WindowBurn sessions={activity.sessions} w={activeWindow} now={s.clock} /> : <details className="burn-details"><summary>Active window breakdown</summary><WindowBurn sessions={activity.sessions} w={activeWindow} now={s.clock} /></details>)}{activity && activity.sessions.length > 0 && <details><summary>Recent sessions ({activity.sessions.length})</summary>{activity.sessions.slice(-8).reverse().map(session => <div key={session.id} className="session"><div className="row"><span>{session.projectName}</span><strong>{n(totalTokens(session.tokens))}</strong></div><p className="secondary">{session.model} · {session.messageCount} turns · estimated {money(session.estimatedCostUSD)}</p></div>)}</details>}{!activity && !usage && (s.activities[key] || s.usages[key]) && <p className="secondary">{reason(s.activities[key] ?? s.usages[key])}</p>}{detail && !staticExport && <footer className="row"><button onClick={() => void action({ action: "share", key })}>{state.platform === "win32" ? "Copy card image" : "Share card"}</button><button onClick={() => void action({ action: "settings" })}>Settings</button></footer>}</article>;
}
function RollingUsage({ windows, provider }: { windows: UsageWindow[]; provider: Provider }) {
  const reference = windows.find(w => w.label === "last 30d"), cost = (reference?.estimatedCostUSD ?? 0) > 0;
  const denominator = cost ? reference!.estimatedCostUSD : reference ? totalTokens(reference.tokens) : 0;
  return <section className="rolling-usage">{windows.map(w => {
    const percent = clamp(denominator > 0 ? (cost ? w.estimatedCostUSD : totalTokens(w.tokens)) / denominator * 100 : 0);
    return <div key={w.label}><div className="row secondary"><span>{w.label}</span><strong style={{ color: colours[provider] }}>{Math.round(percent)}%</strong></div><div className="meter" role="progressbar" aria-label={`${w.label} share of last 30 days`} aria-valuemin={0} aria-valuemax={100} aria-valuenow={percent}><span style={{ width: `${percent}%`, minWidth: percent > 0 ? 3 : 0, background: colours[provider] }} /></div><p className="secondary">{n(totalTokens(w.tokens))} tokens · {n(w.messageCount)} messages</p></div>;
  })}{reference && <p className="secondary">{n(reference.sessionCount)} sessions · {n(reference.messageCount)} messages · {n(totalTokens(reference.tokens))} tokens{cost ? ` · ~${money(reference.estimatedCostUSD)}` : ""}</p>}<p className="secondary">{cost ? `Share of last 30d usage · est. ${pricingSnapshot} rates` : "Share of last 30d tokens"}</p></section>;
}
function WindowBurn({ sessions, w, now }: { sessions: Session[]; w: QuotaWindow; now: number }) {
  const b = burnBreakdown(sessions, now, { window: w });
  if (!b) return null;
  return <section className="window-burn"><h3>Active window burn</h3><p className="secondary">{n(b.totalTokens)} tokens</p>{b.contributors.map(c => <div className="session" key={`${c.projectName}|${c.model}`}><div className="row"><span>{c.projectName}</span><strong>{Math.round(c.shareOfWindow)}%</strong></div><p className="secondary">{c.model}</p></div>)}<p className="secondary">{b.cacheHitRate === undefined ? null : `${Math.round(b.cacheHitRate)}% cache hit`}{b.avgTokensPerTurn === undefined ? null : ` · ${n(b.avgTokensPerTurn)} tokens/turn`}{b.longChatCount ? ` · ${b.longChatCount} long ${b.longChatCount === 1 ? "chat" : "chats"}` : null}</p></section>;
}
function BurnCard({ state }: { state: ViewState }) {
  const s = state.snapshot, since = shiftDay(localDay(s.clock), -6);
  const sessions = attributionSessions(s.slots, s.activities, s.usages, s.clock);
  const b = burnBreakdown(sessions, s.clock, { since, fallbackToRecent: false });
  if (!b) return null;
  return <section className="provider-card"><h2>Measured burn · last 7 days</h2><p>{n(b.totalTokens)} tokens{b.cacheHitRate === undefined ? "" : ` · ${Math.round(b.cacheHitRate)}% cache hit`}</p>{b.contributors.map(c => <div key={`${c.projectName}|${c.model}`} className="session"><div className="row"><span>{c.projectName}</span><strong>{Math.round(c.shareOfWindow)}%</strong></div><p className="secondary">{c.model} · {n(c.totalTokens)} tokens{c.isLongChat ? " · Long chat" : ""}</p></div>)}</section>;
}
function UnifiedStrip({ state }: { state: ViewState }) {
  const s = state.snapshot, localSlots = s.slots.filter(slot => slot.provider !== "openRouter"), activities = localSlots.flatMap(slot => { const a = extract(s.activities[slotKey(slot)]); return a ? [a] : []; }), usages = localSlots.flatMap(slot => { const u = extract(s.usages[slotKey(slot)]); return u ? [u] : []; });
  const totals = stripTotals(activities, usages, s.clock), nudge = failoverNudge(s.slots, s.quotas, s.activities, s.clock);
  if (totals.todayTokens === undefined && !nudge) return null;
  return <section className="provider-card activity-summary"><h2>AI activity on {deviceName(state)}</h2>{totals.todayTokens !== undefined && <dl className="metrics"><div><dt>Tokens today</dt><dd>{n(totals.todayTokens)}</dd></div><div><dt>Last 7 days</dt><dd>{n(totals.weekTokens!)}</dd></div><div><dt>Estimated cost today</dt><dd>{money(totals.todayCost!)}</dd></div></dl>}{nudge && <p className="stale">{nudge}</p>}</section>;
}
const labels: Record<string, string> = { launchAtLogin: "Launch at login", quotaAlertsEnabled: "Quota alerts", updateCheckEnabled: "Check for updates", updateAutoInstall: "Install updates automatically", sideNotchPanelEnabled: "Show side notch", menuBarCompactEnabled: "Compact menu bar", showHeatmap: "Daily heatmaps", showClaudeHeatmap: "Claude heatmap", showCodexHeatmap: "Codex heatmap", showPacingBurnRate: "Pacing and burn rate", showActivityTelemetry: "Activity statistics", showDailyActivityChart: "Daily activity chart", showSideNotchResetButton: "Codex limit resets in the side notch" };
function ConnectionRow({ connection: c, state, action }: { connection: ConnectionState; state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  const [method, setMethod] = useState<ConnectionState["source"]>(!c.localAvailable && c.status !== "unsupported" ? "account" : c.source);
  const [expanded, setExpanded] = useState(false);
  const busy = c.status === "connecting", collected = state.settings.values[providerKey(c.provider)] === true;
  const localActive = c.source === "cli" && collected;
  const localName = c.provider === "claude" ? "Claude Code CLI" : `${providerNames[c.provider]} CLI`;
  const accountName = c.provider === "claude" ? "Claude Desktop" : c.provider === "antigravity" ? "Antigravity Desktop" : c.provider === "grok" ? "Grok Bot Desktop (Beta)" : "Browser sign-in";
  const help = method === "cli"
    ? c.provider === "claude" ? `Reads Claude Code activity on ${deviceName(state)}. Allowance needs a companion usage file.`
      : c.provider === "antigravity" ? `Uses your existing agy CLI for allowance and local activity on ${deviceName(state)}.`
      : c.provider === "grok" ? "Reads your existing Grok CLI allowance and local session counts. Grok website and mobile usage are not supported."
      : `Uses your existing Codex CLI sign-in for allowance and reads token activity on ${deviceName(state)}.`
    : c.provider === "claude" ? state.platform === "win32" ? "Uses the account signed in to Claude Desktop, unlocked for your Windows account. Allowance depends on your plan. The Windows reader is unverified." : "Uses the account signed in to Claude Desktop. You approve access in macOS; allowance depends on your plan."
      : c.provider === "antigravity" ? "Uses one running, signed-in Antigravity Desktop app for account allowance. Local CLI activity stays separate."
      : c.provider === "grok" ? state.platform === "win32" ? "Sign in through Grok Bot Desktop first, then allow read-only access to its sign-in store and allowance. No CLI or separate MeterUsage xAI sign-in is required. Beta compatibility, shared-pool coverage and the Windows reader remain unverified." : "Sign in through Grok Bot Desktop first, then allow read-only Keychain and allowance access. No CLI or separate MeterUsage xAI sign-in is required. Beta compatibility and shared-pool coverage remain unverified."
      : "Sign in through your browser for account allowance and provider-reported token history. Requires an existing Codex app or CLI.";
  const reading = state.snapshot.quotas[c.provider];
  const status = busy ? "Updating connection…" : c.source === "cli" ? localActive ? "CLI selected. Data appears when available." : "CLI selected. Collection is off."
    : c.status === "connected" ? reading?.status === "value" ? "Connected · Account allowance" : "Connection saved. Account allowance is unavailable."
      : c.status === "failed" ? "Connection failed. Check the message above and try again." : "Not connected.";
  const currentSource = c.source === "cli" ? localName : c.provider === "grok" && c.accountMethod === "cursor" ? "Grok Bot via Cursor (legacy Beta)" : accountName;
  return <div className="provider-setting connection-row">
    <div className="connection-summary"><div className="connection-identity"><Mark slot={primary(c.provider)} state={state} /><div><strong className="connection-title">{providerNames[c.provider]}{c.provider === "grok" && <> <span className="badge">Beta</span></>}</strong><p className="secondary">Current source: {currentSource}</p><p className="secondary connection-state">Collection: {collected ? "On" : "Off"} · Allowance: {reading?.status === "value" ? "Available" : reading?.status === "missing" ? reading.reason : "Not checked yet"}</p><p className="secondary connection-state" role="status">{status}</p></div></div><button aria-label={`Configure ${providerNames[c.provider]}`} aria-expanded={expanded} aria-controls={`connection-${c.provider}`} onClick={() => setExpanded(!expanded)}>{expanded ? "Close" : "Configure"}</button></div>
    <div className="connection-detail" id={`connection-${c.provider}`} hidden={!expanded}>
    <label className="setting connection-method"><span>Connect using</span><select aria-label={`${providerNames[c.provider]} connection method`} value={method} disabled={busy} onChange={e => setMethod(e.target.value as ConnectionState["source"])}>
      <option value="account" disabled={c.status === "unsupported"}>{accountName}</option>
      <option value="cli" disabled={!c.localAvailable}>{localName}</option>
    </select></label>
    <p className="secondary connection-help">{help}</p>
    {method === "cli" && c.source === "account" && <p className="secondary connection-help">Use CLI disconnects this MeterUsage account connection. Your other apps stay signed in.</p>}
    {!c.localAvailable && method === "cli" && !state.snapshot.demo && <p className="secondary">CLI selection is unavailable in this isolated test.</p>}
    <div className="connection-actions">
      <p className="secondary">{status}</p>
      {busy ? <button aria-label={`Cancel ${providerNames[c.provider]} connection`} onClick={() => void action({ action: "connectionCancel", provider: c.provider })}>Cancel</button>
        : method === "cli" ? <button disabled={!c.localAvailable || localActive} onClick={() => void action({ action: "connectionLocal", provider: c.provider })}>{localActive ? "CLI selected" : "Use CLI"}</button>
          : c.status === "connected" ? <button aria-label={`Disconnect ${providerNames[c.provider]}`} disabled={state.snapshot.demo} onClick={() => void action({ action: "disconnect", provider: c.provider })}>Disconnect</button>
            : c.status !== "unsupported" && <button className="connect-button" disabled={state.snapshot.demo} onClick={() => void action({ action: "connect", provider: c.provider })}>{c.provider === "claude" ? "Connect Claude Desktop" : c.provider === "antigravity" ? "Connect Antigravity Desktop" : c.provider === "grok" ? "Connect Grok Bot Desktop (Beta)" : "Sign in to Codex"}</button>}
      {c.provider === "claude" && c.status === "failed" && method === "account" && <button disabled={state.snapshot.demo || !c.localAvailable} onClick={() => void action({ action: "claudeUsagePage" })}>Open Claude usage</button>}
    </div>
    </div>
  </div>;
}
function ApiBillingDetails({ reading }: { reading: Extract<ApiBillingReading, { status: "value" }> }) {
  const value = reading.value;
  return <><p className="secondary">Provider-reported billing · USD · {new Date(value.monthStart).toISOString().slice(0, 10)} to {new Date(value.periodEnd).toISOString().slice(0, 10)} UTC</p><p className={reading.stale ? "stale" : "secondary"}>{reading.stale ? "Stale snapshot" : "Snapshot"} · {new Date(value.capturedAt).toISOString()}</p></>;
}
export function ApiBillingCards({ state }: { state: ViewState }) {
  return <>{apiBillingProviders.map(provider => {
    const reading = state.snapshot.apiBilling?.[provider];
    if (reading?.status !== "value") return null;
    return <section key={provider} className="provider-card" aria-label={`${apiBillingNames[provider]} billing`}><div className="row"><h2>{apiBillingNames[provider]} <small>API billing</small></h2><strong>{reading.value.daily.length ? `${money(reading.value.daily.reduce((sum, day) => sum + day.amountUSD, 0))} used` : "No cost buckets reported"}</strong></div><ApiBillingBalanceLine balance={reading.value.balance} /><ApiBillingDetails reading={reading} />{provider === "anthropic" && <p className="secondary">Priority Tier excluded.</p>}</section>;
  })}</>;
}
export function ApiBillingConnections({ state, action }: { state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  return <section className="connections" aria-label="API connections"><h2>API connections <small>Beta</small></h2><p className="secondary section-description">View organization API spend and, for OpenAI, the remaining credit balance. Use an Admin key, not a project key or ChatGPT or Claude subscription sign-in.</p><p className="secondary section-description">Use a saved key from the previous MeterUsage, or paste a one-time key. Pasted keys are cleared on submit and never saved.</p>{state.snapshot.demo && <p className="secondary connection-demo">API access is disabled in this profile.</p>}<div className="settings-group">{apiBillingProviders.map(provider => {
    const reading = state.snapshot.apiBilling?.[provider];
    return <div className="provider-setting connection-row" key={provider}><strong>{apiBillingNames[provider]}</strong>{reading?.status === "value" ? <><ApiBillingBalanceLine balance={reading.value.balance} /><ApiBillingDetails reading={reading} /></> : <p className="secondary">{reading?.code === "unavailable" ? "Billing snapshot unavailable. Fetch again to replace it." : "No billing snapshot yet."}</p>}<ApiBillingSetup provider={provider} disabled={state.snapshot.demo} action={action} savedKey={state.platform !== "win32"} />{provider === "openai" && <PrepaidCreditSetup values={state.settings.values} disabled={state.snapshot.demo} action={action} />}{provider === "anthropic" && <p className="secondary">Priority Tier costs are excluded.</p>}</div>;
  })}</div><p className="secondary">Fetch billing updates the snapshot automatically. Refresh rereads saved snapshots. OpenRouter keeps its existing connection.</p></section>;
}
export function Connections({ state, action }: { state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  const connections: ConnectionState[] = state.connections ?? ["codex", "claude", "antigravity", "grok"].map(provider => ({ provider: provider as ConnectionState["provider"], source: provider === "grok" ? "cli" : "account", localAvailable: !state.snapshot.demo, status: "disconnected" }));
  return <section className="connections" aria-label="Account connections">
    <h2>Choose how to connect</h2>
    <p className="secondary section-description">Choose a method for each provider. Changing the selection takes effect when you use its button.</p>
    {state.snapshot.demo && <p className="secondary connection-demo">Demo uses sample data. Account access is disabled.</p>}
    <div className="settings-group">{[...connections.map(c => <ConnectionRow key={`${c.provider}:${c.source}`} connection={c} state={state} action={action} />),
      <div key="muse" className="provider-setting connection-row" id="connection-muse">
        <div className="row"><div className="provider-heading"><Mark slot={primary("muse")} state={state} /><strong>Muse Code</strong></div><button disabled={state.snapshot.demo} onClick={() => void action({ action: "setPreference", key: "showProviderMuse", value: state.settings.values.showProviderMuse !== true })}>{state.settings.values.showProviderMuse === true ? "Stop Muse Code" : "Use Muse Code CLI"}</button></div>
        <p className="secondary">Uses your existing official Muse Code CLI sign-in. Reads its last observed subscription allowance without sending a prompt. Muse.ai allowance is separate.</p>
        <p className="secondary" role="status">Collection: {state.settings.values.showProviderMuse === true ? "On" : "Off"} · Allowance: {state.snapshot.quotas.muse?.status === "value" ? "Available" : reason(state.snapshot.quotas.muse)}</p>
      </div>,
      <div key="openCodeGo" className="provider-setting connection-row" id="connection-openCodeGo">
        <div className="row"><div className="provider-heading"><Mark slot={primary("openCodeGo")} state={state} /><strong>OpenCode Go</strong></div><button disabled={state.snapshot.demo} onClick={() => void action({ action: "setPreference", key: "showProviderOpenCodeGo", value: state.settings.values.showProviderOpenCodeGo !== true })}>{state.settings.values.showProviderOpenCodeGo === true ? "Stop local OpenCode" : "Use local OpenCode"}</button></div>
        <p className="secondary">Local Go activity needs no sign-in or key. An existing Go key also enables allowance.</p>
        <p className="secondary" role="status">{state.settings.values.showProviderOpenCodeGo === true ? "Local collection enabled" : "Local collection off"} · Activity: {state.snapshot.usages.openCodeGo?.status === "value" ? "Available" : reason(state.snapshot.usages.openCodeGo)} · Allowance: {state.snapshot.quotas.openCodeGo?.status === "value" ? "Available" : reason(state.snapshot.quotas.openCodeGo)}</p>
      </div>]}
    </div>
    {!state.snapshot.appearance.onboarding && <div className="onboarding-finish"><p className="secondary">You can skip setup and change these choices in Settings later.</p><button onClick={() => void action({ action: "setPreference", key: "onboardingCompleted", value: true })}>Done</button></div>}
  </section>;
}
export function UpdateNotice({ state, action }: { state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  const [pending, setPending] = useState(false), dispatching = useRef(false);
  const update = state.update;
  if (!update) return null;
  const busy = pending || update.state === "downloading" || update.state === "installing";
  const send = async (request: "updateInstall" | "updateDismiss") => {
    if (busy || dispatching.current) return;
    dispatching.current = true; setPending(true);
    try { await action({ action: request }); }
    finally { dispatching.current = false; setPending(false); }
  };
  return <section className="provider-card update-notice" aria-label="App update"><div className="row update-actions"><svg className="update-icon" aria-hidden="true" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2"><path d="M12 3v12m-5-5 5 5 5-5M5 16v5h14v-5" /></svg><span role="status">MeterUsage {update.version} available</span><button disabled={busy} onClick={() => void send("updateInstall")}>{update.state === "downloading" ? "Downloading…" : update.state === "installing" ? "Installing…" : pending ? "Please wait…" : update.state === "failed" ? "Retry update" : "Install update…"}</button><button disabled={busy} onClick={() => void send("updateDismiss")}>Dismiss</button></div></section>;
}
export function Settings({ state, action, saveOrder }: { state: ViewState; action: (r: Request) => Promise<boolean | void>; saveOrder: (order: Provider[]) => Promise<boolean> }) {
  const [category, setCategory] = useState("Connections");
  const categories = ["Connections", "API connections", "Appearance", "General", "Providers", "Side notch", "Usage details", "Diagnostics"];
  const values = state.settings.values, style = styleOf(values.interfaceStyle);
  // Classic and Ledger previews show the saved Theme (and Classic the saved Accent), as the app would.
  const previewTheme = values.appearanceTheme === "light" || values.appearanceTheme === "dark" ? values.appearanceTheme : state.systemDark ? "dark" : "light";
  const reportCoolingDown = (state.issueReport?.retryAt ?? 0) > state.snapshot.clock;
  const set = (key: string, value: string | boolean | number) => void action({ action: "setPreference", key, value });
  const toggle = (key: string, text: string, ariaLabel?: string, disabled = false, describedBy?: string) => <label className="setting" key={key}><span>{text}</span><input type="checkbox" aria-label={ariaLabel} aria-describedby={describedBy} checked={values[key] === true} disabled={disabled || (key === "launchAtLogin" && state.snapshot.demo)} onChange={e => set(key, e.target.checked)} /></label>;
  return <main className="settings">
    <header className="settings-header"><h1>Settings</h1><p className="secondary">Accounts, appearance and usage preferences.</p></header>
    <div className="settings-workspace"><nav className="settings-nav" aria-label="Settings categories">{categories.map(name => <button key={name} aria-current={category === name ? "page" : undefined} onClick={() => setCategory(name)}>{name}</button>)}</nav><div className="settings-content">
    <section hidden={category !== "Connections"}>
    {!state.snapshot.appearance.onboarding && <section className="provider-card onboarding"><h2>Your usage, at a glance</h2><p>Choose your existing CLI setup, browser sign-in or Desktop connection below. Each provider shows the methods it supports. Sign-in is optional.</p></section>}
    <Connections state={state} action={action} />
    </section>
    <section hidden={category !== "API connections"}>{category === "API connections" && <ApiBillingConnections state={state} action={action} />}</section>
    <section hidden={category !== "Appearance"}><h2>Appearance</h2><div className="settings-group">
      <fieldset className="style-picker" aria-describedby="style-help"><legend>Style</legend>
        <div className="style-options">{interfaceStyles.map(id => <label key={id} className={`style-option ui-${id}${styleInfo[id].palette === "fixed" ? "" : ` theme-${previewTheme}`}`} style={id === "classic" ? { "--brand": accents[String(values.accentTheme)] ?? accents.blue } as CSSProperties : undefined}><input type="radio" name="interfaceStyle" value={id} checked={style === id} onChange={() => set("interfaceStyle", id)} /><StylePreview id={id} now={state.snapshot.clock} /><span className="style-name">{styleInfo[id].name}</span><span className="style-tagline">{styleInfo[id].tagline}</span></label>)}</div>
        <p id="style-help" className="secondary">Reskins the usage panel, side notch and Settings. {styleInfo[style].palette === "follow" ? "Classic follows the Theme and Accent below." : styleInfo[style].palette === "theme" ? `${styleInfo[style].name} prints on paper in Light and on ink in Dark. It brings its own accent.` : `${styleInfo[style].name} brings its own palette, so Theme and Accent apply to Classic only.`}</p>
      </fieldset>
      <fieldset className="size-picker" aria-describedby="panel-size-help"><legend>Usage-panel size</legend>
        <div className="size-options">{Object.values(PanelSize).map(size => <label key={size}><input type="radio" name="panelSize" value={size} checked={String(values.panelSize ?? PanelSize.Medium) === size} onChange={() => set("panelSize", size)} /><span>{size[0].toUpperCase() + size.slice(1)}</span></label>)}</div>
        <p id="panel-size-help" className="secondary">Sizes the usage panel, notch details and Settings content. Small also hides service status and activity charts in the usage panel. Settings fits the selected page and scrolls when needed.</p>
      </fieldset>
      <label className="setting"><span>Theme</span><select value={String(values.appearanceTheme)} onChange={e => set("appearanceTheme", e.target.value)}>{["system", "light", "dark"].map(x => <option key={x} value={x}>{x[0].toUpperCase() + x.slice(1)}</option>)}</select></label>
      {styleInfo[style].palette === "follow" && <fieldset className="accent-picker"><legend>Accent color</legend>{Object.entries(accents).map(([name, color]) => <label key={name}><input type="radio" name="accentTheme" value={name} checked={values.accentTheme === name} onChange={() => set("accentTheme", name)} /><span className="accent-swatch" style={{ background: color }} aria-hidden="true" /><span>{name}</span></label>)}</fieldset>}
    </div></section>
    <section hidden={category !== "General"}><h2>General</h2><div className="settings-group">
      {["launchAtLogin", "quotaAlertsEnabled", "updateCheckEnabled"].map(k => toggle(k, labels[k]))}
      {toggle("updateAutoInstall", labels.updateAutoInstall, undefined, values.updateCheckEnabled !== true || state.snapshot.demo, "auto-install-help")}
      <p id="auto-install-help" className="secondary connection-help">Installs a verified update while you aren't using MeterUsage, then relaunches. A dismissed version is skipped.</p>
      <UpdateNotice state={state} action={action} />
      <label className="setting"><span>Refresh interval</span><select value={Number(values.refreshIntervalSeconds)} onChange={e => set("refreshIntervalSeconds", Number(e.target.value))}>{[30, 60, 120, 300, 900].map(x => <option key={x} value={x}>{x < 60 ? `${x}s` : `${x / 60}m`}</option>)}</select></label>
    </div></section>
    <section className="providers" hidden={category !== "Providers"}><h2>Providers</h2><p className="secondary section-description">Choose what to collect and where to show it.</p><p id="provider-order-help" className="secondary section-description">Drag a handle or use its arrow keys to reorder. Move up and down buttons also work. Additional accounts stay with their provider.</p><div className="settings-group">
      <ProviderOrder mark={p => <Mark slot={primary(p)} state={state} />} order={state.settings.providerOrder} save={saveOrder} controls={p => { const enabled = values[providerKey(p)] === true || state.snapshot.slots.some(slot => slot.provider === p && slot.slotID); return <>{toggle(providerKey(p), "Collect", `Collect ${providerNames[p]} usage`)}{toggle(trayKey(p), "Show", `Show ${providerNames[p]} in menu bar and side notch`, !enabled)}</>; }} />
      <details className="local-accounts"><summary>Advanced: local accounts</summary>{state.settings.accounts.map(a => <AccountRow key={a.id} account={a} action={action} />)}<div className="row"><button onClick={() => void action({ action: "accountAdd", provider: "codex" })}>Add Codex account…</button><button onClick={() => void action({ action: "accountAdd", provider: "claude" })}>Add Claude account…</button></div><p className="secondary">Choose a separate config directory. Each account keeps its own quota and history.</p></details>
    </div></section>
    <section hidden={category !== "Side notch"}><h2>Side notch</h2><div className="settings-group">{["sideNotchPanelEnabled", "showSideNotchResetButton"].map(k => toggle(k, labels[k]))}</div></section>
    <section hidden={category !== "Usage details"}><h2>Usage details</h2><div className="settings-group">{["menuBarCompactEnabled", "showHeatmap", "showClaudeHeatmap", "showCodexHeatmap", "showPacingBurnRate", "showActivityTelemetry", "showDailyActivityChart"].map(k => toggle(k, labels[k]))}</div></section>
    <section hidden={category !== "Diagnostics"}><h2>Diagnostics</h2><div className="settings-group diagnostics-actions"><p className="secondary">Sends a sanitized diagnostic report privately to MeterUsage support in Linear. No login needed. Credentials and chat content are excluded.</p><div className="row"><button disabled={state.issueReport?.sending || !!state.issueReport?.receipt || reportCoolingDown} onClick={() => void action({ action: "sendReport" })}>{state.issueReport?.sending ? "Sending…" : state.issueReport?.receipt ? "Sent" : "Send report"}</button><button onClick={() => void action({ action: "copyDiagnostics" })}>Copy diagnostics</button><button disabled={state.snapshot.clearingCache} onClick={() => void action({ action: "clearCache" })}>{state.snapshot.clearingCache ? "Clearing…" : "Clear local scan cache"}</button></div>{state.issueReport?.receipt && <p className="secondary" role="status">Report sent. Reference: {state.issueReport.receipt}</p>}{state.issueReport?.error && <p className="secondary" role="alert">{state.issueReport.error}</p>}{reportCoolingDown && !state.issueReport?.receipt && <p className="secondary" role="status">Next report attempt after {new Date(state.issueReport!.retryAt!).toLocaleTimeString()}. Please wait 10 minutes between attempts.</p>}<p className="secondary">Provider files and durable history stay intact.</p></div></section>
    </div></div>
    <p className="secondary settings-footer">MeterUsage{state.appVersion ? ` ${state.appVersion}` : ""} · Cost figures are local estimates.</p>
  </main>;
}
/** A live sample of a style: the real meter and notch gauge, rendered in that style's palette. */
function StylePreview({ id, now }: { id: InterfaceStyle; now: number }) {
  const sample: QuotaWindow = { label: "5-hour", usedPercent: 62, resetsAt: now + 150 * 60000, windowDurationMins: 300 };
  const info = styleInfo[id];
  return <span className="style-preview" aria-hidden="true"><StyleContext.Provider value={id}><span className="style-preview-gauge"><StripGauge kind={info.gauge} w={sample} now={now} pacing><span className="mark style-preview-mark" /></StripGauge><span className="strip-percent">{info.gauge === "flap" ? <Flap text="62" /> : info.gauge === "hp" ? "38" : "62%"}</span></span><Meter w={sample} now={now} pacing /></StyleContext.Provider></span>;
}
function AccountRow({ account: a, action }: { account: ViewState["settings"]["accounts"][number]; action: (r: Request) => Promise<boolean | void> }) {
  const [label, setLabel] = useState(a.label);
  useEffect(() => setLabel(a.label), [a.label]);
  return <div className="account-row"><div className="row"><label><span className="secondary">{providerNames[a.provider]} label</span><input aria-label={`${providerNames[a.provider]} account label`} maxLength={100} value={label} onChange={e => setLabel(e.target.value)} onBlur={() => { if (label !== a.label) void action({ action: "accountUpdate", id: a.id, label }); }} /></label><input aria-label={`Enable ${a.label || a.provider} account`} type="checkbox" checked={a.enabled} onChange={e => void action({ action: "accountUpdate", id: a.id, enabled: e.target.checked })} /><button onClick={() => void action({ action: "accountRemove", id: a.id })}>Remove</button></div><div className="row secondary"><span>{a.pathLabel}</span><button onClick={() => void action({ action: "accountPath", id: a.id })}>Change directory…</button></div></div>;
}
function TrayImage({ state }: { state: ViewState }) {
  const s = state.snapshot, counts = new Map<Provider, number>();
  const clusters = s.traySlots.flatMap(slot => {
    if (slot.slotID) counts.set(slot.provider, (counts.get(slot.provider) ?? 1) + 1);
    const key = slotKey(slot), fresh = extract(s.quotas[key]), q = fresh ?? s.archived[key], w = q && headlineWindow(slot.provider, q.windows), status = extract(s.statuses[slot.provider]);
    if (!w && (!status || status.severity === "operational")) return [];
    const p = s.appearance.pacing && w ? pace(w, s.clock) : undefined, eta = p && etaSeconds(p, w?.resetsAt, s.clock), ambient = p && (p.status === "deficit" || (eta !== undefined && eta < 7200));
    return [<span key={key} className="tray-cluster" style={{ opacity: q && !fresh ? .55 : 1 }}><Mark slot={slot} state={state} />{slot.slotID && <small>{counts.get(slot.provider)}</small>}{w && <span style={{ color: headroom(w.usedPercent) }}>{Math.round(w.usedPercent)}%</span>}{ambient && eta !== undefined && <span className="tray-eta" style={{ color: p?.status === "deficit" ? "var(--warn)" : "var(--text-muted)" }}>{formatETA(eta, true)}</span>}</span>];
  });
  return <div className="tray-image" aria-label="MeterUsage">{s.appearance.compactTray ? <svg width="9" height="13" viewBox="0 0 9 13"><rect x=".5" y=".5" width="8" height="12" rx="2" stroke="currentColor" fill="none" /><rect x="2" y="4.5" width="5" height="6.5" rx="1.5" fill="currentColor" /></svg> : clusters.length ? clusters : <span aria-label="Usage unavailable">–</span>}</div>;
}
/** The strip's per-provider gauge. Every kind keeps the 36-pixel strip width. */
function StripGauge({ kind, w, now, pacing, children }: { kind: GaugeKind; w: QuotaWindow; now: number; pacing: boolean; children: ReactNode }) {
  const used = clamp(w.usedPercent), marker = pacing ? paceMarker(w, now) : undefined, colour = headroom(w.usedPercent);
  if (kind === "twin") {
    const r1 = 11, r2 = 7.5, hot = marker !== undefined && used > marker + 10;
    return <span className="usage-ring gauge-twin" aria-hidden="true"><svg viewBox="0 0 24 24"><circle className="twin-track" cx="12" cy="12" r={r1} /><circle className="twin-track twin-inner-track" cx="12" cy="12" r={r2} />{marker !== undefined && <circle className="twin-time" cx="12" cy="12" r={r1} pathLength="100" strokeDasharray={`${marker} 100`} transform="rotate(-90 12 12)" />}<circle className="twin-used" cx="12" cy="12" r={r2} pathLength="100" strokeDasharray={`${used} 100`} transform="rotate(-90 12 12)" style={{ stroke: hot ? "var(--alert)" : undefined }} /></svg><span>{children}</span></span>;
  }
  if (kind === "vu" || kind === "hp") {
    const left = 100 - used;
    return <span className={`gauge-stack gauge-${kind}`} aria-hidden="true">{children}<span className="gauge-cells">{kind === "vu" ? segments(6, used, marker) : Array.from({ length: 5 }, (_, i) => <i key={i} style={(i + .5) * 20 < left ? { background: hpColour(left) } : undefined} />)}</span></span>;
  }
  if (kind === "ascii") return <span className="gauge-stack gauge-ascii" aria-hidden="true">{children}<span className="gauge-text">{asciiBar(used, marker, 5)}</span></span>;
  if (kind === "figure" || kind === "flap") return <span className={`gauge-stack gauge-${kind}`} aria-hidden="true">{children}</span>;
  return <span className="usage-ring" aria-hidden="true" style={{ background: `conic-gradient(${colour} ${used}%, var(--well) 0)` }}><span>{children}</span></span>;
}
function Notch({ state, action }: { state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  const entries = notchEntries(state.snapshot), selected = entries.find(e => e.key === state.notch.selected) ?? entries[0];
  const suppressClick = useRef(false), drag = useRef<{ id: number; x: number; y: number; started: boolean } | null>(null);
  const open = state.notch.expanded && !state.notch.dragging, gauge = useStyle().gauge;
  return <div className={`notch ${state.notch.cardOnRight ? "card-right" : "card-left"}`}
    onContextMenu={e => { e.preventDefault(); void action({ action: "notchContext" }); }}
    onPointerEnter={() => void action({ action: "notchHover", hovering: true })}
    onPointerLeave={() => void action({ action: "notchHover", hovering: false })}
    onPointerDown={e => {
      if (e.button !== 0 || (e.target as Element).closest(".detail-card button,.detail-card input,.detail-card select,.detail-card summary")) return;
      suppressClick.current = false; e.currentTarget.setPointerCapture(e.pointerId);
      drag.current = { id: e.pointerId, x: e.screenX, y: e.screenY, started: false };
    }}
    onPointerMove={e => { const d = drag.current; if (d && !d.started && Math.hypot(e.screenX - d.x, e.screenY - d.y) > 4) { d.started = true; void action({ action: "dragStart" }); } }}
    onPointerUp={e => { const d = drag.current; drag.current = null; if (d?.started) { suppressClick.current = true; void action({ action: "dragEnd" }); } if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId); }}
    onLostPointerCapture={() => { if (drag.current?.started) void action({ action: "dragEnd" }); drag.current = null; }}>
    <div className="strip">{entries.map(entry => {
      const { slot, key, window: w, fresh, digit } = entry;
      const name = slot.slotID ? `${providerNames[slot.provider]} · ${slot.label || `Account ${digit}`}` : providerNames[slot.provider];
      return <button className="strip-provider" style={{ opacity: fresh ? 1 : .55 }} key={key}
        aria-label={`Show ${name} details, ${Math.round(w.usedPercent)}% used${fresh ? "" : ", last known reading"}`}
        aria-pressed={open && selected?.key === key}
        onPointerEnter={() => { if (!drag.current?.started) void action({ action: "notchSelect", key }); }}
        onClick={() => { if (!suppressClick.current) void action({ action: "notchSelect", key }); }}>
        <StripGauge kind={gauge} w={w} now={state.snapshot.clock} pacing={state.snapshot.appearance.pacing}><Mark slot={slot} state={state} /></StripGauge>
        <span className="strip-percent" style={{ color: gauge === "hp" ? hpColour(100 - w.usedPercent) : headroom(w.usedPercent) }}>{gauge === "flap" ? <Flap text={String(Math.round(w.usedPercent))} /> : gauge === "hp" ? `${Math.max(0, 100 - Math.round(w.usedPercent))}` : `${Math.round(w.usedPercent)}%`}</span>
        {digit && <small>{digit}</small>}
      </button>;
    })}</div>
    {open && selected && <ProviderCard slot={selected.slot} state={state} action={action} detail />}
  </div>;
}
export function UsagePanel({ state, action }: { state: ViewState; action: (r: Request) => Promise<boolean | void> }) {
  const [selected, setSelected] = useState("");
  const slots = state.snapshot.slots;
  const slot = slots.find(slot => slotKey(slot) === selected) ?? slots[0];
  if (!slot) return <p className="empty">Enable a provider in Settings.</p>;
  const card = <ProviderCard key={slotKey(slot)} slot={slot} state={state} action={action} />;
  if (slots.length < 2) return <section className="usage-panel">{card}</section>;
  return <section className="usage-panel"><Tabs value={slotKey(slot)} onValueChange={value => setSelected(String(value))} className="gap-2">
    <TabsList activateOnFocus aria-label="Usage provider" className="provider-tabs h-8 w-full justify-start overflow-x-auto">{slots.map(item => {
      const digit = item.slotID ? slots.filter(s => s.provider === item.provider).indexOf(item) + 1 : undefined;
      const name = slotName(item) + (digit && !item.label ? ` ${digit}` : "");
      return <TabsTrigger key={slotKey(item)} value={slotKey(item)} aria-label={name} title={name} className="flex-none px-2"><Mark slot={item} state={state} />{digit && <small>{digit}</small>}</TabsTrigger>;
    })}</TabsList>
    <TabsContent value={slotKey(slot)}>{card}</TabsContent>
  </Tabs></section>;
}
export function App({ bridge }: { bridge: Bridge }) {
  const [state, setState] = useState<ViewState>(), [error, setError] = useState("");
  const surface = (new URLSearchParams(location.search).get("surface") ?? "flyout") as Surface;
  const panel = surface === "flyout" || surface === "settings";
  const content = useRef<HTMLDivElement>(null);
  useEffect(() => { const unsubscribe = bridge.subscribe(setState); void bridge.request({ action: "state" }).then(r => { if (r.ok && r.state) setState(r.state); else if (!r.ok) setError(r.error); }); return unsubscribe; }, [bridge]);
  useEffect(() => {
    const node = content.current; if (!node || !state) return;
    let last = 0;
    const observer = new ResizeObserver(() => {
      const height = Math.max(20, Math.ceil(panel ? node.getBoundingClientRect().height : node.scrollHeight)), width = surface === "tray" ? Math.ceil(node.scrollWidth) : undefined, size = width ?? height;
      if (size !== last) { last = size; void bridge.request(surface === "share" ? { action: "shareResize", height } : { action: "resize", height: panel ? height : Math.min(2000, height), ...(width === undefined ? {} : { width }) }); }
    }); observer.observe(node); return () => observer.disconnect();
  }, [bridge, !!state, surface, panel ? state?.settings.values.panelSize : undefined]);
  const action = async (r: Request) => { setError(""); try { const reply = await bridge.request(r); if (!reply.ok) setError(reply.error); return reply.ok; } catch { setError("Could not complete action"); return false; } };
  const saveOrder = async (order: Provider[]) => {
    setError("");
    try { const reply = await bridge.request({ action: "providerOrder", order }); if (!reply.ok) setError(reply.error); return reply.ok; }
    catch { setError("Could not save provider order"); return false; }
  };
  if (!state) return <p className="empty" role="status">{error || "Loading usage…"}</p>;
  const s = state.snapshot, scale = panelScales[state.settings.values.panelSize as PanelSize] ?? 1;
  const ui = styleOf(s.appearance.style), palette = styleInfo[ui].palette;
  // Fixed palettes are dark. Ledger follows Theme as paper or ink. The notch and share card stay dark.
  const theme = surface === "tray" ? state.systemDark ? "dark" : "light" : surface === "notch" || surface === "share" || palette === "fixed" ? "dark" : s.appearance.theme;
  const style = { ...(panel ? { zoom: scale } : {}), "--panel-scale": scale, ...(palette === "follow" || surface === "tray" ? { "--brand": accents[s.appearance.accent] ?? accents.blue } : {}), "--notch-max-height": state.notch.maxHeight === undefined ? "100dvh" : `${state.notch.maxHeight}px` } as CSSProperties;
  const app = <div ref={content} className={`app theme-${theme} ui-${surface === "tray" ? "classic" : ui} surface-${surface} size-${state.settings.values.panelSize ?? PanelSize.Medium}`} style={style}>{error && <div className="action-error" role="alert"><span>{error}</span><button aria-label="Dismiss error" onClick={() => setError("")}>×</button></div>}{surface === "share" ? (() => { const slot = notchEntries(s).find(e => e.key === state.notch.selected)?.slot; return slot ? <ProviderCard slot={slot} state={state} action={action} detail staticExport /> : <p className="empty">Card unavailable</p>; })() : surface === "tray" ? <TrayImage state={state} /> : surface === "settings" ? <Settings state={state} action={action} saveOrder={saveOrder} /> : surface === "notch" ? <Notch state={state} action={action} /> : <main className="flyout"><header className="app-header row"><h1>MeterUsage {s.demo && <small>Demo</small>}</h1><div className="header-actions flex gap-1.5"><Button variant="outline" size="xs" disabled={s.refreshing} onClick={() => void action({ action: "refresh" })}>{s.refreshing ? "Refreshing…" : "Refresh"}</Button><Button variant="outline" size="xs" onClick={() => void action({ action: "settings" })}>Settings</Button></div></header><UpdateNotice state={state} action={action} />{s.historyError && <p className="stale">History could not be {s.historyError === "loadFailed" ? "read. Repair the file and relaunch to resume saving" : "saved. Live readings remain available"}.</p>}{s.archiveWriteFailed && <p className="stale">Last known quota could not be saved.</p>}<ServiceStatuses state={state} action={action} /><UsagePanel state={state} action={action} /><ApiBillingCards state={state} /><Collapsible className="overview-details provider-card"><CollapsibleTrigger className="group/breakdown flex min-h-0 w-full items-center gap-1 rounded-none border-0 bg-transparent p-0 text-left text-xs text-muted-foreground hover:bg-transparent hover:text-foreground"><ChevronRight aria-hidden="true" className="size-3.5 transition-transform group-data-[panel-open]/breakdown:rotate-90" />All-provider activity breakdown</CollapsibleTrigger><CollapsibleContent keepMounted className="pt-2"><UnifiedStrip state={state} /><BurnCard state={state} /></CollapsibleContent></Collapsible><footer className="row secondary"><span>{s.lastRefreshedAt === undefined ? "Not refreshed yet" : `Updated ${new Date(s.lastRefreshedAt).toLocaleTimeString()}`}</span><span className="flex gap-1.5"><Button variant="outline" size="xs" onClick={() => void action({ action: "copyJSON" })}>Copy JSON</Button><Button variant="outline" size="xs" onClick={() => void action({ action: "quit" })}>Quit</Button></span></footer></main>}</div>;
  const themed = <StyleContext.Provider value={surface === "tray" ? "classic" : ui}>{app}</StyleContext.Provider>;
  return panel ? <ScrollArea className={`panel-viewport app theme-${theme} ui-${ui}`} role="region" aria-label={surface === "settings" ? "Settings" : "MeterUsage panel"}>{themed}</ScrollArea> : themed;
}
