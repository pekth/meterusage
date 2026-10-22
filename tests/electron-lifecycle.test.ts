import { grokBotConnectionErrors } from "../src/main/providers/grok-bot-desktop";
import { it, expect, vi } from "vite-plus/test";
import { EventEmitter } from "node:events";
import { mkdtempSync, rmSync, mkdirSync, symlinkSync, readlinkSync, realpathSync } from "node:fs";
import { tmpdir, hostname } from "node:os";
import { createServer } from "node:net";
import { join } from "node:path";
import { providers, type Provider } from "../src/domain/models";
import type { HTTP } from "../src/main/providers/transport";
import type { Source } from "../src/main/composition";

it.each([
  { candidate: false, keyboard: false, retainedZoom: false, onboarding: true },
  { candidate: false, keyboard: false, retainedZoom: false, onboarding: false },
  { candidate: true, keyboard: false, retainedZoom: false },
  { candidate: true, keyboard: true, retainedZoom: false },
  { candidate: true, keyboard: false, retainedZoom: true },
  { candidate: true, keyboard: false, retainedZoom: false, notchTest: true },
])("cleans up windows and isolates candidate effects (candidate=$candidate, keyboard=$keyboard, retainedZoom=$retainedZoom, onboarding=$onboarding)", async ({ candidate, keyboard, retainedZoom, onboarding = true, notchTest = false }) => {
  vi.resetModules();
  const root = mkdtempSync(join(tmpdir(), "meterusage-lifecycle-"));
  const platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const resourcesPath = Object.getOwnPropertyDescriptor(process, "resourcesPath");
  let finishReady!: () => void;
  const ready = new Promise<void>(resolve => { finishReady = resolve; });
  const application = Object.assign(new EventEmitter(), {
    isPackaged: true, setName: vi.fn(), setPath: vi.fn(), whenReady: vi.fn(() => ready),
    getLoginItemSettings: vi.fn(() => ({ openAtLogin: false })), setLoginItemSettings: vi.fn(),
    requestSingleInstanceLock: vi.fn(() => true), getVersion: () => "0.0.0", quit: vi.fn(), exit: vi.fn(),
  });
  const workArea = { x: 0, y: 0, width: 1200, height: 900 };
  let cursor = { x: 0, y: 0 };
  const display = Object.assign(new EventEmitter(), { getPrimaryDisplay: () => ({ bounds: workArea, workArea }), getDisplayNearestPoint: () => ({ bounds: workArea, workArea }), getDisplayMatching: () => ({ bounds: workArea, workArea }), getCursorScreenPoint: () => cursor });
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
  const reportFetch = vi.fn<typeof fetch>(async (_url, init) => Response.json({ id: JSON.parse(String(init?.body)).id, identifier: "MU-123" }, { status: 201 }));
  const savedCommand = vi.fn(async () => "synthetic-saved-admin");
  vi.doMock("../src/main/providers/transport", async original => ({ ...await original<typeof import("../src/main/providers/transport")>(), runCommand: savedCommand }));
  vi.stubGlobal("fetch", reportFetch);
  const openExternal = vi.fn(async (_url: string) => {});
  const notify = vi.fn();
  const showErrorBox = vi.fn();
  const showMessageBox = vi.fn(async (_window: unknown, _options: { title: string; detail: string; defaultId: number; cancelId: number }) => ({ response: 0 }));
  const prepareReset = vi.fn(() => ({ token: "fixture-intent", account: "Codex", title: "Full reset" }));
  const confirmReset = vi.fn(async () => {}), cancelReset = vi.fn();
  class TestWindow extends EventEmitter {
    destroyed = false;
    zoomFactor = 1;
    surface = "";
    bounds: { x: number; y: number; width: number; height: number };
    contents = Object.assign(new EventEmitter(), { id: windows.length + 1, mainFrame: { url: "" }, setFrameRate: vi.fn(), setZoomFactor: vi.fn((factor: number) => { this.zoomFactor = factor; }), send: vi.fn(), setWindowOpenHandler: vi.fn() });
    constructor(readonly options: { width: number; height: number; focusable?: boolean; type?: string }) { super(); this.bounds = { x: 0, y: 0, width: options.width, height: options.height }; windows.push(this); }
    get webContents() { if (this.destroyed) throw new Error("webContents is unavailable after destruction"); return this.contents; }
    static fromWebContents(contents: unknown) { return windows.find(w => w.contents === contents); }
    close = vi.fn(() => { this.destroyed = true; this.emit("closed"); });
    isDestroyed = () => this.destroyed;
    isVisible = () => false;
    getBounds = () => this.bounds;
    getContentBounds = () => ({ ...this.bounds, height: this.bounds.height - (this.surface === "settings" ? 28 : 0) });
    setBounds = vi.fn((bounds: typeof this.bounds) => { this.bounds = bounds; });
    setSize = vi.fn((width: number, height: number) => { this.bounds.width = width; this.bounds.height = height; });
    setPosition = vi.fn((x: number, y: number) => { this.bounds.x = x; this.bounds.y = y; }); show = vi.fn(); focus = vi.fn(); hide = vi.fn();
    showInactive = vi.fn(); setAlwaysOnTop = vi.fn(); setVisibleOnAllWorkspaces = vi.fn();
    loadURL = (url: string) => {
      this.contents.mainFrame.url = url;
      this.surface = new URL(url).searchParams.get("surface")!;
      if (retainedZoom && ["flyout", "settings"].includes(new URL(url).searchParams.get("surface")!)) this.zoomFactor = 1.25;
      this.contents.emit("did-finish-load"); return Promise.resolve();
    };
  }
  let finishRecovery!: () => void;
  const recovery = new Promise<void>(resolve => { finishRecovery = resolve; });
  const recover = vi.fn(() => recovery), start = vi.fn(async () => {});
  const connect = vi.fn(async (_provider: string, _open: unknown, consent: () => Promise<boolean>) => { await consent(); return false; });
  const useLocal = vi.fn(async (_provider: string) => {}), disconnect = vi.fn(async (_provider: string) => {});
  const composition = vi.fn<(_launch: unknown, _prefs: unknown, _options: { http: HTTP }) => Source[]>(() => []), refresh = vi.fn(async () => {}), forgetQuota = vi.fn();
  let activeSources: readonly Source[] = [];
  let connectionChanged!: () => void;
  let injectedHTTP: HTTP | undefined;
  const nativeFetch = vi.fn<typeof fetch>(async () => Response.json({}));
  const fromPartition = vi.fn(() => ({ isPersistent: () => false, storagePath: null, fetch: nativeFetch }));
  vi.doMock("electron", () => ({ app: application, Tray: TestTray, BrowserWindow: TestWindow, shell: { openExternal },
    screen: display, nativeTheme: theme, powerMonitor: new EventEmitter(), ipcMain: { handle: ipc }, dialog: { showErrorBox, showMessageBox },
    Notification: Object.assign(class { show = notify; }, { isSupported: () => true }),
    nativeImage: { createFromPath: () => ({ resize: () => ({ setTemplateImage: vi.fn() }) }) },
    session: { fromPartition, defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), webRequest: { onBeforeRequest: vi.fn() } } },
  }));
  const launch = { data: root, home: root, demo: false, candidate, profile: candidate ? root : undefined, codexTest: false, claudeTest: false };
  vi.doMock("../src/main/launch", () => ({ launchConfiguration: () => launch }));
  const values: Record<string, boolean | number | string | Provider[]> = { onboardingCompleted: onboarding, panelSize: "medium", sideNotchPanelPinned: notchTest };
  const setPreference = vi.fn(async (key: string, value: boolean | number | string | Provider[]) => { await Promise.resolve(); values[key] = value; });
  let finishLoad!: () => void;
  const loading = new Promise<void>(resolve => { finishLoad = resolve; });
  const load = vi.fn(async () => { await loading; return { values, accounts: [], set: setPreference }; });
  vi.doMock("../src/main/preferences", () => ({ Preferences: { load } }));
  vi.doMock("../src/main/composition", () => ({ compose: composition }));
  vi.doMock("../src/main/connections", () => ({ DesktopConnections: class {
    constructor(_launch: unknown, _prefs: unknown, _helper: unknown, changed: () => void, _command: unknown, http: HTTP) { connectionChanged = changed; injectedHTTP = http; }
    state = []; configured = () => false; recover = recover; stop = async () => {};
    connect = connect; useLocal = useLocal; disconnect = disconnect;
  } }));
  vi.doMock("../src/main/coordinator", () => ({ Coordinator: class {
    constructor(_launch: unknown, _prefs: unknown, sources: Source[], _clock: unknown, alert: (a: unknown) => void) { activeSources = sources; alert({ title: "Fixture", body: "Fixture" }); }
    get sources() { return activeSources; }
    set sources(next: readonly Source[]) { activeSources = next; }
    prepareReset = prepareReset; confirmReset = confirmReset; cancelReset = cancelReset;
    diagnostics = (version: string) => `MeterUsage ${version}\nquota: unavailable (offline)`;
    refresh = refresh; forgetQuota = forgetQuota;
    start = start; stop = vi.fn(); publish = vi.fn(); subscribe = vi.fn(() => vi.fn()); snapshot = () => ({ appearance: {}, quotas: { codex: { status: "value", value: { provider: "codex", windows: [{ label: "5-hour", usedPercent: 10 }] } } }, archived: {}, notchSlots: [{ provider: "codex", slotID: "" }, { provider: "claude", slotID: "" }] }); refreshIfStale = vi.fn();
  } }));
  vi.doMock("../src/main/updater", () => ({ Updater: class { reset = vi.fn(); } }));
  vi.doMock("../src/domain/overview", () => ({ trayTooltip: () => "Synthetic usage" }));
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    Object.defineProperty(process, "resourcesPath", { value: root, configurable: true });
    vi.stubGlobal("__dirname", root);
    await import("../src/main/electron");
    expect(application.whenReady).toHaveBeenCalledOnce();
    expect(fromPartition).not.toHaveBeenCalled();
    finishReady();
    await vi.waitFor(() => expect(load).toHaveBeenCalledOnce());
    application.emit("second-instance");
    expect(windows).toHaveLength(0);
    finishLoad();
    await vi.waitFor(() => expect(recover).toHaveBeenCalledOnce());
    expect(start).not.toHaveBeenCalled();
    expect(fromPartition).toHaveBeenCalledOnce();
    expect(fromPartition.mock.calls[0]).toEqual([expect.stringMatching(/^meterusage-claude-[a-f0-9-]+$/), { cache: false }]);
    expect(application.whenReady.mock.invocationCallOrder[0]).toBeLessThan(fromPartition.mock.invocationCallOrder[0]);
    expect(injectedHTTP).toBeTypeOf("function");
    expect(composition).toHaveBeenCalledWith(launch, expect.anything(), expect.objectContaining({ http: injectedHTTP }));
    const preloaded = windows.find(w => w.surface === "flyout");
    if (onboarding) {
      expect(preloaded).toBeDefined();
      expect(preloaded!.show).not.toHaveBeenCalled();
      expect(preloaded!.focus).not.toHaveBeenCalled();
      const reply = await ipc.mock.calls[0][1]({ sender: preloaded!.contents, senderFrame: preloaded!.contents.mainFrame }, { action: "state" });
      expect(reply).toMatchObject({ ok: true, state: { snapshot: { quotas: { codex: { status: "value" } } } } });
    } else expect(preloaded).toBeUndefined();
    const coldNavigation = preloaded && vi.spyOn(preloaded, "loadURL");
    finishRecovery();
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
    if (coldNavigation) expect(coldNavigation).not.toHaveBeenCalled();
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
    if (keyboard) {
      const request = { action: "reset", key: "codex", creditID: "fixture-credit" };
      expect(await invoke(flyout, request)).toEqual({ ok: true });
      expect(prepareReset).toHaveBeenCalledWith("codex", "fixture-credit");
      expect(showMessageBox).toHaveBeenCalledWith(flyout, expect.objectContaining({ buttons: ["Cancel", "Use reset"], defaultId: 0, cancelId: 0, message: "Use Full reset for Codex?" }));
      expect(confirmReset).not.toHaveBeenCalled(); expect(cancelReset).toHaveBeenCalledWith("fixture-intent");
      let respond!: (result: { response: number }) => void;
      showMessageBox.mockImplementationOnce(() => new Promise(resolve => { respond = resolve; }));
      const pending = invoke(flyout, request);
      expect(await invoke(flyout, request)).toEqual({ ok: false, error: "Could not complete action" });
      respond({ response: 1 }); expect(await pending).toEqual({ ok: true });
      expect(confirmReset).toHaveBeenCalledExactlyOnceWith("fixture-intent");
      const dialogs = showMessageBox.mock.calls.length;
      expect(await invoke(flyout, { ...request, creditID: "" })).toEqual({ ok: false, error: "Invalid request" });
      expect(showMessageBox).toHaveBeenCalledTimes(dialogs);
    }
    expect(await invoke(flyout, { action: "resize", height: 593 })).toEqual({ ok: true });
    expect(flyout.bounds).toMatchObject({ width: 420, height: 593 });
    await invoke(windows[2], { action: "settings" });
    const settings = windows[3];
    const usageRequest = { action: "claudeUsagePage" };
    expect(openExternal).not.toHaveBeenCalled();
    const sourceBeforeUsage = activeSources, refreshesBeforeUsage = refresh.mock.calls.length, writesBeforeUsage = setPreference.mock.calls.length;
    for (const window of windows.filter(w => w.surface !== "settings")) expect((await invoke(window, usageRequest)).ok).toBe(false);
    for (const flag of ["demo", "candidate", "codexTest", "claudeTest"] as const) {
      const previous = launch[flag]; launch[flag] = true;
      expect((await invoke(settings, usageRequest)).ok).toBe(false); launch[flag] = previous;
    }
    const previousProfile = launch.profile; launch.profile = root;
    expect((await invoke(settings, usageRequest)).ok).toBe(false); launch.profile = previousProfile;
    expect(openExternal).not.toHaveBeenCalled();
    if (!candidate) {
      expect(await invoke(settings, usageRequest)).toEqual({ ok: true });
      expect(openExternal).toHaveBeenCalledExactlyOnceWith("https://claude.ai/settings/usage");
      openExternal.mockRejectedValueOnce(new Error("SYNTHETIC_PRIVATE_SHELL_FAILURE"));
      expect(await invoke(settings, usageRequest)).toEqual({ ok: false, error: "Could not complete action" });
    } else expect((await invoke(settings, usageRequest)).ok).toBe(false);
    expect(activeSources).toBe(sourceBeforeUsage); expect(refresh).toHaveBeenCalledTimes(refreshesBeforeUsage);
    expect(setPreference).toHaveBeenCalledTimes(writesBeforeUsage); expect(connect).not.toHaveBeenCalled();

    const stableSource: Source = { slot: { provider: "codex", slotID: "", label: "" } }, museSource: Source = { slot: { provider: "muse", slotID: "", label: "" } };
    activeSources = [stableSource];
    composition.mockReturnValueOnce([stableSource, museSource]);
    expect(await invoke(settings, { action: "setPreference", key: "showProviderMuse", value: true })).toEqual({ ok: true });
    expect(activeSources).toEqual([stableSource, museSource]); expect(forgetQuota).toHaveBeenCalledWith("muse");
    const oldSources = activeSources, invalidations = forgetQuota.mock.calls.length;
    setPreference.mockRejectedValueOnce(new Error("Synthetic Muse save failure"));
    expect(await invoke(settings, { action: "setPreference", key: "showProviderMuse", value: false })).toEqual({ ok: false, error: "Could not complete action" });
    expect(activeSources).toBe(oldSources); expect(forgetQuota).toHaveBeenCalledTimes(invalidations);
    composition.mockReturnValueOnce([stableSource]);
    expect(await invoke(settings, { action: "setPreference", key: "showProviderMuse", value: false })).toEqual({ ok: true });
    expect(activeSources).toEqual([stableSource]);
    expect(reportFetch).not.toHaveBeenCalled();
    expect(await invoke(flyout, { action: "sendReport" })).toEqual({ ok: false, error: "Could not complete action" });
    expect(reportFetch).not.toHaveBeenCalled();
    expect(await invoke(settings, { action: "sendReport", diagnostics: "renderer text" })).toEqual({ ok: false, error: "Invalid request" });
    expect(reportFetch).not.toHaveBeenCalled();
    expect(await invoke(settings, { action: "sendReport" })).toEqual({ ok: true });
    expect(reportFetch).toHaveBeenCalledOnce();
    expect(JSON.parse(String(reportFetch.mock.calls[0][1]?.body)).diagnostics).toBe("MeterUsage 0.0.0\nquota: unavailable (offline)");
    expect((await invoke(settings, { action: "state" })).state.issueReport).toMatchObject({ sending: false, receipt: "MU-123", retryAt: expect.any(Number) });
    expect((await invoke(flyout, { action: "state" })).state).not.toHaveProperty("issueReport");
    await invoke(settings, { action: "sendReport" });
    expect(reportFetch).toHaveBeenCalledOnce();
    const billingRequest = { action: "apiBillingFetch", provider: "openai", adminKey: "synthetic-settings-admin" };
    const savedRequest = { action: "apiBillingFetchSaved", provider: "openai" };
    for (const window of windows.filter(w => w.surface !== "settings")) {
      expect((await invoke(window, savedRequest)).ok).toBe(false);
    }
    expect(savedCommand).not.toHaveBeenCalled();
    const callsBeforeBilling = reportFetch.mock.calls.length;
    expect(await invoke(flyout, billingRequest)).toEqual({ ok: false, error: "Open Settings to fetch API billing." });
    expect(await invoke(windows[0], billingRequest)).toEqual({ ok: false, error: "Invalid request" });
    expect(await ipc.mock.calls[0][1]({ sender: settings.contents, senderFrame: { ...settings.contents.mainFrame } }, billingRequest)).toEqual({ ok: false, error: "Untrusted renderer" });
    const settingsURL = settings.contents.mainFrame.url;
    settings.contents.mainFrame.url = settingsURL + "&unregistered=1";
    expect(await invoke(settings, billingRequest)).toEqual({ ok: false, error: "Untrusted renderer" });
    settings.contents.mainFrame.url = settingsURL;
    expect(await ipc.mock.calls[0][1]({ sender: { id: -1, mainFrame: settings.contents.mainFrame }, senderFrame: settings.contents.mainFrame }, billingRequest)).toEqual({ ok: false, error: "Untrusted renderer" });
    expect(await invoke(settings, { ...billingRequest, adminKey: "synthetic\x01admin" })).toEqual({ ok: false, error: "Invalid request" });
    expect(reportFetch).toHaveBeenCalledTimes(callsBeforeBilling);
    if (candidate) {
      expect(await invoke(settings, savedRequest)).toEqual({ ok: false, error: "API billing fetch is unavailable in demo or isolated profiles." });
      expect(savedCommand).not.toHaveBeenCalled();
      expect(await invoke(settings, billingRequest)).toEqual({ ok: false, error: "API billing fetch is unavailable in demo or isolated profiles." });
      expect(reportFetch).toHaveBeenCalledTimes(callsBeforeBilling);
    } else {
      reportFetch.mockResolvedValueOnce(Response.json({ has_more: false, data: [] }));
      expect(await invoke(settings, savedRequest)).toEqual({ ok: true });
      expect(savedCommand).toHaveBeenCalledExactlyOnceWith(join(root, "desktop-keychain"), ["--api-openai", "--allow-ui"], { signal: expect.any(AbortSignal), timeoutMs: 60000, maxBytes: 8192 });
      expect(new Headers(reportFetch.mock.calls.at(-1)![1]?.headers).get("authorization")).toBe("Bearer synthetic-saved-admin");
      for (const provider of ["openai", "anthropic"]) {
        reportFetch.mockResolvedValueOnce(Response.json({ has_more: false, data: [] }));
        const refreshes = refresh.mock.calls.length;
        expect(await invoke(settings, { ...billingRequest, provider })).toEqual({ ok: true });
        expect(refresh).toHaveBeenCalledTimes(refreshes + 1);
      }
      reportFetch.mockResolvedValueOnce(new Response(billingRequest.adminKey, { status: 401 }));
      expect(await invoke(settings, billingRequest)).toEqual({ ok: false, error: "API billing authentication failed" });
      reportFetch.mockRejectedValueOnce(new Error(billingRequest.adminKey));
      expect(await invoke(settings, billingRequest)).toEqual({ ok: false, error: "API billing data unavailable" });
    }
    const billingState = await invoke(settings, { action: "state" });
    expect(JSON.stringify([billingState, ...windows.flatMap(w => w.contents.send.mock.calls)])).not.toContain(billingRequest.adminKey);
    expect(JSON.stringify([billingState, ...windows.flatMap(w => w.contents.send.mock.calls)])).not.toContain("synthetic-saved-admin");
    if (keyboard) {
      settings.bounds = { x: 160, y: 100, width: 740, height: 680 };
      const resizeSettings = (height: number) => invoke(settings, { action: "resize", height, width: 10000 });
      expect(await resizeSettings(300.2)).toEqual({ ok: true });
      expect(settings.bounds).toEqual({ x: 160, y: 100, width: 740, height: 329 });
      await resizeSettings(180);
      expect(settings.bounds).toEqual({ x: 160, y: 100, width: 740, height: 208 });
      values.panelSize = "small";
      await resizeSettings(700);
      expect(settings.bounds).toEqual({ x: 160, y: 100, width: 740, height: 728 });
      values.panelSize = "medium";
      await resizeSettings(1000);
      expect(settings.bounds).toEqual({ x: 160, y: 100, width: 740, height: 800 });
      const fits = settings.setBounds.mock.calls.length;
      await resizeSettings(1000);
      expect(settings.setBounds).toHaveBeenCalledTimes(fits);
      for (const event of ["display-metrics-changed", "display-removed"]) {
        workArea.height = 500;
        display.emit(event);
        expect(settings.bounds).toEqual({ x: 160, y: 100, width: 740, height: 400 });
        workArea.height = 1200;
        display.emit(event);
        expect(settings.bounds).toEqual({ x: 160, y: 100, width: 740, height: 1028 });
      }
      workArea.height = 900;
      workArea.x = -1000; workArea.y = 30; workArea.width = 800; workArea.height = 500;
      settings.bounds = { x: -300, y: 60, width: 740, height: 800 };
      await resizeSettings(1000);
      expect(settings.bounds).toEqual({ x: -940, y: 60, width: 740, height: 470 });
      settings.bounds = { x: 160, y: 950, width: 900, height: 680 };
      await resizeSettings(300);
      expect(settings.bounds).toEqual({ x: -1000, y: 30, width: 800, height: 328 });
      Object.assign(workArea, { x: 0, y: 0, width: 1200, height: 900 });
      expect(await invoke(windows[0], { action: "connectionLocal", provider: "codex" })).toEqual({ ok: false, error: "Invalid request" });
      expect(useLocal).not.toHaveBeenCalled();
      for (const source of [settings, flyout]) {
        useLocal.mockImplementationOnce(async provider => { expect(provider).toBe("codex"); values.desktopCodexConnection = ""; connectionChanged(); });
        const compositions = composition.mock.calls.length, refreshes = refresh.mock.calls.length;
        expect(await invoke(source, { action: "connectionLocal", provider: "codex" })).toEqual({ ok: true });
        if (source === settings) {
          expect(forgetQuota).toHaveBeenCalledWith("codex"); expect(composition).toHaveBeenCalledTimes(compositions + 1);
          expect(forgetQuota.mock.invocationCallOrder.at(-1)).toBeLessThan(refresh.mock.invocationCallOrder.at(-1)!);
        }
        expect(refresh).toHaveBeenCalledTimes(refreshes + 1);
        expect(source.contents.send.mock.lastCall?.[0]).toBe("meterusage:state");
      }
      expect(disconnect).not.toHaveBeenCalled();
      for (const message of ["Could not disconnect Codex", "OMIT_PRIVATE_LOCAL_ERROR token=synthetic-secret account=synthetic-account path=/private/store"]) {
        const refreshes = refresh.mock.calls.length;
        useLocal.mockRejectedValueOnce(new Error(message));
        expect(await invoke(settings, { action: "connectionLocal", provider: "codex" })).toEqual({ ok: false, error: message.startsWith("OMIT") ? "Could not complete action" : message });
        expect(refresh).toHaveBeenCalledTimes(refreshes);
      }
      const order = ["claude" as const, ...providers.filter(p => p !== "claude")];
      const writes = setPreference.mock.calls.length;
      expect(await invoke(flyout, { action: "providerOrder", order })).toEqual({ ok: false, error: "Invalid request" });
      expect(setPreference).toHaveBeenCalledTimes(writes);
      setPreference.mockRejectedValueOnce(new Error("Synthetic order save failure"));
      expect(await invoke(settings, { action: "providerOrder", order })).toEqual({ ok: false, error: "Could not complete action" });
      expect(values.providerOrder).toBeUndefined();
      expect(await invoke(settings, { action: "providerOrder", order })).toEqual({ ok: true });
      expect(values.providerOrder).toEqual(order);
      expect(settings.contents.send.mock.lastCall?.[1].settings.providerOrder).toEqual(order);
      for (const request of [
        { action: "connect", provider: "antigravity", message: "Open one Antigravity Desktop account and sign in, then try connecting again" },
        { action: "disconnect", provider: "antigravity", message: "Could not disconnect Antigravity Desktop" },
      ] as const) {
        if (request.action === "connect") connect.mockRejectedValueOnce(new Error(request.message));
        else disconnect.mockRejectedValueOnce(new Error(request.message));
        expect(await invoke(settings, { action: request.action, provider: request.provider })).toEqual({ ok: false, error: request.message });
      }
      for (const response of [0, 1]) {
        showMessageBox.mockResolvedValueOnce({ response });
        connect.mockImplementationOnce(async (provider, _open, consent) => { expect(provider).toBe("grok"); expect(await consent()).toBe(response === 1); return false; });
        expect(await invoke(settings, { action: "connect", provider: "grok" })).toEqual({ ok: true });
        expect(showMessageBox.mock.lastCall?.[1]).toMatchObject({ title: "Connect Grok Bot Desktop (Beta)?", defaultId: 0, cancelId: 0 });
        expect(showMessageBox.mock.lastCall?.[1].detail).toContain("fixed Grok Bot Safe Storage Keychain item");
      }
      connect.mockImplementationOnce(async () => { throw new Error("Could not connect Grok Bot Desktop. Sign in to Grok Bot, check allowance and Keychain access, then reconnect."); });
      expect(await invoke(settings, { action: "connect", provider: "grok" })).toEqual({ ok: false, error: "Could not connect Grok Bot Desktop. Sign in to Grok Bot, check allowance and Keychain access, then reconnect." });
      for (const message of Object.values(grokBotConnectionErrors)) {
        connect.mockImplementationOnce(async () => { throw new Error(message); });
        expect(await invoke(settings, { action: "connect", provider: "grok" })).toEqual({ ok: false, error: message });
      }
      connect.mockImplementationOnce(async () => { throw new Error("PRIVATE_PROVIDER_ERROR private-secret-value"); });
      expect(await invoke(settings, { action: "connect", provider: "grok" })).toEqual({ ok: false, error: "Could not complete action" });
      useLocal.mockImplementationOnce(async () => { values.desktopGrokIdentity = ""; connectionChanged(); });
      values.desktopGrokIdentity = "a".repeat(64); connectionChanged();
      expect(composition.mock.calls.every(call => call[2].http === injectedHTTP)).toBe(true);
      expect(forgetQuota).toHaveBeenCalledWith("grok");
      expect(await invoke(settings, { action: "connectionLocal", provider: "grok" })).toEqual({ ok: true });
      expect(forgetQuota).toHaveBeenCalledWith("grok");
      for (const message of [
        "Could not access Claude Desktop through macOS Keychain. Check the access prompt, then try connecting again.",
        "Could not read Claude Desktop's account configuration.",
        "Could not read Claude Desktop's active organization cookie.",
        "Could not decrypt Claude Desktop's session cookies with its Keychain entry.",
        "Claude Desktop's cache has no current session for the active account and organization.",
        "Claude Desktop's cache has conflicting session or organization cookies. MeterUsage cannot safely choose one.",
        "Could not read Claude account allowance. Try connecting again later.",
        "Claude requires browser verification for account allowance. Open Claude usage to view it in your browser. Your current source is unchanged.",
        "Could not verify the same Claude Desktop account after the allowance request. Try connecting again.",
        "Could not save the Claude Desktop connection preferences. Try connecting again.",
        "OMIT_PRIVATE_CONNECT_ERROR token=synthetic-secret account=synthetic-account path=/private/store",
      ]) {
        showMessageBox.mockResolvedValueOnce({ response: 1 });
        connect.mockImplementationOnce(async (_provider, _open, consent) => { expect(await consent()).toBe(true); throw new Error(message); });
        expect(await invoke(settings, { action: "connect", provider: "claude" })).toEqual({ ok: false, error: message.startsWith("OMIT") ? "Could not complete action" : message });
        expect(showMessageBox.mock.lastCall?.[1].detail).toContain("session cookie");
        expect(showMessageBox.mock.lastCall?.[1].detail).toContain("account identity, organization membership and allowance");
        expect(showMessageBox.mock.lastCall?.[1].detail).toContain("Previous access-token consent requires this new approval");
      }
    }
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
    if (notchTest) {
      vi.useFakeTimers();
      await invoke(settings, { action: "setPreference", key: "sideNotchPanelEnabled", value: true });
      const panel = windows.find(w => w.surface === "notch")!;
      expect((await invoke(panel, { action: "claudeUsagePage" })).ok).toBe(false);
      expect(panel.options).toMatchObject({ type: "panel", focusable: false });
      expect(panel.bounds.width).toBe(36);
      expect(panel.showInactive).toHaveBeenCalled(); expect(panel.focus).not.toHaveBeenCalled();
      const hover = (hovering: boolean) => invoke(panel, { action: "notchHover", hovering });
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 };
      await hover(true);
      const expanded = { ...panel.bounds };
      expect(expanded.width).toBe(256);
      vi.advanceTimersByTime(600); expect(panel.bounds.width).toBe(256);
      // The native cursor leaves without Chromium sending pointerleave or blur.
      cursor = { x: 0, y: 0 };
      vi.advanceTimersByTime(549); expect(panel.bounds.width).toBe(256);
      vi.advanceTimersByTime(1); expect(panel.bounds.width).toBe(36);
      expect(panel.bounds.y).toBe(expanded.y);
      expect(panel.bounds.x + panel.bounds.width).toBe(expanded.x + expanded.width);
      expect(panel.hide).not.toHaveBeenCalled();
      // A legacy saved pin remains untouched and cannot keep details open.
      expect(values.sideNotchPanelPinned).toBe(true);
      for (const key of ["claude", "codex"]) {
        cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 };
        await hover(true); await invoke(panel, { action: "notchSelect", key });
        expect(panel.bounds.width).toBe(256);
        expect(panel.contents.send.mock.calls.at(-1)?.[1].notch.selected).toBe(key);
        await hover(false); cursor = { x: 0, y: 0 };
        vi.advanceTimersByTime(449); expect(panel.bounds.width).toBe(256);
        vi.advanceTimersByTime(1); expect(panel.bounds.width).toBe(36);
      }
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 }; await hover(true);
      let respond!: (result: { response: number }) => void;
      showMessageBox.mockImplementationOnce(() => new Promise(resolve => { respond = resolve; }));
      const pending = invoke(panel, { action: "reset", key: "codex", creditID: "fixture-credit" });
      cursor = { x: 0, y: 0 }; vi.advanceTimersByTime(1000); expect(panel.bounds.width).toBe(256);
      respond({ response: 0 }); await pending;
      vi.advanceTimersByTime(450); expect(panel.bounds.width).toBe(36);
      // A pending share render retains details outside the panel; failure releases it.
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 }; await hover(true);
      const sharing = invoke(panel, { action: "share", key: "codex" });
      expect((await invoke(windows.find(w => w.surface === "share")!, { action: "claudeUsagePage" })).ok).toBe(false);
      cursor = { x: 0, y: 0 }; vi.advanceTimersByTime(1000);
      expect(panel.bounds.width).toBe(256);
      vi.advanceTimersByTime(4000);
      expect(await sharing).toEqual({ ok: false, error: "Could not share snapshot" });
      vi.advanceTimersByTime(450); expect(panel.bounds.width).toBe(36);
      expect(confirmReset).not.toHaveBeenCalled();
      expect(showMessageBox).toHaveBeenCalledWith(panel, expect.objectContaining({ defaultId: 0, cancelId: 0 }));
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 }; await hover(true);
      await hover(false); vi.advanceTimersByTime(200); await hover(true);
      vi.advanceTimersByTime(500); expect(panel.bounds.width).toBe(256);
      await invoke(panel, { action: "dragStart" });
      expect(panel.bounds.width).toBe(36);
      cursor = { x: 0, y: 0 };
      await invoke(panel, { action: "dragEnd" });
      vi.advanceTimersByTime(1000); expect(panel.bounds.width).toBe(36);
      expect(panel.contents.send.mock.lastCall?.[1].notch).toMatchObject({ expanded: false, dragging: false });
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 }; await hover(true);
      await invoke(panel, { action: "dragStart" }); await invoke(panel, { action: "dragEnd" });
      expect(panel.bounds.width).toBe(256);
      cursor = { x: 0, y: 0 }; vi.advanceTimersByTime(550); expect(panel.bounds.width).toBe(36);
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 };
      await invoke(panel, { action: "notchSelect", key: "codex" });
      expect(panel.bounds.width).toBe(256);
      cursor = { x: 0, y: 0 }; vi.advanceTimersByTime(550); expect(panel.bounds.width).toBe(36);
      await hover(true);
      await invoke(settings, { action: "setPreference", key: "sideNotchPanelEnabled", value: false });
      expect(panel.hide).toHaveBeenCalled();
      expect(panel.contents.send.mock.lastCall?.[1].notch.expanded).toBe(false);
      cursor = { x: 0, y: 0 };
      await invoke(settings, { action: "setPreference", key: "sideNotchPanelEnabled", value: true });
      expect(panel.bounds.width).toBe(36);
      expect(panel.contents.send.mock.lastCall?.[1].notch.expanded).toBe(false);
      vi.advanceTimersByTime(1000); expect(panel.bounds.width).toBe(36);
      cursor = { x: panel.bounds.x + 10, y: panel.bounds.y + 10 }; await hover(true);
      expect(panel.bounds.width).toBe(256);
      cursor = { x: 0, y: 0 }; await hover(false);
      vi.advanceTimersByTime(450); expect(panel.bounds.width).toBe(36);
      await invoke(settings, { action: "setPreference", key: "sideNotchPanelEnabled", value: false });
      const writes = setPreference.mock.calls.length;
      vi.advanceTimersByTime(1000); expect(setPreference).toHaveBeenCalledTimes(writes);
    }
    destroyed = true;
    expect(() => display.emit("display-metrics-changed")).not.toThrow();
    expect(() => display.emit("display-removed")).not.toThrow();
    expect(() => theme.emit("updated")).not.toThrow();
    if (!candidate) {
      let finishBilling!: (response: Response) => void;
      reportFetch.mockImplementationOnce(() => new Promise(resolve => { finishBilling = resolve; }));
      const refreshes = refresh.mock.calls.length;
      const pendingBilling = invoke(settings, billingRequest);
      expect(await invoke(settings, billingRequest)).toEqual({ ok: false, error: "API billing fetch is already in progress for this provider." });
      const signal = reportFetch.mock.calls.at(-1)?.[1]?.signal;
      application.emit("before-quit", { preventDefault: vi.fn() });
      expect(signal?.aborted).toBe(true);
      finishBilling(Response.json({ has_more: false, data: [] }));
      expect(await pendingBilling).toEqual({ ok: false, error: "API billing data unavailable" });
      expect(refresh).toHaveBeenCalledTimes(refreshes);
      expect(await invoke(settings, billingRequest)).toEqual({ ok: false, error: "API billing data unavailable" });
    }
  } finally {
    finishLoad();
    finishRecovery();
    application.emit("before-quit", { preventDefault: vi.fn() });
    await Promise.resolve();
    vi.useRealTimers();
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
    session: { fromPartition: () => ({ isPersistent: () => false, storagePath: null, fetch: vi.fn() }), defaultSession: { setPermissionRequestHandler: vi.fn(), setPermissionCheckHandler: vi.fn(), webRequest: { onBeforeRequest: vi.fn() } } },
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

it("keeps JSON startup outside app readiness and native sessions", async () => {
  vi.resetModules();
  const argv = process.argv, platform = Object.getOwnPropertyDescriptor(process, "platform")!;
  const fromPartition = vi.fn(() => { throw new Error("JSON cannot create a native session"); });
  const application = { isPackaged: false, setName: vi.fn(), whenReady: vi.fn(), exit: vi.fn() };
  const runJSON = vi.fn(async () => "synthetic-report"), load = vi.fn();
  vi.doMock("electron", () => ({ app: application, session: { fromPartition } }));
  vi.doMock("../src/main/launch", () => ({ launchConfiguration: () => ({ demo: false, candidate: false }) }));
  vi.doMock("../src/main/cli", () => ({ runJSON }));
  vi.doMock("../src/main/preferences", () => ({ Preferences: { load } }));
  const stdout = vi.spyOn(process.stdout, "write").mockReturnValue(true);
  try {
    Object.defineProperty(process, "platform", { value: "darwin" });
    process.argv = [argv[0], "meterusage", "--json"];
    vi.stubGlobal("__dirname", tmpdir());
    await import("../src/main/electron");
    await vi.waitFor(() => expect(application.exit).toHaveBeenCalledWith(0));
    expect(runJSON).toHaveBeenCalledOnce(); expect(stdout).toHaveBeenCalledWith("synthetic-report\n");
    expect(application.whenReady).not.toHaveBeenCalled(); expect(fromPartition).not.toHaveBeenCalled(); expect(load).not.toHaveBeenCalled();
  } finally {
    process.argv = argv; Object.defineProperty(process, "platform", platform); vi.restoreAllMocks(); vi.unstubAllGlobals();
    for (const name of ["electron", "../src/main/launch", "../src/main/cli", "../src/main/preferences"]) vi.doUnmock(name);
  }
});
