import { afterEach, describe, expect, it, vi } from "vite-plus/test";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { win32 } from "node:path";
import { boundedChild, cliEnvironment, cliPath, codexRPC, runCommand } from "../src/main/providers/transport";

const files = vi.hoisted(() => new Map<string, boolean>());
vi.mock("node:path", async original => {
  const actual = await original<typeof import("node:path")>();
  return { ...actual, join: actual.win32.join };
});
vi.mock("node:fs", async original => ({
  ...await original<typeof import("node:fs")>(),
  accessSync: vi.fn((path: string) => { if (!files.has(path.toLowerCase())) throw new Error("Synthetic path missing"); }),
  statSync: vi.fn((path: string) => ({ isFile: () => files.get(path.toLowerCase()) === true })),
}));
vi.mock("node:child_process", async original => {
  const actual = await original<typeof import("node:child_process")>();
  return { ...actual, spawn: vi.fn(actual.spawn) };
});
afterEach(() => { files.clear(); vi.clearAllMocks(); vi.mocked(spawn).mockReset(); vi.useRealTimers(); });
const home = "C:\\Users\\testuser", npm = win32.join(home, "AppData", "Roaming", "npm");
function file(path: string) { files.set(path.toLowerCase(), true); return path; }
function onWindows<T>(run: () => T): T {
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  Object.defineProperty(process, "platform", { value: "win32" });
  try { return run(); } finally { Object.defineProperty(process, "platform", platform); }
}
function fakeChild(cleanup: "success" | "error" | "timeout" = "success") {
  const child = Object.assign(new EventEmitter(), { pid: 43210, stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(), exitCode: null as number | null,
    kill: vi.fn(() => { queueMicrotask(() => close(0)); return true; }),
  });
  let closed = false;
  const close = (code: number) => {
    if (closed) return; closed = true; child.exitCode = code;
    child.stdout.once("end", () => child.emit("close", code));
    child.stdout.end(); child.stderr.end(); child.emit("exit", code);
  };
  const treeKill = Object.assign(new EventEmitter(), { kill: vi.fn(() => true) });
  vi.mocked(spawn).mockImplementationOnce(() => child as unknown as ChildProcessWithoutNullStreams);
  vi.mocked(spawn).mockImplementationOnce(() => {
    queueMicrotask(() => {
      if (cleanup === "success") { close(0); treeKill.emit("close", 0); }
      if (cleanup === "error") treeKill.emit("error", new Error("PRIVATE taskkill failure"));
    });
    return treeKill as unknown as ChildProcessWithoutNullStreams;
  });
  return { child, close, treeKill };
}

