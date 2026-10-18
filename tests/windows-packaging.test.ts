import { createRequire } from "node:module";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { afterEach, expect, it } from "vite-plus/test";

const require = createRequire(import.meta.url);
const afterPack = require("../Scripts/electron/after-pack.cjs");
const { exportAssets } = require("../Scripts/electron/export-portable-assets.cjs");
const roots: string[] = [];
const temp = () => { const root = mkdtempSync(join(tmpdir(), "meterusage-packaging-")); roots.push(root); return root; };
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });

it("skips all macOS executable and plist operations for Windows", async () => {
  const root = temp();
  await expect(afterPack({ electronPlatformName: "win32", appOutDir: root })).resolves.toBeUndefined();
  expect(existsSync(join(root, "MeterUsage.app"))).toBe(false);
  await expect(afterPack({ electronPlatformName: "linux", appOutDir: root })).rejects.toThrow("Unsupported");
});

it("keeps the macOS executable rename and plist update", () => {
  const bundle = temp(), macos = join(bundle, "Contents", "MacOS");
  mkdirSync(macos, { recursive: true }); writeFileSync(join(macos, "MeterUsage"), "fixture");
  const commands: unknown[][] = [];
  afterPack.renameExecutable(bundle, (...args: unknown[]) => commands.push(args));
  expect(readFileSync(join(macos, "meterusage"), "utf8")).toBe("fixture");
  expect(commands).toEqual([["/usr/libexec/PlistBuddy", ["-c", "Set :CFBundleExecutable meterusage", join(bundle, "Contents/Info.plist")]]]);
});

it("copies the original provider marks and wraps the original 256px PNG as ICO", () => {
  const root = temp(), resources = join(root, "Resources"); mkdirSync(resources);
  copyFileSync(resolve("Resources/AppIcon.icns"), join(resources, "AppIcon.icns"));
  exportAssets(root);
  for (const provider of ["openRouter", "cursor", "copilot", "gemini"]) {
    expect(readFileSync(join(resources, `${provider}-symbol.png`))).toEqual(readFileSync(resolve("Scripts/electron/assets", `${provider}-symbol.png`)));
  }
  const ico = readFileSync(join(root, "build/AppIcon.ico"));
  expect(ico.readUInt16LE(2)).toBe(1); expect(ico.readUInt16LE(4)).toBe(1);
  expect(ico.readUInt32LE(14)).toBe(ico.length - 22); expect(ico.readUInt32LE(18)).toBe(22);
  expect(ico.subarray(22, 30)).toEqual(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  expect(ico.readUInt32BE(38)).toBe(256); expect(ico.readUInt32BE(42)).toBe(256);
});

it("keeps Swift and the Keychain helper confined to macOS packaging", () => {
  const manifest = JSON.parse(readFileSync(resolve("package.json"), "utf8"));
  expect(manifest.scripts["package:win"]).toBe("pnpm export:marks:portable && pnpm build && electron-builder --win --x64 --publish never");
  const config = readFileSync(resolve("electron-builder.yml"), "utf8");
  expect(config.split("mac:\n")[0]).not.toContain("desktop-keychain");
  expect(config.split("win:\n")[1]).not.toContain("desktop-keychain");
  expect(config).toContain("mac:\n  extraResources:\n    - from: build/desktop-keychain\n      to: desktop-keychain");
});
