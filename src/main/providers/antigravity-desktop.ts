import { createHash } from "node:crypto";
import { userInfo } from "node:os";
import { request as httpRequest, type RequestOptions, type ClientRequest, type IncomingMessage } from "node:http";
import { request as httpsRequest } from "node:https";
import { Unavailable, quota, window, type QuotaWindow, type QuotaGroup } from "../../domain/models";
import { selectJSON } from "../select-json";
import { object, displayText } from "./parsers";
import { runCommand, type Command } from "./transport";

const unavailable = () => new Unavailable("notSignedIn", "Antigravity Desktop");
const noData = () => new Unavailable("noData");
const methods = { GetUserStatus: { metadata: { ideName: "antigravity", extensionName: "antigravity", ideVersion: "unknown", locale: "en" } }, RetrieveUserQuotaSummary: { forceRefresh: true } };
type Method = keyof typeof methods;
interface DesktopServer { pid: number; executable: string; csrf: string; extensionPort?: number; extensionCSRF?: string; ports: number[] }
export interface AntigravityEndpoint { pid: number; port: number; csrf: string; scheme: "https:" | "http:"; extensionPort?: number }
export type AntigravityRPC = (endpoint: AntigravityEndpoint, method: Method, signal: AbortSignal) => Promise<string>;
const portNumber = (raw: string) => { const n = Number(raw); return /^\d+$/.test(raw) && n > 0 && n <= 65535 ? n : undefined; };
const token = (raw: string | undefined) => raw !== undefined && /^[\x21-\x7e]{1,512}$/.test(raw) ? raw : undefined;
const executable = (path: string) => /^\/.*\/(?:Antigravity|Antigravity IDE)\.app\/Contents\/[^\r\n]*\/language_server(?:_[a-zA-Z0-9_-]+)?$/.test(path);
function flag(args: string, name: string) {
  const matches = [...args.matchAll(new RegExp(`(?:^|\\s)--${name}(?:=|\\s+)([^\\s]+)`, "g"))];
  if (matches.length > 1) throw unavailable();
  return matches[0]?.[1];
}

