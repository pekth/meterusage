import { it, expect, vi } from "vite-plus/test";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync, mkdirSync, symlinkSync, readlinkSync, realpathSync } from "node:fs";
import { tmpdir, hostname } from "node:os";
import { createServer } from "node:net";
import { join } from "node:path";

it.each([
  { candidate: false, keyboard: false, retainedZoom: false, onboarding: true },
  { candidate: false, keyboard: false, retainedZoom: false, onboarding: false },
  { candidate: true, keyboard: false, retainedZoom: false },
  { candidate: true, keyboard: true, retainedZoom: false },
  { candidate: true, keyboard: false, retainedZoom: true },
])("cleans up windows and isolates candidate effects (candidate=$candidate, keyboard=$keyboard, retainedZoom=$retainedZoom, onboarding=$onboarding)", async ({ candidate, keyboard, retainedZoom, onboarding = true }) => {
  vi.resetModules();
  const root = mkdtempSync(join(tmpdir(), "meterusage-lifecycle-"));
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const resourcesPath = Object.getOwnPropertyDescriptor(process, "resourcesPath");
  const application = Object.assign(new EventEmitter(), {
    isPackaged: true, setName: vi.fn(), setPath: vi.fn(), whenReady: vi.fn(() => Promise.resolve()),
    getLoginItemSettings: vi.fn(() => ({ openAtLogin: false })), setLoginItemSettings: vi.fn(),
    requestSingleInstanceLock: vi.fn(() => true), getVersion: () => "0.0.0", quit: vi.fn(), exit: vi.fn(),
  });
  const workArea = { x: 0, y: 0, width: 1200, height: 900 };
  const display = Object.assign(new EventEmitter(), { getPrimaryDisplay: () => ({ workArea }), getDisplayNearestPoint: () => ({ workArea }), getDisplayMatching: () => ({ workArea }) });
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
  const showErrorBox = vi.fn();
  class TestWindow extends EventEmitter {
    destroyed = false;
    zoomFactor = 1;
    surface = "";
    bounds: { x: number; y: number; width: number; height: number };
    contents = Object.assign(new EventEmitter(), { id: windows.length + 1, mainFrame: { url: "" }, setFrameRate: vi.fn(), setZoomFactor: vi.fn((factor: number) => { this.zoomFactor = factor; }), send: vi.fn(), setWindowOpenHandler: vi.fn() });
    constructor(options: { width: number; height: number }) { super(); this.bounds = { x: 0, y: 0, width: options.width, height: options.height }; windows.push(this); }
    get webContents() { if (this.destroyed) throw new Error("webContents is unavailable after destruction"); return this.contents; }
    static fromWebContents(contents: unknown) { return windows.find(w => w.contents === contents); }
    isDestroyed = () => this.destroyed;
    isVisible = () => false;
    getBounds = () => this.bounds;
    setBounds = vi.fn((bounds: typeof this.bounds) => { this.bounds = bounds; });
    setSize = vi.fn((width: number, height: number) => { this.bounds.width = width; this.bounds.height = height; });
    setPosition = vi.fn((x: number, y: number) => { this.bounds.x = x; this.bounds.y = y; }); show = vi.fn(); focus = vi.fn(); hide = vi.fn();
    loadURL = (url: string) => {
      this.contents.mainFrame.url = url;
      this.surface = new URL(url).searchParams.get("surface")!;
      if (retainedZoom && ["flyout", "settings"].includes(new URL(url).searchParams.get("surface")!)) this.zoomFactor = 1.25;
      this.contents.emit("did-finish-load"); return Promise.resolve();
    };
  }
  const start = vi.fn(async () => {});
  vi.doMock("electron", () => ({ app: application, Tray: TestTray, BrowserWindow: TestWindow,
    screen: display, nativeTheme: theme, powerMonitor: new EventEmitter(), ipcMain: { handle: ipc }, dialog: { showErrorBox },
    Notification: Object.assign(class { show = notify; }, { isSupported: () => true }),
    nativeImage: { createFromPath: () => ({ resize: () => ({ setTemplateImage: vi.fn() }) }) },
    session: { defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), webRequest: { onBeforeRequest: vi.fn() } } },
  }));
  vi.doMock("../src/main/launch", () => ({ launchConfiguration: () => ({ data: root, home: root, demo: false, candidate, profile: candidate ? root : undefined }) }));
  const values: Record<string, boolean | string> = { onboardingCompleted: onboarding, panelSize: "medium" };
  const setPreference = vi.fn(async (key: string, value: boolean | string) => { await Promise.resolve(); values[key] = value; });
  let finishLoad!: () => void;
  const loading = new Promise<void>(resolve => { finishLoad = resolve; });
  const load = vi.fn(async () => { await loading; return { values, accounts: [], set: setPreference }; });
  vi.doMock("../src/main/preferences", () => ({ Preferences: { load } }));
  vi.doMock("../src/main/composition", () => ({ compose: () => [] }));
  vi.doMock("../src/main/connections", () => ({ DesktopConnections: class {
    state = []; configured = () => false; recover = async () => {}; stop = async () => {};
  } }));
  vi.doMock("../src/main/coordinator", () => ({ Coordinator: class {
    constructor(_launch: unknown, _prefs: unknown, _sources: unknown, _clock: unknown, alert: (a: unknown) => void) { alert({ title: "Fixture", body: "Fixture" }); }
    start = start; stop = vi.fn(); publish = vi.fn(); subscribe = vi.fn(() => vi.fn()); snapshot = () => ({ appearance: {} }); refreshIfStale = vi.fn();
  } }));
  vi.doMock("../src/main/updater", () => ({ Updater: class { reset = vi.fn(); } }));
  vi.doMock("../src/domain/overview", () => ({ trayTooltip: () => "Synthetic usage" }));
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    Object.defineProperty(process, "resourcesPath", { value: root, configurable: true });
    vi.stubGlobal("__dirname", root);
    await import("../src/main/electron");
    await vi.waitFor(() => expect(load).toHaveBeenCalledOnce());
    application.emit("second-instance");
    expect(windows).toHaveLength(0);
    finishLoad();
    await vi.waitFor(() => expect(start).toHaveBeenCalledOnce());
    await vi.waitFor(() => expect(windows).toHaveLength(2));
    expect(windows[1].focus).toHaveBeenCalled();
    application.emit("activate");
    expect(windows[1].focus).toHaveBeenCalledTimes(candidate || !onboarding ? 3 : 2);
    expect(application.requestSingleInstanceLock.mock.invocationCallOrder[0]).toBeLessThan(application.whenReady.mock.invocationCallOrder[0]);
    if (candidate) {
      expect(application.setPath.mock.calls).toEqual([["userData", join(root, "electron")], ["sessionData", join(root, "electron")]]);
      expect(notify).not.toHaveBeenCalled();
    } else {
      expect(application.setPath).not.toHaveBeenCalled(); expect(notify).toHaveBeenCalledOnce();
    }
    tray.emit("click");
    await vi.waitFor(() => expect(windows).toHaveLength(2));
    if (!onboarding) {
      const setup = windows[1];
      expect(setup.surface).toBe("settings");
      application.emit("activate");
      expect(setup.focus).toHaveBeenCalled();
      const invoke = (w: TestWindow, request: unknown) => ipc.mock.calls[0][1]({ sender: w.contents, senderFrame: w.contents.mainFrame }, request);
      setPreference.mockRejectedValueOnce(new Error("Synthetic write failure"));
      expect(await invoke(setup, { action: "setPreference", key: "onboardingCompleted", value: true })).toEqual({ ok: false, error: "Could not complete action" });
      expect(values.onboardingCompleted).toBe(false); expect(setup.hide).not.toHaveBeenCalled();
      expect(await invoke(setup, { action: "setPreference", key: "onboardingCompleted", value: true })).toEqual({ ok: true });
      expect(values.onboardingCompleted).toBe(true); expect(setup.hide).toHaveBeenCalled();
      expect(windows.some(w => w.surface === "flyout" && w.show.mock.calls.length > 0)).toBe(true);
      return;
    }
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
    const flyout = windows[2];
    expect(await invoke(flyout, { action: "resize", height: 593 })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 420, height: 593 });
    await invoke(windows[2], { action: "settings" });
    const settings = windows[3];
    if (retainedZoom) {
      expect(flyout.zoomFactor).toBe(1); expect(settings.zoomFactor).toBe(1);
      flyout.zoomFactor = 1.5; flyout.contents.emit("did-finish-load");
      expect(flyout.zoomFactor).toBe(1);
      expect(windows[0].contents.setZoomFactor).not.toHaveBeenCalled();
    }
    if (keyboard) {
      const key = (w: TestWindow, key: string, modifiers = { control: true, meta: false, alt: false }, type = "keyDown") => {
        const event = { preventDefault: vi.fn() };
        w.contents.emit("before-input-event", event, { key, type, ...modifiers });
        return event;
      };
      expect(key(flyout, "-").preventDefault).toHaveBeenCalledOnce();
      await vi.waitFor(() => expect(values.panelSize).toBe("small"));
      expect(flyout.bounds).toMatchObject({ width: 336, height: 475 });
      expect(settings.contents.send.mock.lastCall?.[1].settings.values.panelSize).toBe("small");
      expect(key(flyout, "-").preventDefault).toHaveBeenCalledOnce();
      await Promise.resolve(); await Promise.resolve();
      expect(values.panelSize).toBe("small");
      // Two inputs before persistence completes must advance twice, not lose a step.
      key(flyout, "="); key(flyout, "+", { control: false, meta: true, alt: false });
      await vi.waitFor(() => expect(values.panelSize).toBe("large"));
      expect(flyout.bounds).toMatchObject({ width: 483, height: 682 });
      key(settings, "+");
      await Promise.resolve(); await Promise.resolve();
      expect(values.panelSize).toBe("large");
      key(settings, "0", { control: false, meta: true, alt: false });
      await vi.waitFor(() => expect(values.panelSize).toBe("medium"));
      expect(flyout.bounds).toMatchObject({ width: 420, height: 593 });
      expect(settings.contents.send.mock.lastCall?.[1].settings.values.panelSize).toBe("medium");
      for (const input of ["+", "-", "=", "0", "a", "z"]) expect(key(settings, input, { control: false, meta: false, alt: false }).preventDefault).not.toHaveBeenCalled();
      expect(key(settings, "a").preventDefault).not.toHaveBeenCalled();
      expect(key(settings, "z").preventDefault).not.toHaveBeenCalled();
      expect(key(settings, "+", { control: true, meta: false, alt: true }).preventDefault).not.toHaveBeenCalled();
      expect(key(settings, "+", undefined, "keyUp").preventDefault).not.toHaveBeenCalled();
      expect(key(windows[0], "+").preventDefault).not.toHaveBeenCalled();
      setPreference.mockRejectedValueOnce(new Error("Synthetic write failure"));
      key(settings, "-");
      await vi.waitFor(() => expect(showErrorBox).toHaveBeenCalledOnce());
      expect(values.panelSize).toBe("medium");
      expect(flyout.bounds).toMatchObject({ width: 420, height: 593 });
      key(flyout, "-");
      await vi.waitFor(() => expect(values.panelSize).toBe("small"));
      key(flyout, "0");
      await vi.waitFor(() => expect(values.panelSize).toBe("medium"));
      expect(flyout.zoomFactor).toBe(1); expect(settings.zoomFactor).toBe(1);
      const writes = setPreference.mock.calls.length;
      key(closed, "-");
      await new Promise(resolve => setImmediate(resolve));
      expect(setPreference).toHaveBeenCalledTimes(writes);
    }
    expect(await invoke(windows[3], { action: "setPreference", key: "panelSize", value: "large" })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 483, height: 682 });
    expect(await invoke(flyout, { action: "resize", height: 1200 })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 483, height: 900 });
    expect(await invoke(windows[3], { action: "setPreference", key: "panelSize", value: "small" })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 336, height: 835 });
    expect(await invoke(flyout, { action: "resize", height: 400, width: 10000 })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 336, height: 400 });
    workArea.height = 350;
    display.emit("display-metrics-changed");
    expect(flyout.bounds).toMatchObject({ width: 336, height: 350 });
    workArea.height = 900;
    display.emit("display-metrics-changed");
    expect(flyout.bounds).toMatchObject({ width: 336, height: 400 });
    expect(await invoke(windows[3], { action: "setPreference", key: "panelSize", value: "huge" })).toEqual({ ok: false, error: "Invalid request" });
    expect(flyout.bounds).toMatchObject({ width: 336, height: 400 });
    workArea.height = 2400;
    expect(await invoke(flyout, { action: "resize", height: 2800 })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 336, height: 2400 });
    expect(await invoke(flyout, { action: "resize", height: 2200 })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 336, height: 2200 });
    workArea.height = 900;
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
    finishLoad();
    application.emit("before-quit", { preventDefault: vi.fn() });
    await Promise.resolve();
    Object.defineProperty(process, "platform", platform);
    if (resourcesPath) Object.defineProperty(process, "resourcesPath", resourcesPath); else Reflect.deleteProperty(process, "resourcesPath");
    vi.unstubAllGlobals();
    for (const path of ["electron", "../src/main/launch", "../src/main/preferences", "../src/main/composition", "../src/main/connections", "../src/main/coordinator", "../src/main/updater", "../src/domain/overview"]) vi.doUnmock(path);
    rmSync(root, { recursive: true, force: true });
  }
});

