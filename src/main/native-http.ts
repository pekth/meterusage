import type { session } from "electron";
import { randomUUID } from "node:crypto";
import type { Launch } from "./launch";
import { httpTransport, isClaudeEndpoint, type HTTP } from "./providers/transport";

export function desktopHTTP(launch: Launch, sessions: Pick<typeof session, "fromPartition">): HTTP {
  if (launch.demo || launch.codexTest) return httpTransport();
  // A unique nonpersistent session avoids the renderer's HTTPS block and ambient credentials.
  const isolated = sessions.fromPartition(`meterusage-claude-${randomUUID()}`, { cache: false });
  if (isolated.isPersistent() || isolated.storagePath !== null) throw new Error("Claude HTTP session is not isolated");
  return httpTransport((url, options) => isClaudeEndpoint(String(url))
    ? isolated.fetch(String(url), { ...options, credentials: "omit" })
    : fetch(url, options));
}
