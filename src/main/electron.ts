import { app, BrowserWindow, Tray, Menu, nativeImage, ipcMain, screen, nativeTheme, dialog, clipboard, Notification, ShareMenu, session, powerMonitor, shell } from "electron";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { randomUUID } from "node:crypto";
import { launchConfiguration, type Launch } from "./launch";
import { Preferences } from "./preferences";
import { compose } from "./composition";
import { DesktopConnections } from "./connections";
import { Coordinator } from "./coordinator";
import { NotchFold } from "./notch-fold";
import { Updater } from "./updater";
import { runJSON } from "./cli";
import { channel, stateChannel, statusPages, panelScales, PanelSize, type ViewState, type Surface, type Request, type Reply } from "../shared/ipc";
import { parseRequest, trustedSender, projectSettings, shareSnapshot } from "./ipc";
import { providers, slotKey } from "../domain/models";
import { notchFrame, cardOnRight, stripWidth, cardWidth, minimumShareSize } from "../domain/notch";
import { trayTooltip } from "../domain/overview";

const args = process.argv.slice(1);
const desktopHelper = app.isPackaged ? join(process.resourcesPath, "desktop-keychain") : join(__dirname, "../../build/desktop-keychain");
void main().catch(() => { process.stderr.write("MeterUsage could not start.\n"); app.exit(1); });
async function main() {
  const json = args.includes("json") || args.includes("--json");
  const launch = launchConfiguration(args, process.env, undefined, !json && process.platform === "darwin");
  // Validate isolation before Electron creates a session or contacts a singleton socket.
  if (launch.profile) { app.setPath("userData", join(launch.data, "electron")); app.setPath("sessionData", join(launch.data, "electron")); }
  app.setName("MeterUsage");
  if (json) {
    await runJSON(args, process.env, desktopHelper).then(json => { process.stdout.write(json + "\n"); app.exit(0); }, () => { process.stderr.write("meterusage: could not read report\n"); app.exit(1); });
  } else if (process.platform !== "darwin") {
    process.stderr.write("MeterUsage desktop candidates currently support macOS only.\n"); app.exit(1);
  } else {
    let reveal: (() => void) | undefined, requested = false;
    const activate = () => { if (reveal) reveal(); else requested = true; };
    app.on("second-instance", activate); app.on("activate", activate);
    if (!app.requestSingleInstanceLock({ candidate: launch.candidate || launch.demo })) { app.quit(); return; }
    await app.whenReady();
    reveal = await start(launch);
    if (requested) reveal?.();
  }
}
async function start(launch: Launch) {
  mkdirSync(launch.data, { recursive: true });
  app.dock?.hide();
  const prefs = await Preferences.load(launch);
  const documents = new Map<number, string>(), windows = new Map<Surface, BrowserWindow>();
  const markers = { codex: prefs.values.desktopCodexConnection, claude: prefs.values.desktopClaudeIdentity };
  const connections = new DesktopConnections(launch, prefs, desktopHelper, () => {
    const changed = (["codex", "claude"] as const).filter(p => markers[p] !== prefs.values[p === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity"]);
    if (changed.length) {
      for (const p of changed) { markers[p] = prefs.values[p === "codex" ? "desktopCodexConnection" : "desktopClaudeIdentity"]; coordinator.forgetQuota(p); }
      coordinator.sources = sources();
    }
    publish();
  });
  const sources = () => compose(launch, prefs, { connections });
  const coordinator = new Coordinator(launch, prefs, sources(), Date.now, alert => {
    if (!launch.demo && !launch.candidate && Notification.isSupported()) new Notification({ title: alert.title, body: alert.body, silent: !alert.sound }).show();
  }, sources);
  // Do not restore a legacy archive under a newly connected account.
  for (const p of ["codex", "claude"] as const) if (connections.configured(p)) coordinator.forgetQuota(p);
  const notch = { expanded: prefs.values.sideNotchPanelPinned === true, cardOnRight: false, selected: "codex", dragging: false };
  let notchHeight = 200, anchor: { x: number; y: number } | undefined;
  let flyoutHeight = 700;
  const panelScale = () => panelScales[prefs.values.panelSize as PanelSize] ?? 1;
  let panelSizeKeys = Promise.resolve();
  let drag: { cursor: Electron.Point; anchor: Electron.Point; timer: ReturnType<typeof setInterval>; timeout: ReturnType<typeof setTimeout> } | undefined;
  let shareMenu: ShareMenu | undefined, shareDirectory: string | undefined, sharing = false, confirmingReset = false, trayWidth = 0;
  const sharedDirectories = new Set<string>();
  const icon = nativeImage.createFromPath(join(__dirname, "../renderer/AppIcon.png")).resize({ width: 18, height: 18 }); icon.setTemplateImage(true);
  const tray = new Tray(icon);
  tray.setToolTip("MeterUsage");
  tray.on("right-click", () => tray.popUpContextMenu(Menu.buildFromTemplate([{ label: "Open MeterUsage", click: () => showUsage() }, { label: "Settings…", click: () => showSettings() }, { type: "separator" }, { label: "Quit MeterUsage", role: "quit" }])));
  tray.on("click", () => { const w = windows.get("flyout"); w?.isVisible() ? w.hide() : showUsage(); });
  let shareState: ViewState | undefined, shareHeight = 0, shareReady: ((image: Electron.NativeImage) => void) | undefined, shareFailed: ((error: Error) => void) | undefined;
  const state = (surface?: Surface): ViewState => surface === "share" && shareState ? shareState : ({ connections: connections.state, snapshot: coordinator.snapshot(), settings: projectSettings(prefs.values, prefs.accounts, launch.home, surface), systemDark: nativeTheme.shouldUseDarkColorsForSystemIntegratedUI, notch: { ...notch, maxHeight: Math.floor((anchor ? screen.getDisplayNearestPoint(anchor) : screen.getPrimaryDisplay()).workArea.height) }, update: updater.visible ? { version: updater.visible.version, state: updater.installState } : undefined });
  const updater = new Updater(prefs, app.getVersion(), publish, undefined, release => {
    if (!launch.demo && !launch.candidate && Notification.isSupported()) new Notification({ title: "MeterUsage update available", body: `MeterUsage ${release.version} is ready to install.`, silent: true }).show();
  });
  const folding = new NotchFold(() => prefs.values.sideNotchPanelPinned === true || sharing || confirmingReset || notch.dragging, () => { notch.expanded = false; placeNotch(); publish(); });
  function publish() {
    if (tray.isDestroyed()) return;
    const s = state();
    for (const [surface, w] of windows) if (!w.isDestroyed()) w.webContents.send(stateChannel, surface === "settings" || surface === "share" ? state(surface) : s);
    tray.setToolTip(trayTooltip(s.snapshot));
  }
  // Only fixed public status pages can open externally through main.
  session.defaultSession.setPermissionRequestHandler((_wc, _permission, callback) => callback(false));
  session.defaultSession.setPermissionCheckHandler(() => false);
  session.defaultSession.webRequest.onBeforeRequest((details, callback) => callback({ cancel: !details.url.startsWith("file://") && !details.url.startsWith("data:") }));
  function create(surface: Surface) {
    const existing = windows.get(surface); if (existing && !existing.isDestroyed()) return existing;
    const panel = surface === "notch", trayImage = surface === "tray", shareImage = surface === "share";
    const w = new BrowserWindow({ width: shareImage ? cardWidth * 2 : trayImage ? 1000 : panel ? stripWidth : surface === "settings" ? 620 : Math.round(420 * panelScale()), height: trayImage ? 22 : panel ? notchHeight : surface === "settings" ? 680 : Math.ceil(flyoutHeight * panelScale()), show: false, frame: surface === "settings", transparent: panel || trayImage || shareImage, resizable: surface === "settings", minimizable: false, maximizable: false, fullscreenable: false, skipTaskbar: true, ...(panel ? { type: "panel", focusable: false, hasShadow: false } : {}), title: surface === "settings" ? "MeterUsage Settings" : "MeterUsage", backgroundColor: panel || trayImage || shareImage ? "#00000000" : "#242428", webPreferences: { preload: join(__dirname, "../preload/preload.cjs"), offscreen: trayImage || shareImage, zoomFactor: shareImage ? 2 : 1, sandbox: true, contextIsolation: true, nodeIntegration: false, webSecurity: true, spellcheck: false } });
    if (trayImage) { w.webContents.setFrameRate(10); w.webContents.on("paint", (_event, _rect, image) => { if (!tray.isDestroyed() && trayWidth > 0) tray.setImage(image); }); }
    if (shareImage) {
      w.webContents.setFrameRate(10);
      w.webContents.on("paint", (_event, _rect, image) => {
        const size = image.getSize();
        if (shareReady && shareHeight > 0 && size.width >= cardWidth * 2 && size.height >= shareHeight) { const ready = shareReady; shareReady = undefined; ready(image); }
      });
    }
    const document = pathToFileURL(join(__dirname, "../renderer/index.html")); document.searchParams.set("surface", surface);
    const webContentsId = w.webContents.id;
    documents.set(webContentsId, document.href); windows.set(surface, w);
    w.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
    w.webContents.on("will-navigate", e => e.preventDefault()); w.webContents.on("will-attach-webview", e => e.preventDefault());
    if (surface === "flyout" || surface === "settings") {
      // A saved Chromium zoom would compound the persisted CSS panel scale.
      w.webContents.on("did-finish-load", () => w.webContents.setZoomFactor(1));
      w.webContents.on("before-input-event", (event, input) => {
        if (input.type !== "keyDown" || input.alt || !(input.control || input.meta) || !["+", "=", "-", "0"].includes(input.key)) return;
        event.preventDefault();
        panelSizeKeys = panelSizeKeys.then(async () => {
          if (quitting || w.isDestroyed()) return;
          const sizes = Object.values(PanelSize), current = sizes.indexOf(prefs.values.panelSize as PanelSize);
          const value = input.key === "0" ? PanelSize.Medium : sizes[Math.max(0, Math.min(sizes.length - 1, (current < 0 ? 1 : current) + (input.key === "-" ? -1 : 1)))];
          if (value !== prefs.values.panelSize) await handle({ action: "setPreference", key: "panelSize", value }, w, surface);
        }).catch(() => { dialog.showErrorBox("Could not change panel size", "Your panel size was not saved. Try again."); });
      });
    }
    w.on("closed", () => { documents.delete(webContentsId); if (windows.get(surface) === w) windows.delete(surface); if (panel) finishDrag(); });
    if (surface === "flyout") w.on("blur", () => { if (!sharing) w.hide(); });
    if (panel) { w.setAlwaysOnTop(true, "status"); w.setVisibleOnAllWorkspaces(true, { visibleOnFullScreen: true }); }
    void w.loadURL(document.href).then(() => { publish(); if (panel) { placeNotch(); w.showInactive(); } });
    return w;
  }
  function showFlyout() {
    const w = create("flyout"), bounds = tray.getBounds(), work = screen.getDisplayNearestPoint({ x: bounds.x, y: bounds.y }).workArea;
    w.setPosition(Math.round(Math.min(Math.max(bounds.x + bounds.width / 2 - w.getBounds().width / 2, work.x), work.x + work.width - w.getBounds().width)), work.y);
    sizeFlyout(); w.show(); w.focus(); void coordinator.refreshIfStale();
  }
  function showUsage() { if (prefs.values.onboardingCompleted === true) showFlyout(); else showSettings(); }
  function sizeFlyout() {
    const w = windows.get("flyout"); if (!w || w.isDestroyed()) return;
    const bounds = w.getBounds(), work = screen.getDisplayMatching(bounds).workArea;
    const width = Math.min(Math.round(420 * panelScale()), work.width), height = Math.min(Math.ceil(flyoutHeight * panelScale()), work.height);
    w.setBounds({ x: Math.round(Math.min(Math.max(bounds.x, work.x), work.x + work.width - width)), y: Math.round(Math.min(Math.max(bounds.y, work.y), work.y + work.height - height)), width, height }, false);
  }
  function showSettings() {
    if (!launch.demo && !launch.candidate && app.isPackaged) prefs.values.launchAtLogin = app.getLoginItemSettings().openAtLogin;
    windows.get("flyout")?.hide(); const w = create("settings"); publish(); w.show(); w.focus();
  }
  function restoreAnchor() {
    const raw = String(prefs.values.sideNotchPanelCorner), nums = raw.split(",").map(Number);
    if (raw && nums.length === 2 && nums.every(Number.isFinite)) {
      // AppKit persisted a bottom-left-origin corner. Electron uses a
      // top-left origin, relative to the primary display's coordinate space.
      const primary = screen.getPrimaryDisplay().bounds;
      anchor = { x: nums[0], y: primary.y + primary.height - nums[1] };
    }
  }
  function placeNotch() {
    const w = windows.get("notch"); if (!w || w.isDestroyed() || notch.dragging) return;
    const display = anchor ? screen.getDisplayNearestPoint(anchor) : screen.getPrimaryDisplay();
    const point = anchor ?? { x: display.bounds.x + display.bounds.width - 4, y: Math.max(display.workArea.y, display.bounds.y + 25) };
    notch.cardOnRight = cardOnRight(point.x, display.workArea);
    w.setBounds(notchFrame(point, { width: stripWidth + (notch.expanded ? cardWidth : 0), height: notchHeight }, notch.cardOnRight, display.workArea), false);
  }
  function syncNotch() {
    if (prefs.values.sideNotchPanelEnabled) { create("notch"); placeNotch(); windows.get("notch")?.showInactive(); }
    else { finishDrag(); windows.get("notch")?.hide(); }
  }
  function finishDrag() {
    if (!drag) return;
    clearInterval(drag.timer); clearTimeout(drag.timeout); drag = undefined; notch.dragging = false;
    notch.expanded = prefs.values.sideNotchPanelPinned === true || folding.hovered; folding.changed();
    if (anchor) {
      const primary = screen.getPrimaryDisplay().bounds;
      void prefs.set("sideNotchPanelCorner", `${anchor.x},${primary.y + primary.height - anchor.y}`).catch(() => {});
    }
    placeNotch(); publish();
  }
  function startDrag() {
    if (drag) return;
    const w = windows.get("notch"); if (!w) return;
    folding.cancel(); notch.expanded = false; placeNotch();
    const bounds = w.getBounds(); anchor = { x: bounds.x + stripWidth, y: bounds.y };
    notch.dragging = true;
    const origin = { ...anchor }, cursor = screen.getCursorScreenPoint();
    drag = { cursor, anchor: origin, timer: setInterval(() => {
      const at = screen.getCursorScreenPoint(); anchor = { x: Math.round(origin.x + at.x - cursor.x), y: Math.round(origin.y + at.y - cursor.y) };
      w.setPosition(anchor.x - stripWidth, anchor.y, false);
    }, 16), timeout: setTimeout(finishDrag, 60000) };
    publish();
  }
  async function handle(r: Request, source: BrowserWindow, surface: Surface): Promise<Reply> {
    if (surface === "tray" && !["state", "resize"].includes(r.action) || surface === "share" && !["state", "shareResize"].includes(r.action)) throw new Error("Invalid request");
    switch (r.action) {
      case "state": return { ok: true, state: state(surface) };
      case "refresh": await coordinator.refresh(); break;
      case "settings": showSettings(); break;
      case "statusPage":
        if (surface !== "flyout") throw new Error("Invalid request");
        await shell.openExternal(statusPages[r.provider]); break;
      case "close": source.hide(); break;
      case "quit": app.quit(); break;
      case "clearCache": await coordinator.clearCache(); break;
      case "connect": {
        if (surface !== "settings" && surface !== "flyout") throw new Error("Invalid request");
        const connected = await connections.connect(r.provider, url => shell.openExternal(url), async () => {
          if (r.provider !== "claude") return true;
          const consent = await dialog.showMessageBox(source, { type: "question", title: "Connect Claude Desktop?", message: "Allow MeterUsage to read your Claude allowance?", detail: "MeterUsage will read Claude Desktop's current access token through macOS Keychain and request account allowance from Anthropic. It will not read chats, use refresh tokens or change Claude Desktop. This connection depends on an interface that can change.", buttons: ["Cancel", "Allow access"], defaultId: 0, cancelId: 0, noLink: true });
          return consent.response === 1;
        });
        if (!connected) break;
        await coordinator.refresh(); break;
      }
      case "connectionCancel":
        if (surface !== "settings" && surface !== "flyout") throw new Error("Invalid request");
        connections.cancel(r.provider); break;
      case "disconnect":
        if (surface !== "settings" && surface !== "flyout") throw new Error("Invalid request");
        await connections.disconnect(r.provider);
        await coordinator.refresh(); break;
      case "copyDiagnostics": clipboard.writeText(coordinator.diagnostics()); break;
      case "copyJSON": clipboard.writeText(coordinator.json()); break;
      case "setPreference":
        if (r.key === "launchAtLogin") {
          if (launch.demo || launch.candidate || !app.isPackaged) throw new Error("Login items require an installed app");
          app.setLoginItemSettings({ openAtLogin: r.value === true });
          if (app.getLoginItemSettings().openAtLogin !== r.value) throw new Error("Could not change login item");
        }
        await prefs.set(r.key, r.value);
        if (r.key === "onboardingCompleted" && r.value === true && surface === "settings" && !quitting && !source.isDestroyed()) { source.hide(); showFlyout(); }
        if (r.key === "panelSize") sizeFlyout();
        if (r.key === "refreshIntervalSeconds") coordinator.restartTimer();
        if (r.key === "sideNotchPanelPinned") { notch.expanded = r.value === true || folding.hovered; folding.changed(); }
        nativeTheme.themeSource = prefs.values.appearanceTheme as "system" | "dark" | "light";
        if (r.key === "updateCheckEnabled") { if (r.value) void updater.checkIfDue(); else updater.reset(); }
        syncNotch(); coordinator.publish(); if (r.key.startsWith("showProvider")) await coordinator.refresh(); break;
      case "accountAdd": {
        if (surface !== "settings") throw new Error("Open Settings to add an account");
        const chosen = await dialog.showOpenDialog(source, { title: `Choose ${r.provider === "codex" ? "Codex" : "Claude"} config directory`, properties: ["openDirectory"] });
        if (chosen.canceled || !chosen.filePaths[0]) break;
        await prefs.updateAccounts(accounts => [...accounts, { id: randomUUID(), provider: r.provider, label: "", path: chosen.filePaths[0], enabled: true }]);
        coordinator.sources = sources(); await coordinator.refresh(); break;
      }
      case "accountPath": {
        const account = prefs.accounts.find(a => a.id === r.id);
        if (surface !== "settings" || !account) throw new Error("Unknown account");
        const chosen = await dialog.showOpenDialog(source, { title: `Choose ${account.provider === "codex" ? "Codex" : "Claude"} config directory`, properties: ["openDirectory"] });
        if (chosen.canceled || !chosen.filePaths[0]) break;
        await prefs.updateAccounts(accounts => accounts.map(a => a.id === r.id ? { ...a, path: chosen.filePaths[0] } : a));
        coordinator.sources = sources(); await coordinator.refresh(); break;
      }
      case "accountUpdate": case "accountRemove": {
        if (surface !== "settings" || !prefs.accounts.some(a => a.id === r.id)) throw new Error("Unknown account");
        await prefs.updateAccounts(accounts => r.action === "accountRemove" ? accounts.filter(a => a.id !== r.id) : accounts.map(a => a.id === r.id ? { ...a, ...(r.label === undefined ? {} : { label: r.label }), ...(r.enabled === undefined ? {} : { enabled: r.enabled }) } : a));
        coordinator.sources = sources(); await coordinator.refresh(); break;
      }
      case "reset": {
        if (confirmingReset) throw new Error("Reset confirmation already open");
        const intent = coordinator.prepareReset(r.key, r.creditID);
        confirmingReset = true; folding.cancel();
        try {
          const confirmation = await dialog.showMessageBox(source, { type: "warning", title: "Use Codex reset?", message: `Use ${intent.title} for ${intent.account}?`, detail: "This uses one earned reset credit and cannot be undone.", buttons: ["Cancel", "Use reset"], defaultId: 0, cancelId: 0, noLink: true });
          if (confirmation.response === 1) await coordinator.confirmReset(intent.token); else coordinator.cancelReset(intent.token);
        } finally { confirmingReset = false; coordinator.cancelReset(intent.token); folding.changed(); }
        break;
      }
      case "notchSelect":
        if (notch.dragging) break;
        if (!coordinator.snapshot().notchSlots.some(s => slotKey(s) === r.key)) throw new Error("Unknown account");
        notch.selected = r.key; notch.expanded = true; placeNotch(); break;
      case "notchHover":
        if (surface !== "notch" || notch.dragging) break;
        folding.hovered = r.hovering;
        if (r.hovering) { notch.expanded = true; placeNotch(); }
        folding.changed();
        break;
      case "notchContext":
        if (surface !== "notch") throw new Error("Invalid request");
        Menu.buildFromTemplate([{ label: "Keep open", type: "checkbox", checked: prefs.values.sideNotchPanelPinned === true, click: () => { void handle({ action: "setPreference", key: "sideNotchPanelPinned", value: prefs.values.sideNotchPanelPinned !== true }, source, surface); } }, { label: "Refresh now", click: () => { void coordinator.refresh(); } }, { type: "separator" }, { label: "Hide panel", click: () => { void handle({ action: "setPreference", key: "sideNotchPanelEnabled", value: false }, source, surface); } }]).popup({ window: source });
        break;
      case "resize":
        if (surface === "notch") { notchHeight = Math.min(2000, Math.ceil(r.height)); placeNotch(); }
        else if (surface === "tray" && r.width !== undefined) { trayWidth = Math.ceil(r.width); source.setSize(trayWidth, 22, false); }
        else if (surface === "flyout") { flyoutHeight = r.height / panelScale(); sizeFlyout(); }
        break;
      case "shareResize":
        if (surface !== "share" || !shareReady) throw new Error("Invalid request");
        try { const size = minimumShareSize(cardWidth, r.height, 2); shareHeight = size.height; source.setSize(size.width, size.height, false); }
        catch (e) { shareFailed?.(new Error(e instanceof Error && e.message === "Card too tall to share" ? e.message : "Could not share snapshot")); }
        break;
      case "dragStart": if (surface === "notch") startDrag(); break;
      case "dragEnd": if (surface === "notch") finishDrag(); break;
      case "share": {
        if (surface !== "notch" || !notch.expanded || sharing) throw new Error("Open a provider card to share");
        sharing = true;
        try {
          // Render the same card at 2x zoom in an isolated hidden window.
          // Upsampling a 1x screen capture would not preserve sharp text.
          shareState = shareSnapshot(state(), r.key); shareHeight = 0;
          const image = await new Promise<Electron.NativeImage>((resolve, reject) => {
            const timer = setTimeout(() => shareFailed?.(new Error("Share render timed out")), 5000);
            shareReady = image => { clearTimeout(timer); shareReady = undefined; shareFailed = undefined; resolve(image); };
            shareFailed = error => { clearTimeout(timer); shareReady = undefined; shareFailed = undefined; reject(error); };
            create("share");
          });
          windows.get("share")?.close(); shareState = undefined;
          shareDirectory = mkdtempSync(join(launch.data, "share-")); const path = join(shareDirectory, "MeterUsage.png"); writeFileSync(path, image.toPNG(), { mode: 0o600 });
          sharedDirectories.add(shareDirectory);
          // ShareMenu reports menu dismissal, not completion of the service.
          // Keep its file available until this app session ends.
          shareMenu = new ShareMenu({ filePaths: [path] }); shareMenu.popup({ window: source, callback: () => { sharing = false; folding.changed(); shareMenu = undefined; shareDirectory = undefined; } });
        } catch (e) { shareFailed?.(new Error("Could not share snapshot")); windows.get("share")?.close(); shareState = undefined; shareReady = undefined; sharing = false; folding.changed(); if (shareDirectory) rmSync(shareDirectory, { recursive: true, force: true }); shareDirectory = undefined; throw new Error(e instanceof Error && e.message === "Card too tall to share" ? e.message : "Could not share snapshot"); }
        break;
      }
      case "updateDismiss": await updater.dismiss(); break;
      case "updateInstall": {
        if (launch.demo || launch.candidate || !app.isPackaged || !updater.visible) throw new Error("Update installation unavailable");
        const confirmedRelease = structuredClone(updater.visible);
        const accepted = await dialog.showMessageBox(source, { type: "question", title: "Install MeterUsage update?", message: `Install MeterUsage ${confirmedRelease.version}?`, detail: "The app will quit, verify the downloaded bundle, replace this app and relaunch.", buttons: ["Cancel", "Install update"], defaultId: 0, cancelId: 0 });
        if (accepted.response === 1) { await updater.install(resolve(app.getPath("exe"), "../../.."), confirmedRelease); app.quit(); }
        break;
      }
    }
    publish(); return { ok: true };
  }
  ipcMain.handle(channel, async (event, raw: unknown): Promise<Reply> => {
    if (!trustedSender(event, documents)) return { ok: false, error: "Untrusted renderer" };
    const source = BrowserWindow.fromWebContents(event.sender), surface = [...windows].find(([, w]) => w === source)?.[0];
    if (!source || !surface) return { ok: false, error: "Unknown window" };
    try { return await handle(parseRequest(raw), source, surface); }
    catch (e) { return { ok: false, error: e instanceof Error && ["Invalid request", "Unknown account", "Reset credit unavailable", "Reset confirmation expired", "Couldn't redeem Codex reset", "Login items require an installed app", "Could not change login item", "Could not share snapshot", "Card too tall to share", "Open Codex on this Mac, then try connecting again", "Open Claude Desktop and sign in, then try connecting again", "Could not clear the cancelled Codex connection", "Could not disconnect Codex", "Connections are disabled in demo mode", "Automatic Grok connection is unavailable"].includes(e.message) ? e.message : "Could not complete action" }; }
  });
  const unsubscribe = coordinator.subscribe(() => { syncNotch(); publish(); if (!coordinator.snapshot().refreshing) void updater.checkIfDue(); });
  screen.on("display-metrics-changed", () => { placeNotch(); sizeFlyout(); publish(); }); screen.on("display-removed", () => { placeNotch(); sizeFlyout(); publish(); });
  powerMonitor.on("resume", () => { void coordinator.refresh(); });
  app.on("window-all-closed", () => {});
  const clockTimer = setInterval(publish, 60000);
  nativeTheme.on("updated", publish);
  let quitting = false, quitReady = false;
  app.on("before-quit", event => {
    if (quitReady) return;
    event.preventDefault();
    if (quitting) return;
    quitting = true;
    unsubscribe();
    coordinator.stop(); updater.reset(); clearInterval(clockTimer); if (drag) { clearInterval(drag.timer); clearTimeout(drag.timeout); } folding.cancel();
    void connections.stop().finally(() => {
      if (shareDirectory) rmSync(shareDirectory, { recursive: true, force: true }); for (const directory of sharedDirectories) rmSync(directory, { recursive: true, force: true }); tray.destroy();
      quitReady = true; app.quit();
    });
  });
  nativeTheme.themeSource = prefs.values.appearanceTheme as "system" | "dark" | "light";
  create("tray"); restoreAnchor();
  // Recovery failures remain visible in connection state, with collection disabled.
  await connections.recover().catch(() => {});
  if (quitting) return;
  syncNotch(); await coordinator.start();
  if (!quitting && (launch.candidate || prefs.values.onboardingCompleted !== true)) showUsage();
  if (!quitting) return () => { if (!quitting) showUsage(); };
}
