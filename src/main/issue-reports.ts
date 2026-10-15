import { randomUUID } from "node:crypto";
import type { IssueReportState } from "../shared/ipc";

const endpoint = "https://meterusage-reports.fancy-queen-3301.workers.dev/report";
const failures = {
  tooLarge: "This report is too large to send. Copy diagnostics to keep the full report.",
  rateLimited: "Too many reports. Please wait a minute, then try again.",
  unconfirmed: "Delivery could not be confirmed. Try again or copy diagnostics.",
};
class ReportFailure extends Error {
  constructor(code: keyof typeof failures) { super(failures[code]); }
}
interface Report { schema: 1; id: string; diagnostics: string }

export async function sendIssueReport(report: Report, fetcher: typeof fetch = fetch): Promise<string> {
  const body = JSON.stringify(report);
  if (!report.diagnostics.length || Buffer.byteLength(report.diagnostics) > 49152 || Buffer.byteLength(body) > 65536) throw new ReportFailure("tooLarge");
  const response = await fetcher(endpoint, {
    method: "POST", redirect: "error", credentials: "omit", cache: "no-store",
    signal: AbortSignal.timeout(20000), headers: { "Content-Type": "application/json", Accept: "application/json" }, body,
  });
  if (response.status !== 201 || !response.body) {
    await response.body?.cancel();
    throw new ReportFailure(response.status === 429 ? "rateLimited" : "unconfirmed");
  }
  const reader = response.body.getReader(), chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > 1024) throw new ReportFailure("unconfirmed");
      chunks.push(value);
    }
    const receipt = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)));
    if (typeof receipt?.id !== "string" || receipt.id.toLowerCase() !== report.id.toLowerCase() || typeof receipt.identifier !== "string" || !/^[A-Z][A-Z0-9]{0,15}-[0-9]{1,12}$/.test(receipt.identifier)) throw new ReportFailure("unconfirmed");
    return receipt.identifier;
  } finally {
    await reader.cancel().catch(() => {});
    reader.releaseLock();
  }
}

// Keep one snapshot and UUID across retries and Settings navigation.
export class IssueReports {
  state: IssueReportState = { sending: false };
  private pending?: Report;
  constructor(private diagnostics: () => string, private changed: () => void, private send = sendIssueReport) {}
  async submit() {
    if (this.state.sending || this.state.receipt) return;
    this.state = { sending: true }; this.changed();
    try {
      this.pending ??= { schema: 1, id: randomUUID(), diagnostics: this.diagnostics() };
      const receipt = await this.send(this.pending);
      this.state = { sending: false, receipt }; this.pending = undefined;
    } catch (error) {
      this.state = { sending: false, error: error instanceof ReportFailure ? error.message : failures.unconfirmed };
    } finally { this.changed(); }
  }
}
