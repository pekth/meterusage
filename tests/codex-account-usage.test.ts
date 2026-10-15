import { expect, it } from "vite-plus/test";
import { parseCodexAccountUsage } from "../src/main/providers/codex-account-usage";
const now = Date.parse("2026-10-12T12:00:00Z");
const raw = (dailyUsageBuckets: unknown) => JSON.stringify({ result: { summary: { lifetimeTokens: 999999, currentStreakDays: 10 }, dailyUsageBuckets, accountId: "OMIT_SYNTHETIC_ID", unknown: { tokens: 1.5 } } });
it("preserves exact reported dates, gaps and zero, discarding summary and unknown fields", () => {
  expect(parseCodexAccountUsage(raw([{ startDate: "2024-02-29", tokens: 0, private: "OMIT" }, { startDate: "2024-03-02", tokens: Number.MAX_SAFE_INTEGER }]), now)).toEqual({ capturedAt: now, dailyUsageBuckets: [{ startDate: "2024-02-29", tokens: 0 }, { startDate: "2024-03-02", tokens: Number.MAX_SAFE_INTEGER }] });
});
it.each([null, undefined, []])("does not invent daily history from a summary: %s", buckets => {
  expect(parseCodexAccountUsage(raw(buckets), now)).toEqual({ capturedAt: now, dailyUsageBuckets: buckets === undefined ? null : buckets });
});
it.each([
  [{ startDate: "2023-02-29", tokens: 1 }], [{ startDate: "2024-04-31", tokens: 1 }], [{ startDate: "2024-1-01", tokens: 1 }], [{ startDate: "2024-01-01T00:00:00Z", tokens: 1 }], [{ startDate: "bad", tokens: 1 }],
  [{ startDate: "2024-01-01", tokens: -1 }], [{ startDate: "2024-01-01", tokens: 1.1 }], [{ startDate: "2024-01-01", tokens: Number.MAX_SAFE_INTEGER + 1 }], [{ startDate: "2024-01-01", tokens: "1" }], [{ startDate: "2024-01-01", tokens: null }],
  [{ startDate: "2024-01-01", tokens: 1 }, { startDate: "2024-01-01", tokens: 2 }], [null], [1], {}, "bad",
])("rejects malformed, duplicate or unsafe buckets: %j", buckets => {
  expect(() => parseCodexAccountUsage(raw(buckets), now)).toThrow("Couldn't read Codex usage");
});
it.each(["9223372036854775807", "9007199254740991.1", "-0", "1e2"])("rejects unsafe or non-integer protocol text before rounding: %s", tokens => {
  expect(() => parseCodexAccountUsage(`{"result":{"dailyUsageBuckets":[{"startDate":"2024-01-01","tokens":${tokens}}]}}`, now)).toThrow();
});
it("uses fixed errors without publishing provider error text", () => {
  expect(() => parseCodexAccountUsage('{"error":{"code":-32600,"message":"OMIT_PRIVATE_ERROR"}}', now)).toThrow("Not signed in");
  expect(() => parseCodexAccountUsage('{"error":{"code":-32603,"message":"OMIT_PRIVATE_ERROR"}}', now)).toThrow("Couldn't read Codex usage");
  expect(() => parseCodexAccountUsage("bad", now)).toThrow("Couldn't read Codex usage");
});
