import { it, expect, vi, beforeEach, afterEach } from "vite-plus/test";
import { IssueReports, sendIssueReport } from "../src/main/issue-reports";

const now = Date.parse("2026-10-15T12:00:00Z"), retryAt = now + 10 * 60 * 1000;
beforeEach(() => { vi.useFakeTimers(); vi.setSystemTime(now); });
afterEach(() => { vi.useRealTimers(); });
function preferences() {
  const values: Record<string, number> = {};
  return { values, set: vi.fn(async (key: string, value: unknown) => { values[key] = value as number; }) };
}

const report = { schema: 1 as const, id: "12345678-1234-4123-8123-123456789abc", diagnostics: "MeterUsage fixture\nquota: unavailable (offline)" };
const receipt = { id: report.id.toUpperCase(), identifier: "MU-123" };

it("posts only the generated report to the fixed relay and verifies its receipt", async () => {
  const fetcher = vi.fn<typeof fetch>().mockResolvedValue(Response.json(receipt, { status: 201 }));
  expect(await sendIssueReport(report, fetcher)).toBe("MU-123");
  expect(fetcher).toHaveBeenCalledExactlyOnceWith("https://meterusage-reports.fancy-queen-3301.workers.dev/report", {
    method: "POST", redirect: "error", credentials: "omit", cache: "no-store", signal: expect.any(AbortSignal),
    headers: { "Content-Type": "application/json", Accept: "application/json" }, body: JSON.stringify(report),
  });
});

it.each([
  [200, receipt], [201, { ...receipt, id: "different" }], [201, { ...receipt, identifier: "MU-123\nsecret" }],
  [201, { ...receipt, identifier: "https://example.invalid" }], [201, null], [500, { error: "private server error" }],
])("rejects status %s or an invalid receipt", async (status, body) => {
  const reports = new IssueReports(() => report.diagnostics, () => {}, preferences(), r => sendIssueReport(r, vi.fn<typeof fetch>().mockResolvedValue(Response.json(body, { status }))));
  await reports.submit();
  expect(reports.state).toEqual({ sending: false, error: "Delivery could not be confirmed. Try again or copy diagnostics.", retryAt });
});

it("caps streamed response bytes and cancels the reader", async () => {
  const cancel = vi.fn();
  const body = new ReadableStream<Uint8Array>({ start(c) { c.enqueue(new Uint8Array(1025)); }, cancel });
  const response = new Response(body, { status: 201 });
  await expect(sendIssueReport(report, vi.fn<typeof fetch>().mockResolvedValue(response))).rejects.toThrow("Delivery could not be confirmed");
  expect(cancel).toHaveBeenCalledOnce(); expect(body.locked).toBe(false);
});

it.each(["not json", new Uint8Array([0xff])])("rejects malformed response data without exposing it", async body => {
  const response = new Response(body, { status: 201 });
  const reports = new IssueReports(() => report.diagnostics, () => {}, preferences(), r => sendIssueReport(r, vi.fn<typeof fetch>().mockResolvedValue(response)));
  await reports.submit(); expect(reports.state.error).toBe("Delivery could not be confirmed. Try again or copy diagnostics.");
});

it("cancels rate-limit response bodies and shows a fixed retry message", async () => {
  const cancel = vi.fn();
  const body = new ReadableStream<Uint8Array>({ cancel });
  const reports = new IssueReports(() => report.diagnostics, () => {}, preferences(), r => sendIssueReport(r, vi.fn<typeof fetch>().mockResolvedValue(new Response(body, { status: 429 }))));
  await reports.submit(); expect(reports.state.error).toBe("Too many reports. Try again later or copy diagnostics.");
  expect(cancel).toHaveBeenCalledOnce();
});

it.each(["", "é".repeat(24577), "\n".repeat(40000)])("refuses empty or oversized UTF-8/JSON payloads before network access", async diagnostics => {
  const fetcher = vi.fn<typeof fetch>();
  await expect(sendIssueReport({ ...report, diagnostics }, fetcher)).rejects.toThrow("This report is too large");
  expect(fetcher).not.toHaveBeenCalled();
});

it("deduplicates in-flight clicks and retains success across Settings navigation", async () => {
  let resolve!: (value: string) => void;
  const send = vi.fn(() => new Promise<string>(r => { resolve = r; })), changed = vi.fn();
  const reports = new IssueReports(() => report.diagnostics, changed, preferences(), send);
  const first = reports.submit();
  expect(reports.state).toEqual({ sending: true, retryAt });
  await reports.submit(); expect(send).toHaveBeenCalledOnce();
  resolve("MU-123"); await first;
  expect(reports.state).toEqual({ sending: false, receipt: "MU-123", retryAt });
  await reports.submit(); expect(send).toHaveBeenCalledOnce(); expect(changed).toHaveBeenCalledTimes(2);
});

it("retries uncertain delivery with the same UUID and snapshot, redacting raw errors", async () => {
  const diagnostics = vi.fn().mockReturnValueOnce(report.diagnostics).mockReturnValue("different snapshot");
  const send = vi.fn().mockRejectedValueOnce(new Error("private token and /private/path")).mockResolvedValue("MU-124");
  const reports = new IssueReports(diagnostics, () => {}, preferences(), send);
  await reports.submit(); expect(reports.state.error).toBe("Delivery could not be confirmed. Try again or copy diagnostics.");
  for (let i = 0; i < 20; i++) await reports.submit();
  expect(send).toHaveBeenCalledOnce();
  vi.setSystemTime(retryAt);
  await reports.submit();
  expect(send.mock.calls[1][0]).toEqual(send.mock.calls[0][0]);
  expect(send.mock.calls[0][0].id).toMatch(/^[a-f0-9-]{14}4[a-f0-9-]{21}$/);
  expect(diagnostics).toHaveBeenCalledOnce(); expect(reports.state).toEqual({ sending: false, receipt: "MU-124", retryAt: retryAt + 10 * 60 * 1000 });
});


it("keeps the cooldown after relaunch and reserves it before sending", async () => {
  const prefs = preferences();
  const send = vi.fn(async () => {
    expect(prefs.values.reportNextAllowedAt).toBe(retryAt);
    throw new Error("Uncertain delivery");
  });
  await new IssueReports(() => report.diagnostics, () => {}, prefs, send).submit();
  const relaunched = new IssueReports(() => report.diagnostics, () => {}, prefs, send);
  expect(relaunched.state).toEqual({ sending: false, retryAt });
  await relaunched.submit(); expect(send).toHaveBeenCalledOnce();
  vi.setSystemTime(retryAt - 1);
  await relaunched.submit(); expect(send).toHaveBeenCalledOnce();
  vi.setSystemTime(retryAt);
  expect(relaunched.state).toEqual({ sending: false });
  expect(send).toHaveBeenCalledOnce();
});

it("does not contact the relay if saving the cooldown fails", async () => {
  const prefs = preferences(), send = vi.fn();
  prefs.set.mockRejectedValue(new Error("private storage failure"));
  const reports = new IssueReports(() => report.diagnostics, () => {}, prefs, send);
  await reports.submit();
  expect(send).not.toHaveBeenCalled();
  expect(reports.state).toEqual({ sending: false, error: "Could not save the report cooldown. Nothing was sent. Copy diagnostics instead." });
});
