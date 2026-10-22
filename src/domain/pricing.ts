import type { Tokens } from "./models";
export const pricingSnapshot = "2026-09";
// Same USD-per-million table and ordering as Services/Pricing.swift.
const rates: [string, number[]][] = [
  ["6.1-sol", [2, 10, .10, 0]], ["6-astra", [10, 50, 1, 0]],
  ["5.6-sol", [4, 20, .4, 0]], ["5.6-terra", [2, 12, .2, 0]], ["5.6-luna", [.2, 1.2, .02, 0]],
  ["6-luna", [.1, .5, .01, 0]], ["6-sol", [2, 10, .2, 0]], ["5.3-codex", [1.75, 14, .175, 0]],
  ["fable", [10, 50, 1, 12.5]], ["opus", [4, 20, .4, 5]], ["haiku", [1, 5, .1, 1.25]], ["sonnet", [2, 10, .2, 2.5]],
];
export function estimate(model: string, t: Tokens): { costUSD: number; isFallback: boolean } {
  const lower = model.toLowerCase(), openAI = /gpt|codex/.test(lower);
  const match = rates.slice(openAI ? 0 : 8, openAI ? 8 : undefined).find(([name]) => lower.includes(name));
  const r = match?.[1] ?? (openAI ? rates[0][1] : rates[11][1]);
  return { costUSD: (t.input * r[0] + (t.output + t.reasoning) * r[1] + t.cacheRead * r[2] + t.cacheWrite * r[3]) / 1e6, isFallback: !match };
}
