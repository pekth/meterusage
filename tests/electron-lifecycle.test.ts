import { it, expect, vi } from "vite-plus/test";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

it.each([false, true])("cleans up windows and isolates candidate effects (candidate=%s)", async candidate => {
  vi.resetModules();
  const root = mkdtempSync(join(tmpdir(), "meterusage-lifecycle-"));
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const resourcesPath = Object.getOwnPropertyDescriptor(process, "resourcesPath");
  const application = Object.assign(new EventEmitter(), {
    isPackaged: true, setName: vi.fn(), setPath: vi.fn(), whenReady: () => Promise.resolve(),
    getLoginItemSettings: vi.fn(() => ({ openAtLogin: false })), setLoginItemSettings: vi.fn(),
    requestSingleInstanceLock: () => true, getVersion: () => "0.0.0", quit: vi.fn(), exit: vi.fn(),
  });
  const display = Object.assign(new EventEmitter(), { getPrimaryDisplay: () => ({ workArea: { height: 900 } }), getDisplayNearestPoint: () => ({ workArea: { x: 0, y: 0, width: 1200, height: 900 } }) });
  const theme = new EventEmitter();
  let destroyed = false;
  const tooltip = vi.fn(() => { if (destroyed) throw new Error("Tray is destroyed"); });
  let tray!: TestTray;
  class TestTray extends EventEmitter {
    constructor(...args: ConstructorParameters<typeof EventEmitter>) { super(...args); tray = this; }
    setToolTip = tooltip;
    isDestroyed = () => destroyed;
    getBounds = () => ({ x: 0, y: 0, width: 22, height: 22 });
    destroy() { destroyed = true; }
  }
  const windows: TestWindow[] = [];
  const ipc = vi.fn();
  const notify = vi.fn();
  class TestWindow extends EventEmitter {
    destroyed = false;
    contents = { id: windows.length + 1, mainFrame: { url: "" }, setFrameRate: vi.fn(), on: vi.fn(), send: vi.fn(), setWindowOpenHandler: vi.fn() };
    constructor(...args: ConstructorParameters<typeof EventEmitter>) { super(...args); windows.push(this); }
    get webContents() { if (this.destroyed) throw new Error("webContents is unavailable after destruction"); return this.contents; }
    static fromWebContents(contents: unknown) { return windows.find(w => w.contents === contents); }
    isDestroyed = () => this.destroyed;
    isVisible = () => false;
    getBounds = () => ({ x: 0, y: 0, width: 100, height: 100 });
    setPosition = vi.fn(); show = vi.fn(); focus = vi.fn(); hide = vi.fn();
    loadURL = (url: string) => { this.contents.mainFrame.url = url; return Promise.resolve(); };
  }
  const start = vi.fn(async () => {});
  vi.doMock("electron", () => ({ app: application, Tray: TestTray, BrowserWindow: TestWindow,
    screen: display, nativeTheme: theme, powerMonitor: new EventEmitter(), ipcMain: { handle: ipc },
    Notification: Object.assign(class { show = notify; }, { isSupported: () => true }),
    nativeImage: { createFromPath: () => ({ resize: () => ({ setTemplateImage: vi.fn() }) }) },
    session: { defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), webRequest: { onBeforeRequest: vi.fn() } } },
  }));
  vi.doMock("../src/main/launch", () => ({ launchConfiguration: () => ({ data: root, home: root, demo: false, candidate, profile: candidate ? root : undefined }) }));
  vi.doMock("../src/main/preferences", () => ({ Preferences: { load: async () => ({ values: { onboardingCompleted: true }, accounts: [] }) } }));
  vi.doMock("../src/main/composition", () => ({ compose: () => [] }));
  vi.doMock("../src/main/connections", () => ({ DesktopConnections: class {
    state = []; configured = () => false; recover = async () => {}; stop = async () => {};
  } }));
  vi.doMock("../src/main/coordinator", () => ({ Coordinator: class {
    constructor(_launch: unknown, _prefs: unknown, _sources: unknown, _clock: unknown, alert: (a: unknown) => void) { alert({ title: "Fixture", body: "Fixture" }); }
    start = start; stop = vi.fn(); subscribe = vi.fn(); snapshot = () => ({ appearance: {} }); refreshIfStale = vi.fn();
  } }));
  vi.doMock("../src/main/updater", () => ({ Updater: class { reset = vi.fn(); } }));
  vi.doMock("../src/domain/overview", () => ({ trayTooltip: () => "Synthetic usage" }));
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    Object.defineProperty(process, "resourcesPath", { value: root, configurable: true });
    vi.stubGlobal("__dirname", root);
    await import("../src/main/electron");
    await vi.waitFor(() => expect(start).toHaveBeenCalledOnce());
    if (candidate) {
      expect(application.setPath.mock.calls).toEqual([["userData", join(root, "electron")], ["sessionData", join(root, "electron")]]);
      expect(notify).not.toHaveBeenCalled();
    } else {
      expect(application.setPath).not.toHaveBeenCalled(); expect(notify).toHaveBeenCalledOnce();
    }
    tray.emit("click");
    await vi.waitFor(() => expect(windows).toHaveLength(2));
    const closed = windows[1];
    closed.destroyed = true;
    tray.emit("click");
    expect(windows).toHaveLength(3);
    expect(() => closed.emit("closed")).not.toThrow();
    tray.emit("click");
    expect(windows).toHaveLength(3);
    expect(() => display.emit("display-metrics-changed")).not.toThrow();
    expect(tooltip).toHaveBeenCalledWith("Synthetic usage");
    const invoke = (w: TestWindow, request: unknown) => ipc.mock.calls[0][1]({ sender: w.contents, senderFrame: w.contents.mainFrame }, request);
    await invoke(windows[2], { action: "settings" });
    if (candidate) {
      expect(application.getLoginItemSettings).not.toHaveBeenCalled();
      const reply = await invoke(windows[3], { action: "setPreference", key: "launchAtLogin", value: true });
      expect(reply).toEqual({ ok: false, error: "Login items require an installed app" });
      expect(application.setLoginItemSettings).not.toHaveBeenCalled();
    } else expect(application.getLoginItemSettings).toHaveBeenCalledOnce();
    destroyed = true;
    expect(() => display.emit("display-metrics-changed")).not.toThrow();
    expect(() => display.emit("display-removed")).not.toThrow();
    expect(() => theme.emit("updated")).not.toThrow();
  } finally {
    application.emit("before-quit", { preventDefault: vi.fn() });
    await Promise.resolve();
    Object.defineProperty(process, "platform", platform);
    if (resourcesPath) Object.defineProperty(process, "resourcesPath", resourcesPath); else Reflect.deleteProperty(process, "resourcesPath");
    vi.unstubAllGlobals();
    for (const path of ["electron", "../src/main/launch", "../src/main/preferences", "../src/main/composition", "../src/main/connections", "../src/main/coordinator", "../src/main/updater", "../src/domain/overview"]) vi.doUnmock(path);
    rmSync(root, { recursive: true, force: true });
  }
});
