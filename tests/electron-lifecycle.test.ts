import { it, expect, vi } from "vite-plus/test";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

it("ignores display and theme updates after the tray is destroyed", async () => {
  const root = mkdtempSync(join(tmpdir(), "meterusage-lifecycle-"));
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const application = Object.assign(new EventEmitter(), {
    isPackaged: false, setName: vi.fn(), whenReady: () => Promise.resolve(),
    requestSingleInstanceLock: () => true, getVersion: () => "0.0.0", quit: vi.fn(), exit: vi.fn(),
  });
  const display = Object.assign(new EventEmitter(), { getPrimaryDisplay: () => ({ workArea: { height: 900 } }) });
  const theme = new EventEmitter();
  let destroyed = false;
  const tooltip = vi.fn(() => { if (destroyed) throw new Error("Tray is destroyed"); });
  class TestTray extends EventEmitter {
    setToolTip = tooltip;
    isDestroyed = () => destroyed;
    destroy() { destroyed = true; }
  }
  class TestWindow extends EventEmitter {
    webContents = { id: 1, setFrameRate: vi.fn(), on: vi.fn(), send: vi.fn(), setWindowOpenHandler: vi.fn() };
    isDestroyed = () => false;
    loadURL = () => Promise.resolve();
  }
  const start = vi.fn(async () => {});
  vi.doMock("electron", () => ({ app: application, Tray: TestTray, BrowserWindow: TestWindow,
    screen: display, nativeTheme: theme, powerMonitor: new EventEmitter(), ipcMain: { handle: vi.fn() },
    nativeImage: { createFromPath: () => ({ resize: () => ({ setTemplateImage: vi.fn() }) }) },
    session: { defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), webRequest: { onBeforeRequest: vi.fn() } } },
  }));
  vi.doMock("../src/main/launch", () => ({ launchConfiguration: () => ({ data: root, home: root, demo: false }) }));
  vi.doMock("../src/main/preferences", () => ({ Preferences: { load: async () => ({ values: { onboardingCompleted: true }, accounts: [] }) } }));
  vi.doMock("../src/main/composition", () => ({ compose: () => [] }));
  vi.doMock("../src/main/connections", () => ({ DesktopConnections: class {
    state = []; configured = () => false; recover = async () => {}; stop = async () => {};
  } }));
  vi.doMock("../src/main/coordinator", () => ({ Coordinator: class {
    start = start; stop = vi.fn(); subscribe = vi.fn(); snapshot = () => ({ appearance: {} });
  } }));
  vi.doMock("../src/main/updater", () => ({ Updater: class { reset = vi.fn(); } }));
  vi.doMock("../src/domain/overview", () => ({ trayTooltip: () => "Synthetic usage" }));
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    vi.stubGlobal("__dirname", root);
    await import("../src/main/electron");
    await vi.waitFor(() => expect(start).toHaveBeenCalledOnce());
    expect(() => display.emit("display-metrics-changed")).not.toThrow();
    expect(tooltip).toHaveBeenCalledWith("Synthetic usage");
    destroyed = true;
    expect(() => display.emit("display-metrics-changed")).not.toThrow();
    expect(() => display.emit("display-removed")).not.toThrow();
    expect(() => theme.emit("updated")).not.toThrow();
  } finally {
    application.emit("before-quit", { preventDefault: vi.fn() });
    await Promise.resolve();
    Object.defineProperty(process, "platform", platform);
    vi.unstubAllGlobals();
    for (const path of ["electron", "../src/main/launch", "../src/main/preferences", "../src/main/composition", "../src/main/connections", "../src/main/coordinator", "../src/main/updater", "../src/domain/overview"]) vi.doUnmock(path);
    rmSync(root, { recursive: true, force: true });
  }
});
