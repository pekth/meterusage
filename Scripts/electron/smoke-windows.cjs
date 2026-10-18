const { spawn, spawnSync } = require("node:child_process");
const { existsSync, mkdtempSync, realpathSync, rmSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { dirname, join, resolve } = require("node:path");
const { setTimeout: delay } = require("node:timers/promises");

async function smoke(executable) {
  if (process.platform !== "win32") throw new Error("Windows smoke requires Windows");
  if (existsSync(join(dirname(executable), "resources", "desktop-keychain"))) throw new Error("Windows package includes the macOS Keychain helper");
  const root = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-windows-smoke-"));
  const args = ["--demo", "--candidate-profile", join(root, "profile")];
  const env = { ...process.env };
  delete env.ELECTRON_RUN_AS_NODE;
  let first, second;
  const alive = child => child.pid && child.exitCode === null && child.signalCode === null;
  const launch = () => {
    const child = spawn(executable, args, { env, stdio: "ignore" });
    child.on("error", () => {});
    return child;
  };
  try {
    first = launch();
    await delay(10000);
    if (!alive(first) || !existsSync(join(root, "profile", "electron"))) throw new Error("Packaged demo did not remain running in its isolated profile");
    second = launch();
    for (let attempt = 0; attempt < 50 && alive(second); attempt++) await delay(100);
    if (second.exitCode !== 0 || !alive(first)) throw new Error("Packaged single-instance relaunch failed");
    console.log("Windows packaged demo stayed alive; second invocation exited successfully.");
  } finally {
    for (const child of [second, first]) {
      if (child && alive(child)) {
        const result = spawnSync("taskkill.exe", ["/pid", String(child.pid), "/T", "/F"], { stdio: "ignore" });
        if (result.status !== 0) throw new Error("Could not stop packaged smoke process tree");
      }
    }
    rmSync(root, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
  }
}

if (require.main === module) smoke(resolve(process.argv[2] || "release/win-unpacked/MeterUsage.exe")).catch(error => { console.error(error.message); process.exitCode = 1; });