// Enumerate executable names first. Only a matching, same-user PID exposes arguments.
export async function discoverAntigravity(command: Command = runCommand, signal?: AbortSignal): Promise<DesktopServer> {
  const options = { signal, timeoutMs: 3000, maxBytes: 1048576 }, uid = userInfo().uid;
  const processes = await command("/bin/ps", ["-axo", "pid=,uid=,comm="], options);
  const candidates = processes.split("\n").flatMap(line => {
    const match = line.trim().match(/^(\d+)\s+(\d+)\s+(.+)$/);
    return match && Number(match[2]) === uid && executable(match[3]) ? [{ pid: Number(match[1]), executable: match[3] }] : [];
  });
  if (candidates.length !== 1 || !Number.isSafeInteger(candidates[0].pid) || candidates[0].pid <= 0) throw unavailable();
  const candidate = candidates[0];
  const commandLine = (await command("/bin/ps", ["-ww", "-p", String(candidate.pid), "-o", "command="], { ...options, maxBytes: 16384 })).trim();
  if (!commandLine.startsWith(candidate.executable + " ")) throw unavailable();
  const args = commandLine.slice(candidate.executable.length), csrf = token(flag(args, "csrf_token"));
  if (!csrf) throw unavailable();
  const declaredPort = flag(args, "extension_server_port"), extensionPort = declaredPort === undefined ? undefined : portNumber(declaredPort);
  const declaredToken = flag(args, "extension_server_csrf_token"), extensionCSRF = token(declaredToken);
  if (declaredPort !== undefined && extensionPort === undefined || declaredToken !== undefined && !extensionCSRF) throw unavailable();
  const listeners = await command("/usr/sbin/lsof", ["-nP", "-a", "-p", String(candidate.pid), "-iTCP", "-sTCP:LISTEN", "-Fpn"], { ...options, maxBytes: 32768 });
  let owner: number | undefined;
  const ports = new Set<number>();
  for (const line of listeners.split("\n")) {
    if (line.startsWith("p")) owner = Number(line.slice(1));
    const match = line.match(/^n127\.0\.0\.1:(\d+)$/), port = match && portNumber(match[1]);
    if (owner === candidate.pid && port) ports.add(port);
  }
  if (!ports.size || ports.size > 8) throw unavailable();
  signal?.throwIfAborted();
  return { ...candidate, csrf, extensionPort, extensionCSRF, ports: [...ports].sort((a, b) => a - b) };
}
function endpoints(server: DesktopServer): AntigravityEndpoint[] {
  const common = { pid: server.pid, extensionPort: server.extensionPort };
  const secure: AntigravityEndpoint[] = server.ports.map(port => ({ ...common, port, csrf: server.csrf, scheme: "https:" }));
  if (server.extensionPort && server.ports.includes(server.extensionPort)) {
    secure.push({ ...common, port: server.extensionPort, csrf: server.extensionCSRF ?? server.csrf, scheme: "http:" });
  }
  return secure;
}
class UnsupportedQuotaRPC extends Error {}
type Send = (options: RequestOptions, callback: (response: IncomingMessage) => void) => ClientRequest;
// TLS relaxation belongs only to this literal loopback request, never a global agent.
export function antigravityRPC(endpoint: AntigravityEndpoint, method: Method, signal: AbortSignal, send: Send = (options, callback) => (options.protocol === "https:" ? httpsRequest : httpRequest)(options, callback)): Promise<string> {
  return new Promise((resolve, reject) => {
    if (!Object.hasOwn(methods, method) || !["https:", "http:"].includes(endpoint.scheme) || !Number.isInteger(endpoint.port) || endpoint.port < 1 || endpoint.port > 65535 || !token(endpoint.csrf) || endpoint.scheme === "http:" && endpoint.port !== endpoint.extensionPort || signal.aborted) { reject(noData()); return; }
    const body = JSON.stringify(methods[method]);
    let settled = false, request: ClientRequest | undefined;
    const finish = (error?: Error, raw?: string) => {
      if (settled) return; settled = true; clearTimeout(timer); signal.removeEventListener("abort", abort);
      if (error) { request?.destroy(); reject(error); } else resolve(raw!);
    };
    const abort = () => finish(noData());
    const timer = setTimeout(abort, 3000);
    signal.addEventListener("abort", abort, { once: true });
    try {
      request = send({ protocol: endpoint.scheme, hostname: "127.0.0.1", port: endpoint.port, path: `/exa.language_server_pb.LanguageServerService/${method}`, method: "POST", agent: false, ...(endpoint.scheme === "https:" ? { rejectUnauthorized: false } : {}), headers: { "Content-Type": "application/json", "Content-Length": Buffer.byteLength(body), "Connect-Protocol-Version": "1", "X-Codeium-Csrf-Token": endpoint.csrf } }, response => {
        const code = response.statusCode;
        if (code !== 200) { response.resume(); finish(method === "RetrieveUserQuotaSummary" && (code === 404 || code === 501) ? new UnsupportedQuotaRPC() : noData()); return; }
        let bytes = 0; const chunks: Buffer[] = [];
        if (Number(response.headers["content-length"]) > 1048576) { response.destroy(); finish(noData()); return; }
        response.on("data", (chunk: Buffer) => { bytes += chunk.length; if (bytes > 1048576) { response.destroy(); finish(noData()); } else chunks.push(chunk); });
        response.on("error", () => finish(noData()));
        response.on("aborted", () => finish(noData()));
        response.on("end", () => finish(undefined, Buffer.concat(chunks).toString("utf8")));
      });
      request.on("error", () => finish(noData()));
      if (settled) request.destroy(); else request.end(body);
    } catch { finish(noData()); }
  });
}
const label = (raw: unknown) => { const value = displayText(raw); return value && !/[\x00-\x1f\x7f]/.test(value) ? value : undefined; };
const bucketSelection = { bucketId: true, id: true, displayName: true, name: true, disabled: true, remainingFraction: true, remaining: { remainingFraction: true, case: true, value: true }, resetTime: true } as const;
const summarySelection = { groups: { '*': { displayName: true, name: true, buckets: { '*': bucketSelection } } } } as const;
const statusSelection = { code: true, userStatus: { email: true, userTier: { name: true }, planStatus: { planInfo: { planName: true, planDisplayName: true, displayName: true, productName: true, planShortName: true } }, cascadeModelConfigData: { clientModelConfigs: { '*': { label: true, quotaInfo: { remainingFraction: true, resetTime: true } } } } } } as const;
function success(root: Record<string, unknown>) {
  if (root.code !== undefined && ![0, "0", "ok", "OK", "success", "SUCCESS"].includes(root.code as string | number)) throw noData();
}
export function antigravityIdentity(raw: string) {
  const root = object(selectJSON(raw, statusSelection)); success(root);
  const status = object(root.userStatus), email = status.email;
  if (typeof email !== "string" || email.length > 320 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) throw unavailable();
  return createHash("sha256").update("antigravity-desktop\0" + email.toLowerCase()).digest("hex");
}
function reading(name: string | undefined, fraction: unknown, reset: unknown, now: number): QuotaWindow[] {
  if (!name || typeof fraction !== "number" || !Number.isFinite(fraction) || fraction < 0 || fraction > 1) return [];
  const resetsAt = typeof reset === "string" ? Date.parse(reset) : undefined;
  if (reset != null && (resetsAt === undefined || !Number.isFinite(resetsAt) || resetsAt <= now)) return [];
  return [window(name, (1 - fraction) * 100, resetsAt)];
}
export function antigravityDesktopQuota(raw: string, statusRaw: string, now: number, legacy = false) {
  const statusRoot = object(selectJSON(statusRaw, statusSelection)); success(statusRoot);
  const status = object(statusRoot.userStatus), plan = object(object(status.planStatus).planInfo);
  let windows: QuotaWindow[];
  const quotaGroups: QuotaGroup[] = [];
  if (legacy) {
    const configs = object(status.cascadeModelConfigData).clientModelConfigs;
    windows = Array.isArray(configs) ? configs.flatMap(config => { const c = object(config), q = object(c.quotaInfo); return reading(label(c.label), q.remainingFraction, q.resetTime, now); }) : [];
  } else {
    const root = object(selectJSON(raw, { code: true, ...summarySelection, response: summarySelection, summary: summarySelection }));
    if ([12, "12", "unimplemented"].includes(root.code as number | string)) throw new UnsupportedQuotaRPC();
    success(root);
    const payload = object(root.response ?? root.summary ?? root), groups = payload.groups;
    windows = Array.isArray(groups) ? groups.flatMap(value => {
      const group = object(value), rawGroupName = label(group.displayName ?? group.name);
      const groupName = rawGroupName?.replace(/^Gemini Models$/i, "Gemini").replace(/^Claude and GPT models$/i, "Claude/GPT");
      const groupWindows: QuotaWindow[] = [];
      const flat = Array.isArray(group.buckets) ? group.buckets.flatMap(value => {
        const bucket = object(value), remaining = object(bucket.remaining);
        if (!label(bucket.bucketId ?? bucket.id) || bucket.disabled != null && bucket.disabled !== false) return [];
        const fraction = bucket.remainingFraction ?? remaining.remainingFraction ?? (remaining.case === "remainingFraction" ? remaining.value : undefined);
        const bucketName = (label(bucket.displayName ?? bucket.name) ?? label(bucket.bucketId ?? bucket.id))?.replace(/ Limit Remaining$/i, "").replace(/^Five Hour$/i, "5-hour");
        const parsed = reading(bucketName, fraction, bucket.resetTime, now);
        for (const w of parsed) {
          const duration = /^(?:Weekly|Weekly Limit)$/i.test(w.label) ? 10080 : /^(?:5-hour|5-hour Limit)$/i.test(w.label) ? 300 : undefined;
          if (duration !== undefined) w.windowDurationMins = duration;
          groupWindows.push({ ...w, label: w.label + (/limit/i.test(w.label) ? "" : " limit") });
        }
        return parsed.map(w => ({ ...w, label: groupName ? `${groupName} · ${w.label}` : w.label }));
      }) : [];
      if (groupName && groupWindows.length) quotaGroups.push({ id: `desktop-${quotaGroups.length}`, title: groupName, windows: groupWindows });
      return flat;
    }) : [];
  }
  if (!windows.length) throw noData();
  return { ...quota("antigravity", windows, now), groups: quotaGroups.reduce((count, group) => count + group.windows.length, 0) === windows.length ? quotaGroups : [], planType: label(object(status.userTier).name) ?? [plan.planDisplayName, plan.displayName, plan.productName, plan.planName, plan.planShortName].map(label).find(Boolean) };
}

