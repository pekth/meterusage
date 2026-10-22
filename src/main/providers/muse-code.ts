import { Unavailable, quota, type QuotaWindow } from "../../domain/models";
import { selectJSON } from "../select-json";
import { object } from "./parsers";
import { boundedChild, type CommandOptions } from "./transport";

const unavailable = () => new Unavailable("noData", "Muse Code");
const usageShape = { observedAtMs: true, tier: true, window: { usedPercent: true, resetsAtMs: true, windowDurationMins: true }, weekly: { usedPercent: true, resetsAtMs: true } } as const;
const integer = (value: unknown): value is number => typeof value === "number" && Number.isSafeInteger(value) && value >= 0;

// MSP's percentages can exceed 100. Preserve the reported value; display rings
// clamp their geometry independently of the numeric reading.
export function museCodeQuota(raw: string, now: number) {
  try {
    const response = object(selectJSON(raw, { result: { usage: usageShape }, error: { code: true } }, undefined, true));
    if (response.error) throw unavailable();
    const usage = object(object(response.result).usage);
    if (!integer(usage.observedAtMs) || usage.observedAtMs === 0 || usage.observedAtMs > now) throw unavailable();
    const readWindow = (raw: unknown, label: string, duration?: number): QuotaWindow => {
      const value = object(raw), mins = duration ?? value.windowDurationMins;
      if (!integer(value.usedPercent) || !integer(value.resetsAtMs) || value.resetsAtMs <= now || value.resetsAtMs > 8640000000000000 || !integer(mins) || mins === 0) throw unavailable();
      return { label, usedPercent: value.usedPercent, resetsAt: value.resetsAtMs, windowDurationMins: mins };
    };
    const current = readWindow(usage.window, "Session"), weekly = readWindow(usage.weekly, "Weekly", 10080);
    const result = quota("muse", [current, weekly], usage.observedAtMs);
    if (typeof usage.tier === "string" && /^[A-Za-z0-9_-]{1,64}$/.test(usage.tier)) result.planType = usage.tier;
    return result;
  } catch { throw unavailable(); }
}

// Read only the host's observation. No session, model turn, login or logout is
// started, and authentication remains inside the installed official CLI.
export function museCodeRPC(binary: string, options: CommandOptions): Promise<string> {
  return boundedChild(binary, ["serve"], { ...options, timeoutMs: 20000, maxBytes: 1048576 }, (child, finish) => {
    const write = (message: unknown) => child.stdin.write(JSON.stringify({ jsonrpc: "2.0", ...message as object }) + "\n");
    let pending = "", initialized = false;
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => {
      pending += chunk;
      let newline: number;
      while ((newline = pending.indexOf("\n")) >= 0) {
        const line = pending.slice(0, newline); pending = pending.slice(newline + 1);
        if (!line.trim()) continue;
        try {
          const message = object(selectJSON(line, { jsonrpc: true, id: true, error: { code: true }, result: { experimentalApi: true } }, undefined, true));
          if (message.jsonrpc !== "2.0") throw unavailable();
          if (message.id === 1 && !initialized) {
            if (message.error || object(message.result).experimentalApi !== true) throw unavailable();
            initialized = true;
            write({ method: "initialized", params: {} });
            write({ id: 2, method: "usage/read", params: {} });
          } else if (message.id === 2 && initialized) { finish(line); return; }
        } catch { finish(unavailable()); return; }
      }
    });
    write({ id: 1, method: "initialize", params: { clientInfo: { name: "meterusage", version: "0.2.41" }, capabilities: { experimentalApi: true, userInputDialogs: false } } });
  });
}
