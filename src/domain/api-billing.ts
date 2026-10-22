export const apiBillingProviders = ["openai", "anthropic"] as const;
export type ApiBillingProvider = typeof apiBillingProviders[number];
export const apiBillingNames = { openai: "OpenAI API", anthropic: "Anthropic API" } as const;
export interface ApiBillingSnapshot {
  schema: 1; provider: ApiBillingProvider; capturedAt: number; monthStart: number; periodEnd: number; currency: "USD";
  daily: { start: number; end: number; amountUSD: number }[];
}
export type ApiBillingReading = { status: "value"; value: ApiBillingSnapshot; stale: boolean } | { status: "missing"; code: "notConfigured" | "unavailable" };
