/** Interface styles reskin every surface. Each one picks a quota meter, a notch gauge and an activity chart. */
export const interfaceStyles = ["classic", "flightDeck", "orbit", "ledger", "terminal", "blueprint", "departures", "arcade"] as const;
export type InterfaceStyle = typeof interfaceStyles[number];
export type MeterKind = "bar" | "tape" | "rule" | "ascii" | "flap" | "orbit" | "hp";
export type GaugeKind = "conic" | "twin" | "vu" | "figure" | "flap" | "ascii" | "hp";
export type ChartKind = "grid" | "trace" | "bars" | "spark";
export interface StyleInfo {
  name: string; tagline: string; meter: MeterKind; gauge: GaugeKind; chart: ChartKind;
  /** "follow" uses the Theme and Accent settings; "fixed" brings its own palette. Ledger follows Theme as paper or ink. */
  palette: "follow" | "theme" | "fixed";
}
export const styleInfo: Record<InterfaceStyle, StyleInfo> = {
  classic: { name: "Classic", tagline: "System look with bars and rings", meter: "bar", gauge: "conic", chart: "grid", palette: "follow" },
  flightDeck: { name: "Flight Deck", tagline: "Amber LED tapes with a pace needle", meter: "tape", gauge: "vu", chart: "trace", palette: "fixed" },
  orbit: { name: "Orbit", tagline: "Rings that track time against quota", meter: "orbit", gauge: "twin", chart: "bars", palette: "fixed" },
  ledger: { name: "Ledger", tagline: "Serif figures on newsprint", meter: "rule", gauge: "figure", chart: "bars", palette: "theme" },
  terminal: { name: "Terminal", tagline: "Green phosphor with ASCII bars", meter: "ascii", gauge: "ascii", chart: "spark", palette: "fixed" },
  blueprint: { name: "Blueprint", tagline: "Quotas drawn as dimension lines", meter: "rule", gauge: "twin", chart: "trace", palette: "fixed" },
  departures: { name: "Departures", tagline: "Split-flap board with reset times", meter: "flap", gauge: "flap", chart: "bars", palette: "fixed" },
  arcade: { name: "Arcade", tagline: "Quota left shown as hit points", meter: "hp", gauge: "hp", chart: "bars", palette: "fixed" },
};
export const validInterfaceStyle = (v: unknown): v is InterfaceStyle => typeof v === "string" && (interfaceStyles as readonly string[]).includes(v);
export const styleOf = (v: unknown): InterfaceStyle => validInterfaceStyle(v) ? v : "classic";