describe("Windows CLI discovery", () => {
  it.each(["codex", "claude", "opencode"])("finds a native %s install outside PATH", name => {
    const binary = file(win32.join(home, ".local", "bin", name + ".exe"));
    expect(cliPath(name, home, {}, "win32")).toBe(binary);
  });
  it("honors case-insensitive Path/PATHEXT, quoted directories and spaces", () => {
    const binary = file("D:\\CLI Tools\\codex.cmd");
    expect(cliPath("codex", home, { pAtH: '"D:\\CLI Tools"', pAtHeXt: ".pS1;.cMd" }, "win32")).toBe(binary);
    file("D:\\CLI Tools\\claude.ps1");
    expect(() => cliPath("claude", home, { Path: "D:\\CLI Tools", PATHEXT: ".PS1" }, "win32")).toThrow("not found");
  });
  it.each([
    ["codex", "AppData\\Roaming\\npm"], ["claude", ".bun\\bin"], ["opencode", ".cargo\\bin"],
    ["claude", "AppData\\Local\\Programs\\claude"], ["codex", "AppData\\Local\\Microsoft\\WinGet\\Links"],
  ])("finds %s in the per-user %s installation", (name, dir) => {
    const binary = file(win32.join(home, dir, name + ".exe"));
    expect(cliPath(name, home, {}, "win32")).toBe(binary);
  });
  it("uses redirected AppData locations and skips directories and current-directory PATH entries", () => {
    files.set(win32.join(home, ".local", "bin", "codex.exe").toLowerCase(), false);
    const binary = file("D:\\Roaming\\npm\\codex.cmd");
    expect(cliPath("codex", home, { AppData: "D:\\Roaming", Path: ";.;relative" }, "win32")).toBe(binary);
    expect(cliEnvironment(home, { Path: ';.;relative;"D:\\CLI Tools"', SystemRoot: "C:\\Windows" }, "win32")).toMatchObject({ SystemRoot: "C:\\Windows" });
    expect(cliEnvironment(home, { Path: ';.;relative;"D:\\CLI Tools"' }, "win32").PATH?.split(";")).toContain("D:\\CLI Tools");
    expect(cliEnvironment(home, { Path: ";.;relative" }, "win32").PATH?.split(";")).not.toContain(".");
  });
  it("emits one PATH key and preserves the rest of the provider environment", () => {
    const env = cliEnvironment(home, { Path: "D:\\CLI Tools", USERPROFILE: home, LOCALAPPDATA: "D:\\Local", CODEX_HOME: "D:\\Profile" }, "win32");
    expect(Object.keys(env).filter(key => key.toLowerCase() === "path")).toEqual(["PATH"]);
    expect(env.PATH).toContain("D:\\CLI Tools"); expect(env.PATH).toContain("D:\\Local\\Microsoft\\WinGet\\Links");
    expect(env.USERPROFILE).toBe(home); expect(env.CODEX_HOME).toBe("D:\\Profile");
  });
  it("rejects relative user directories and drive-relative PATH entries", () => {
    const env = cliEnvironment("", { APPDATA: "relative", LOCALAPPDATA: "relative", Path: "\\root-relative;D:drive-relative;\\\\server\\share\\tools" }, "win32");
    expect(env.PATH?.split(";")).toEqual(["\\\\server\\share\\tools"]);
    file(".local\\bin\\codex.exe");
    expect(() => cliPath("codex", "", {}, "win32")).toThrow("not found");
  });
  it.each(["linux", "darwin"] as const)("preserves %s paths when the host uses Windows joins", platform => {
    expect(cliEnvironment("/synthetic/home", { PATH: "/synthetic/bin", KEEP: "value" }, platform)).toEqual({ KEEP: "value", PATH: "/opt/homebrew/bin:/usr/local/bin:/synthetic/home/.cargo/bin:/synthetic/home/.local/bin:/synthetic/bin" });
    file("/synthetic/home/.bun/bin/opencode");
    expect(cliPath("opencode", "/synthetic/home", {}, platform)).toBe("/synthetic/home/.bun/bin/opencode");
  });
});

