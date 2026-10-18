import { posix, win32 } from "node:path";
import type { ConnectionProvider } from "../shared/ipc";
import type { Rect } from "../domain/notch";

export function applicationData(home: string, platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env): string {
  if (platform !== "win32") return posix.join(home, "Library/Application Support/MeterUsage");
  const roaming = Object.entries(env).find(([key]) => key.toLowerCase() === "appdata")?.[1];
  if (roaming && (!win32.isAbsolute(roaming) || win32.parse(roaming).root.length < 2 || /[\r\n\0]/.test(roaming))) throw new Error("APPDATA must be an absolute directory");
  return win32.join(roaming || win32.join(home, "AppData", "Roaming"), "MeterUsage");
}

export function windowsFlyoutY(tray: Rect, work: Rect, height: number): number {
  return tray.y >= work.y + work.height / 2 ? work.y + work.height - height : work.y;
}

export function accountConnectionAvailable(provider: ConnectionProvider, platform: NodeJS.Platform = process.platform): boolean {
  return platform !== "win32" || provider === "codex";
}
