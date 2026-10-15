import { type AccountActivity, Unavailable, failed } from "../../domain/models";

export function parseCodexAccountUsage(raw: string, capturedAt: number): AccountActivity {
  try {
    // Keep integer text until validation so JSON number rounding cannot hide fractions.
    const tokenText = new WeakMap<object, string>();
    const root = JSON.parse(raw, function (key: string, value: unknown, context?: { source: string }) {
      if (key === "tokens" && context) tokenText.set(this, context.source);
      return value;
    });
    if (root.error) throw root.error.code === -32600 ? new Unavailable("notSignedIn", "Codex") : failed("codex");
    const buckets = root.result?.dailyUsageBuckets;
    if (buckets === null || buckets === undefined) return { dailyUsageBuckets: null, capturedAt };
    if (!Array.isArray(buckets)) throw failed("codex");
    const dates = new Set<string>();
    const dailyUsageBuckets = buckets.map(bucket => {
      const { startDate, tokens } = bucket ?? {};
      if (typeof startDate !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(startDate) || !Number.isFinite(Date.parse(startDate)) || new Date(startDate).toISOString().slice(0, 10) !== startDate || dates.has(startDate) || !Number.isSafeInteger(tokens) || tokens < 0 || !/^(0|[1-9]\d*)$/.test(tokenText.get(bucket) ?? "")) throw failed("codex");
      dates.add(startDate);
      return { startDate, tokens };
    });
    return { dailyUsageBuckets, capturedAt };
  } catch (error) { throw error instanceof Unavailable ? error : failed("codex"); }
}