export async function readAntigravityDesktop(command: Command = runCommand, rpc: AntigravityRPC = antigravityRPC, now = Date.now(), signal?: AbortSignal, expectedIdentity?: string) {
  const bounded = signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000);
  try {
    bounded.throwIfAborted();
    const server = await discoverAntigravity(command, bounded);
    const request = async (endpoint: AntigravityEndpoint, method: Method) => {
      bounded.throwIfAborted();
      const current = await discoverAntigravity(command, bounded);
      if (current.executable !== server.executable || !endpoints(current).some(e => e.pid === endpoint.pid && e.port === endpoint.port && e.scheme === endpoint.scheme && e.csrf === endpoint.csrf)) throw unavailable();
      return rpc(endpoint, method, bounded);
    };
    let selected: { endpoint: AntigravityEndpoint; status: string; identity: string } | undefined;
    for (const endpoint of endpoints(server)) {
      let status: string;
      try { status = await request(endpoint, "GetUserStatus"); } catch { bounded.throwIfAborted(); continue; }
      // A responding endpoint with missing/changed identity cannot select a different account.
      const identity = antigravityIdentity(status);
      if (expectedIdentity && identity !== expectedIdentity) throw unavailable();
      selected = { endpoint, status, identity }; break;
    }
    if (!selected) throw unavailable();
    let q;
    try { q = antigravityDesktopQuota(await request(selected.endpoint, "RetrieveUserQuotaSummary"), selected.status, now); }
    catch (error) {
      if (!(error instanceof UnsupportedQuotaRPC)) throw error;
      q = antigravityDesktopQuota("", selected.status, now, true);
    }
    if (antigravityIdentity(await request(selected.endpoint, "GetUserStatus")) !== selected.identity) throw unavailable();
    const current = await discoverAntigravity(command, bounded);
    if (current.pid !== server.pid || current.csrf !== server.csrf || current.executable !== server.executable || !current.ports.includes(selected.endpoint.port)) throw unavailable();
    bounded.throwIfAborted();
    return { identity: selected.identity, quota: q };
  } catch (error) { throw error instanceof Unavailable ? error : unavailable(); }
}
