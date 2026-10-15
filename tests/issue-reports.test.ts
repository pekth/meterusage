import { it, expect, vi } from "vite-plus/test";
import { IssueReports, sendIssueReport } from "../src/main/issue-reports";

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
  const reports = new IssueReports(() => report.diagnostics, () => {}, r => sendIssueReport(r, vi.fn<typeof fetch>().mockResolvedValue(Response.json(body, { status }))));
  await reports.submit();
  expect(reports.state).toEqual({ sending: false, error: "Delivery could not be confirmed. Try again or copy diagnostics." });
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
  const reports = new IssueReports(() => report.diagnostics, () => {}, r => sendIssueReport(r, vi.fn<typeof fetch>().mockResolvedValue(response)));
  await reports.submit(); expect(reports.state.error).toBe("Delivery could not be confirmed. Try again or copy diagnostics.");
});

it("cancels rate-limit response bodies and shows a fixed retry message", async () => {
  const cancel = vi.fn();
  const body = new ReadableStream<Uint8Array>({ cancel });
  const reports = new IssueReports(() => report.diagnostics, () => {}, r => sendIssueReport(r, vi.fn<typeof fetch>().mockResolvedValue(new Response(body, { status: 429 }))));
  await reports.submit(); expect(reports.state.error).toBe("Too many reports. Please wait a minute, then try again.");
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
  const reports = new IssueReports(() => report.diagnostics, changed, send);
  const first = reports.submit();
  expect(reports.state).toEqual({ sending: true });
  await reports.submit(); expect(send).toHaveBeenCalledOnce();
  resolve("MU-123"); await first;
  expect(reports.state).toEqual({ sending: false, receipt: "MU-123" });
  await reports.submit(); expect(send).toHaveBeenCalledOnce(); expect(changed).toHaveBeenCalledTimes(2);
});

it("retries uncertain delivery with the same UUID and snapshot, redacting raw errors", async () => {
  const diagnostics = vi.fn().mockReturnValueOnce(report.diagnostics).mockReturnValue("different snapshot");
  const send = vi.fn().mockRejectedValueOnce(new Error("private token and /private/path")).mockResolvedValue("MU-124");
  const reports = new IssueReports(diagnostics, () => {}, send);
  await reports.submit(); expect(reports.state.error).toBe("Delivery could not be confirmed. Try again or copy diagnostics.");
  await reports.submit();
  expect(send.mock.calls[1][0]).toEqual(send.mock.calls[0][0]);
  expect(send.mock.calls[0][0].id).toMatch(/^[a-f0-9-]{14}4[a-f0-9-]{21}$/);
  expect(diagnostics).toHaveBeenCalledOnce(); expect(reports.state).toEqual({ sending: false, receipt: "MU-124" });
});
