import { afterEach, expect, it } from "vite-plus/test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { boundedChild, runCommand } from "../src/main/providers/transport";

const roots: string[] = [];
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }); });
it.skipIf(process.platform !== "win32")("runs an installed npm target with literal arguments on Windows without executing its batch wrapper", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage cli fixture ")); roots.push(root);
  const script = join(root, "node_modules", "@openai", "codex", "bin", "codex.js");
  mkdirSync(dirname(script), { recursive: true });
  writeFileSync(script, "process.stdout.write(JSON.stringify(process.argv.slice(2)))");
  const binary = join(root, "codex.cmd"); writeFileSync(binary, "@echo PRIVATE_WRAPPER_MUST_NOT_RUN\r\n@exit /b 99\r\n");
  const args = ["space value", 'quote"value', "&echo PRIVATE", "|more", "%PATH%", "!value!", "^", "\r\n"];
  const result = await runCommand(binary, args, { env: { SystemRoot: process.env.SystemRoot, USERPROFILE: root, PATH: dirname(process.execPath), PATHEXT: ".EXE" } });
  expect(JSON.parse(result)).toEqual(args);
});
it.skipIf(process.platform !== "win32").each(["success", "cancel"])("settles %s and reaps a launcher and grandchild retaining inherited pipes", async outcome => {
  const root = mkdtempSync(join(tmpdir(), "meterusage process tree ")); roots.push(root);
  const launcher = join(root, "launcher.cjs"), launcherPID = join(root, "launcher.pid"), grandchildPID = join(root, "grandchild.pid");
  const grandchild = "require('node:fs').writeFileSync(process.argv[1], String(process.pid));process.stdout.write('READY\\n');setInterval(()=>{},1000)";
  writeFileSync(launcher, `const {spawn}=require('node:child_process');require('node:fs').writeFileSync(process.argv[2],String(process.pid));const child=spawn(process.execPath,['-e',${JSON.stringify(grandchild)},process.argv[3]],{stdio:'inherit'});process.on('SIGTERM',()=>child.kill('SIGTERM'));child.on('exit',()=>process.exit(0));`);
  const controller = new AbortController();
  let watchdog: ReturnType<typeof setTimeout> | undefined;
  const pids = () => [launcherPID, grandchildPID].flatMap(path => { try { return [Number(readFileSync(path, "utf8"))]; } catch { return []; } });
  const alive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };
  try {
    const pending = boundedChild(process.execPath, [launcher, launcherPID, grandchildPID], { signal: controller.signal, timeoutMs: 3000 }, (child, finish) => {
      let text = "";
      child.stdout.on("data", chunk => { text += String(chunk); if (text.includes("READY\n")) { if (outcome === "cancel") controller.abort(); else finish("synthetic result"); } });
    });
    const bounded = Promise.race([pending, new Promise<never>((_resolve, reject) => { watchdog = setTimeout(() => reject(new Error("Fixture process cleanup did not settle")), 6000); })]);
    if (outcome === "cancel") await expect(bounded).rejects.toThrow("Provider request cancelled");
    else await expect(bounded).resolves.toBe("synthetic result");
    expect(pids()).toHaveLength(2);
    await expect.poll(() => pids().some(alive), { timeout: 2000 }).toBe(false);
  } finally {
    if (watchdog) clearTimeout(watchdog);
    for (const pid of pids()) if (alive(pid)) spawnSync(join(process.env.SystemRoot ?? "C:\\Windows", "System32", "taskkill.exe"), ["/PID", String(pid), "/T", "/F"], { stdio: "ignore", shell: false, windowsHide: true, timeout: 1500 });
  }
});