it.each(["duplicate", "invalid", "nested", "json"])("handles isolated profile startup safely (%s)", async scenario => {
  vi.resetModules();
  const root = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-startup-"));
  const socketDirectory = mkdtempSync(join(realpathSync(tmpdir()), "meterusage-socket-"));
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const argv = process.argv;
  const { launchConfiguration } = await import("../src/main/launch");
  const args = ["--codex-test-profile", root];
  launchConfiguration(args, {}, "/synthetic/home"); mkdirSync(join(root, "electron"));
  const socket = join(socketDirectory, "SingletonSocket"), server = createServer();
  await new Promise<void>(resolve => server.listen(socket, resolve));
  const links = new Map([
    [join(root, "electron/SingletonSocket"), socket],
    [join(root, "electron/SingletonCookie"), "123456789"],
    [join(root, "electron/SingletonLock"), `${hostname()}-${process.pid}`],
    [join(socketDirectory, "SingletonCookie"), scenario === "invalid" ? "987654321" : "123456789"],
  ]);
  for (const [path, target] of links) symlinkSync(target, path);
  if (scenario === "nested") symlinkSync(socketDirectory, join(root, "connections"));
  const application = Object.assign(new EventEmitter(), {
    isPackaged: false, setName: vi.fn(), setPath: vi.fn(),
    whenReady: vi.fn(() => Promise.resolve()), requestSingleInstanceLock: vi.fn(() => false),
    quit: vi.fn(), exit: vi.fn(),
  });
  const load = vi.fn(), runJSON = vi.fn();
  const stderr = vi.spyOn(process.stderr, "write").mockReturnValue(true);
  vi.doMock("electron", () => ({ app: application }));
  vi.doMock("../src/main/preferences", () => ({ Preferences: { load } }));
  vi.doMock("../src/main/cli", () => ({ runJSON }));
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    process.argv = [argv[0], "meterusage", ...args, ...(scenario === "json" ? ["--json"] : [])];
    vi.stubGlobal("__dirname", root);
    await expect(import("../src/main/electron")).resolves.toBeDefined();
    if (scenario === "duplicate") {
      await vi.waitFor(() => expect(application.quit).toHaveBeenCalledOnce());
      expect(application.setPath.mock.calls).toEqual([["userData", join(root, "electron")], ["sessionData", join(root, "electron")]]);
      expect(application.requestSingleInstanceLock).toHaveBeenCalledExactlyOnceWith({ candidate: true });
      expect(stderr).not.toHaveBeenCalled(); expect(application.exit).not.toHaveBeenCalled();
    } else {
      await vi.waitFor(() => expect(application.exit).toHaveBeenCalledExactlyOnceWith(1));
      expect(stderr).toHaveBeenCalledExactlyOnceWith("MeterUsage could not start.\n");
      expect(application.requestSingleInstanceLock).not.toHaveBeenCalled(); expect(application.setPath).not.toHaveBeenCalled();
    }
    expect(application.whenReady).not.toHaveBeenCalled(); expect(load).not.toHaveBeenCalled(); expect(runJSON).not.toHaveBeenCalled();
    for (const [path, target] of links) expect(readlinkSync(path)).toBe(target);
  } finally {
    process.argv = argv; Object.defineProperty(process, "platform", platform);
    vi.restoreAllMocks(); vi.unstubAllGlobals();
    for (const path of ["electron", "../src/main/preferences", "../src/main/cli"]) vi.doUnmock(path);
    await new Promise<void>(resolve => server.close(() => resolve()));
    rmSync(root, { recursive: true, force: true }); rmSync(socketDirectory, { recursive: true, force: true });
  }
});