describe("Windows provider process boundary", () => {
  it.each([
    ["codex.CMD", "@openai/codex/bin/codex.js"], ["claude.bat", "@anthropic-ai/claude-code/cli.js"], ["opencode.cmd", "opencode-ai/bin/opencode"],
  ])("bypasses %s using the installed Node script and literal argv", async (name, script) => {
    const binary = file(win32.join(npm, name)), target = file(win32.join(npm, "node_modules", script)), node = file(win32.join(npm, "node.exe"));
    const { child, close } = fakeChild(), args = ["space value", 'quote"value', "&whoami", "|more", "%PATH%", "!value!", "^", "\r\n"];
    const pending = onWindows(() => runCommand(binary, args, { env: { Path: "D:\\Node" } }));
    expect(spawn).toHaveBeenCalledWith(node, [target, ...args], { env: { Path: "D:\\Node" }, stdio: "pipe", shell: false, windowsHide: true });
    child.stdout.write("synthetic result"); close(0); expect(await pending).toBe("synthetic result");
  });
  it("finds node.exe on Path without using the Electron executable", async () => {
    const binary = file(win32.join(npm, "codex.cmd")), target = file(win32.join(npm, "node_modules", "@openai/codex/bin/codex.js")), node = file("D:\\Node Tools\\node.exe");
    const { close } = fakeChild();
    const pending = onWindows(() => runCommand(binary, ["--version"], { env: { pAtH: "D:\\Node Tools", PATHEXT: ".CMD;.COM", USERPROFILE: home } }));
    expect(spawn).toHaveBeenCalledWith(node, [target, "--version"], expect.objectContaining({ shell: false })); close(0); await pending;
  });
  it("passes native executable arguments directly without a shell", async () => {
    const { close } = fakeChild(), args = ["a & b", '"quoted"', "%PATH%"];
    const pending = onWindows(() => runCommand("D:\\CLI Tools\\claude.exe", args));
    expect(spawn).toHaveBeenCalledWith("D:\\CLI Tools\\claude.exe", args, expect.objectContaining({ shell: false, windowsHide: true })); close(0); await pending;
  });
  it("rejects unknown wrappers, absent package targets and missing Node without leaking command details", async () => {
    await expect(onWindows(() => runCommand("D:\\PRIVATE\\custom.cmd", ["PRIVATE_ARG"]))).rejects.toThrow("Provider command wrapper unsupported");
    const missingTarget = onWindows(() => runCommand(win32.join(npm, "codex.cmd"), ["PRIVATE_ARG"]));
    await expect(missingTarget).rejects.toThrow("Provider command wrapper unavailable");
    file(win32.join(npm, "node_modules", "@openai/codex/bin/codex.js"));
    await expect(onWindows(() => runCommand(win32.join(npm, "codex.cmd"), ["PRIVATE_ARG"], { env: { USERPROFILE: home } }))).rejects.toThrow("Provider command wrapper unavailable");
    expect(spawn).not.toHaveBeenCalled();
  });
  it("does not substitute node.com or a relative node.exe for Node", async () => {
    file(win32.join(npm, "node_modules", "@openai/codex/bin/codex.js"));
    file("D:\\Node Tools\\node.com"); file(".local\\bin\\node.exe");
    await expect(onWindows(() => runCommand(win32.join(npm, "codex.cmd"), [], { env: { PATH: "D:\\Node Tools" } }))).rejects.toThrow("Provider command wrapper unavailable");
    expect(spawn).not.toHaveBeenCalled();
  });
  it("retains JSON-RPC initialization and closes/reaps the shim-free child", async () => {
    const binary = file(win32.join(npm, "codex.cmd")); file(win32.join(npm, "node.exe")); file(win32.join(npm, "node_modules", "@openai/codex/bin/codex.js"));
    const { child } = fakeChild(), requests: Record<string, unknown>[] = [];
    child.stdin.on("data", chunk => {
      const request = JSON.parse(String(chunk)); requests.push(request);
      if (request.id === 1) queueMicrotask(() => child.stdout.write('{"id":1,"result":{}}\n'));
      if (request.id === 2) queueMicrotask(() => child.stdout.write('{"id":2,"result":{"ok":true}}\n'));
    });
    expect(await onWindows(() => codexRPC(binary, {}))).toBe('{"id":2,"result":{"ok":true}}');
    expect(requests.map(request => request.method)).toEqual(["initialize", "initialized", "account/rateLimits/read"]);
    expect(spawn).toHaveBeenLastCalledWith(expect.stringMatching(/System32\\taskkill\.exe$/), ["/PID", "43210", "/T", "/F"], { stdio: "ignore", shell: false, windowsHide: true });
    expect(child.kill).not.toHaveBeenCalled(); expect(child.exitCode).toBe(0);
  });
  it("cancels and reaps an npm script process", async () => {
    const binary = file(win32.join(npm, "codex.cmd")); file(win32.join(npm, "node.exe")); file(win32.join(npm, "node_modules", "@openai/codex/bin/codex.js"));
    const { child } = fakeChild(), controller = new AbortController();
    const pending = onWindows(() => runCommand(binary, [], { signal: controller.signal })); controller.abort();
    await expect(pending).rejects.toThrow("Provider request cancelled"); expect(child.kill).not.toHaveBeenCalled(); expect(child.exitCode).toBe(0);
  });
  it("waits for tree termination after the launcher's pipes close", async () => {
    const { close, treeKill } = fakeChild("timeout");
    const pending = onWindows(() => boundedChild("D:\\CLI\\codex.exe", [], {}, (_child, finish) => finish("synthetic result")));
    let settled = false; void pending.then(() => { settled = true; });
    close(0); await Promise.resolve(); expect(settled).toBe(false);
    treeKill.emit("close", 0); await expect(pending).resolves.toBe("synthetic result");
  });
  it.each(["helper-first", "child-first"])("preserves the output limit after process-not-found cleanup (%s)", async order => {
    const { child, close, treeKill } = fakeChild("timeout");
    const pending = onWindows(() => runCommand("D:\\CLI\\codex.exe", [], { maxBytes: 10 }));
    const rejected = expect(pending).rejects.toThrow("Provider output exceeded limit");
    child.stdout.write("x".repeat(1000));
    if (order === "helper-first") treeKill.emit("close", 128);
    close(0); await Promise.resolve();
    if (order === "child-first") treeKill.emit("close", 128);
    await rejected; expect(child.kill).not.toHaveBeenCalled();
  });
  it("does not accept access failure after the provider closes", async () => {
    const { close, treeKill } = fakeChild("timeout");
    const pending = onWindows(() => boundedChild("D:\\CLI\\codex.exe", [], {}, (_child, finish) => finish("synthetic result")));
    const rejected = expect(pending).rejects.toThrow("Provider process cleanup failed");
    close(0); await Promise.resolve(); treeKill.emit("close", 1); await rejected;
  });
  it.each(["error", "timeout", "pipes", "exited-launcher", "missing-with-open-pipes"] as const)("bounds tree cleanup %s and rejects without exposing stderr", async cleanup => {
    vi.useFakeTimers();
    const { child, treeKill } = fakeChild(cleanup === "error" ? "error" : "timeout");
    if (cleanup === "exited-launcher") child.exitCode = 0;
    const pending = onWindows(() => boundedChild("D:\\CLI\\codex.exe", [], {}, (_child, finish) => finish("synthetic result")));
    if (cleanup === "pipes") treeKill.emit("close", 0);
    if (cleanup === "missing-with-open-pipes") { child.exitCode = 0; treeKill.emit("close", 128); }
    const rejected = expect(pending).rejects.toThrow("Provider process cleanup failed");
    await vi.advanceTimersByTimeAsync(1500); await rejected;
    if (cleanup !== "exited-launcher") expect(treeKill.kill).toHaveBeenCalledWith("SIGKILL");
    expect(child.kill).toHaveBeenCalledWith("SIGKILL");
    expect(child.stdout.destroyed).toBe(true); expect(child.stderr.destroyed).toBe(true);
    expect(vi.getTimerCount()).toBe(0);
  });
  it("executes portable literal argv and enforces timeout, cancellation, output limits and stderr secrecy", async () => {
    const args = ["space value", 'quote"value', "&whoami", "%PATH%", "|more"];
    expect(JSON.parse(await runCommand(process.execPath, ["-e", "process.stdout.write(JSON.stringify(process.argv.slice(1)))", ...args]))).toEqual(args);
    await expect(runCommand(process.execPath, ["-e", "process.stderr.write('PRIVATE');setInterval(()=>{},1000)"], { timeoutMs: 50 })).rejects.toThrow("Provider request timed out");
    const controller = new AbortController(), pending = runCommand(process.execPath, ["-e", "setInterval(()=>{},1000)"], { signal: controller.signal }); controller.abort();
    await expect(pending).rejects.toThrow("Provider request cancelled");
    await expect(runCommand(process.execPath, ["-e", "process.stdout.write('x'.repeat(1000))"], { maxBytes: 10 })).rejects.toThrow("Provider output exceeded limit");
    await expect(runCommand(process.execPath, ["-e", "process.stderr.write('PRIVATE');process.exit(1)"])).rejects.toThrow("Provider command failed");
  });
});