it.each([
  { entry: "flyout", notchEnabled: false }, { entry: "flyout", notchEnabled: true },
  { entry: "tray", notchEnabled: false }, { entry: "tray", notchEnabled: true },
])("finishes $entry Quit after late collection publication (notch=$notchEnabled)", async ({ entry, notchEnabled }) => {
  vi.resetModules();
  const root = mkdtempSync(join(tmpdir(), "meterusage-quit-"));
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const resourcesPath = Object.getOwnPropertyDescriptor(process, "resourcesPath");
  const { Preferences } = await import("../src/main/preferences");
  const { Coordinator } = await import("../src/main/coordinator");
  const launch = { data: root, home: root, demo: true, candidate: false, env: {} };
  const prefs = await Preferences.load(launch);
  launch.demo = false;
  Object.assign(prefs.values, { onboardingCompleted: true, sideNotchPanelEnabled: notchEnabled, updateCheckEnabled: false });
  let coordinator!: InstanceType<typeof Coordinator>;
  const subscribe = Coordinator.prototype.subscribe;
  vi.spyOn(Coordinator.prototype, "subscribe").mockImplementation(function (this: InstanceType<typeof Coordinator>, observer) {
    coordinator = this; return subscribe.call(this, observer);
  });
  let finishCleanup!: () => void;
  const cleanup = new Promise<void>(resolve => { finishCleanup = resolve; });
  const stop = vi.fn(() => cleanup);
  const updaterCheck = vi.fn();
  const windows: TestWindow[] = [];
  const ipc = vi.fn(), willQuit = vi.fn(), didQuit = vi.fn();
  let running = true;
  const application = Object.assign(new EventEmitter(), {
    isPackaged: true, setName: vi.fn(), whenReady: () => Promise.resolve(),
    requestSingleInstanceLock: () => true, getVersion: () => "0.0.0", exit: vi.fn(),
    quit: vi.fn(() => {
      const event = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
      application.emit("before-quit", event);
      if (event.defaultPrevented) return;
      // Replay an in-flight collection's final publication between window closures.
      const closing = windows.filter(w => !w.destroyed);
      closing.find(w => w.surface === "notch")?.close();
      coordinator.publish();
      for (const w of closing) if (!w.destroyed) w.close();
      if (windows.some(w => !w.destroyed)) return;
      const final = { defaultPrevented: false, preventDefault() { this.defaultPrevented = true; } };
      application.emit("will-quit", final);
      if (!final.defaultPrevented) { running = false; application.emit("quit", {}, 0); }
    }),
  });
  application.on("will-quit", willQuit); application.on("quit", didQuit);
  const workArea = { x: 0, y: 25, width: 1200, height: 875 };
  const display = Object.assign(new EventEmitter(), { getPrimaryDisplay: () => ({ bounds: { x: 0, y: 0, width: 1200, height: 900 }, workArea }), getDisplayNearestPoint: () => ({ workArea }), getDisplayMatching: () => ({ workArea }) });
  let tray!: TestTray;
  class TestTray extends EventEmitter {
    destroyed = false;
    menu: { items: { label?: string; role?: string }[] } | undefined;
    constructor(...args: ConstructorParameters<typeof EventEmitter>) { super(...args); tray = this; }
    isDestroyed = () => this.destroyed;
    destroy() { this.destroyed = true; }
    setToolTip = vi.fn(); getBounds = () => ({ x: 0, y: 0, width: 22, height: 22 });
    popUpContextMenu(menu: NonNullable<TestTray["menu"]>) { this.menu = menu; }
  }
  class TestWindow extends EventEmitter {
    destroyed = false;
    surface = "";
    contents = { id: windows.length + 1, mainFrame: { url: "" }, setFrameRate: vi.fn(), on: vi.fn(), send: vi.fn(), setWindowOpenHandler: vi.fn() };
    constructor(...args: ConstructorParameters<typeof EventEmitter>) { super(...args); windows.push(this); }
    get webContents() { if (this.destroyed) throw new Error("webContents is unavailable after destruction"); return this.contents; }
    static fromWebContents(contents: unknown) { return windows.find(w => w.contents === contents); }
    isDestroyed = () => this.destroyed;
    isVisible = () => false;
    getBounds = () => ({ x: 0, y: 25, width: 100, height: 200 });
    setPosition = vi.fn(); setBounds = vi.fn(); setAlwaysOnTop = vi.fn(); setVisibleOnAllWorkspaces = vi.fn();
    show = vi.fn(); showInactive = vi.fn(); focus = vi.fn(); hide = vi.fn();
    loadURL(url: string) { this.contents.mainFrame.url = url; this.surface = new URL(url).searchParams.get("surface")!; return Promise.resolve(); }
    close() { this.destroyed = true; this.emit("closed"); }
  }
  vi.doMock("electron", () => ({ app: application, Tray: TestTray, BrowserWindow: TestWindow,
    Menu: { buildFromTemplate: (items: unknown[]) => ({ items }) },
    screen: display, nativeTheme: new EventEmitter(), powerMonitor: new EventEmitter(), ipcMain: { handle: ipc },
    nativeImage: { createFromPath: () => ({ resize: () => ({ setTemplateImage: vi.fn() }) }) },
    session: { defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), webRequest: { onBeforeRequest: vi.fn() } } },
  }));
  vi.doMock("../src/main/launch", () => ({ launchConfiguration: () => launch }));
  vi.spyOn(Preferences, "load").mockResolvedValue(prefs);
  vi.doMock("../src/main/composition", () => ({ compose: () => [] }));
  vi.doMock("../src/main/connections", () => ({ DesktopConnections: class {
    state = []; configured = () => false; recover = async () => {}; stop = stop;
  } }));
  vi.doMock("../src/main/updater", () => ({ Updater: class { reset = vi.fn(); checkIfDue = updaterCheck; } }));
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    Object.defineProperty(process, "resourcesPath", { value: root, configurable: true });
    vi.stubGlobal("__dirname", root);
    await import("../src/main/electron");
    await vi.waitFor(() => expect(coordinator.snapshot().refreshing).toBe(false));
    tray.emit("click");
    const flyout = windows.find(w => w.surface === "flyout")!;
    const windowCount = windows.length;
    const checks = updaterCheck.mock.calls.length;
    if (entry === "flyout") {
      expect(await ipc.mock.calls[0][1]({ sender: flyout.contents, senderFrame: flyout.contents.mainFrame }, { action: "quit" })).toEqual({ ok: true });
    } else {
      tray.emit("right-click");
      expect(tray.menu?.items.find(item => item.label === "Quit MeterUsage")?.role).toBe("quit");
      application.quit();
    }
    application.quit();
    application.emit("second-instance"); application.emit("activate");
    expect(stop).toHaveBeenCalledOnce(); expect(running).toBe(true); expect(tray.destroyed).toBe(false);
    expect(windows.filter(w => !w.destroyed)).toHaveLength(windowCount);
    finishCleanup();
    await cleanup;
    await vi.waitFor(() => expect(application.quit).toHaveBeenCalledTimes(3));
    expect(windows).toHaveLength(windowCount);
    expect(windows.every(w => w.destroyed)).toBe(true);
    expect(tray.destroyed).toBe(true); expect(running).toBe(false);
    expect(willQuit).toHaveBeenCalledOnce(); expect(didQuit).toHaveBeenCalledOnce();
    expect(application.exit).not.toHaveBeenCalled();
    expect(updaterCheck).toHaveBeenCalledTimes(checks);
    coordinator.publish();
    application.emit("second-instance"); application.emit("activate");
    expect(windows).toHaveLength(windowCount);
  } finally {
    finishCleanup(); coordinator?.stop();
    application.emit("before-quit", { preventDefault: vi.fn() });
    await cleanup; await Promise.resolve();
    Object.defineProperty(process, "platform", platform);
    if (resourcesPath) Object.defineProperty(process, "resourcesPath", resourcesPath); else Reflect.deleteProperty(process, "resourcesPath");
    vi.restoreAllMocks(); vi.unstubAllGlobals();
    for (const path of ["electron", "../src/main/launch", "../src/main/composition", "../src/main/connections", "../src/main/updater"]) vi.doUnmock(path);
    rmSync(root, { recursive: true, force: true });
  }
});
