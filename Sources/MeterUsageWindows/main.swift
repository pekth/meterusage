// meterusage-windows: Win32 system-tray shell for Windows 10 and Windows 11.
//
// A hidden window owns the tray icon. MeterUsageCore owns data loading and
// refresh scheduling. This shell translates current core state into a tooltip
// and a native context menu.

#if os(Windows)
import Foundation
import MeterUsageCore
import WinSDK

private let trayCallbackMessage: UINT = WM_APP + 1
private let trayIconID: UINT = 1
private let trayRenderTimerID: UINT_PTR = 1

/// Win32 calls this function outside Swift actor isolation. It performs only
/// synchronous Win32 dispatch here. UI work enters the main actor without
/// capturing the non-Sendable HWND supplied by Windows.
private let meterUsageWindowProcedure: WNDPROC = { window, message, wParam, lParam in
    switch message {
    case trayCallbackMessage:
        let mouseMessage = UINT(truncatingIfNeeded: lParam)
        if mouseMessage == WM_LBUTTONUP ||
            mouseMessage == WM_RBUTTONUP ||
            mouseMessage == WM_CONTEXTMENU {
            Task { @MainActor in MeterUsageWindowsApp.showMenu() }
            return 0
        }

    case WM_TIMER:
        if UINT_PTR(truncatingIfNeeded: wParam) == trayRenderTimerID {
            Task { @MainActor in MeterUsageWindowsApp.updateTooltip() }
            return 0
        }

    case WM_CLOSE:
        Task { @MainActor in MeterUsageWindowsApp.quit() }
        return 0

    case WM_DESTROY:
        // LoadIconW returns a shared stock icon, so it must not be passed to
        // DestroyIcon. NIM_DELETE releases the tray's copy of that icon.
        if let window {
            removeTrayIcon(for: window)
        }
        PostQuitMessage(0)
        return 0

    default:
        break
    }

    return DefWindowProcW(window, message, wParam, lParam)
}

private func removeTrayIcon(for window: HWND) {
    var iconData = NOTIFYICONDATAW()
    iconData.cbSize = UINT(MemoryLayout<NOTIFYICONDATAW>.size)
    iconData.hWnd = window
    iconData.uID = trayIconID
    _ = Shell_NotifyIconW(NIM_DELETE, &iconData)
}

@MainActor
private enum MeterUsageWindowsApp {
    private static let windowClassName = "MeterUsageTrayWindow"
    private static let windowTitle = "MeterUsage"
    private static let renderIntervalMilliseconds: UINT = 1_000
    private static let messagePollNanoseconds: UInt64 = 16_000_000

    private static var coordinator: AppCoordinator!
    private static var preferences: Preferences!
    private static var window: HWND?
    private static var shouldStop = false

    static func run() async {
        guard let instance = GetModuleHandleW(nil) else { return }
        guard registerWindowClass(instance: instance) else { return }

        guard let createdWindow = createWindow(instance: instance) else {
            unregisterWindowClass(instance: instance)
            return
        }
        window = createdWindow

        guard addTrayIcon(to: createdWindow) else {
            _ = DestroyWindow(createdWindow)
            unregisterWindowClass(instance: instance)
            return
        }

        let storedPreferences = Preferences()
        preferences = storedPreferences
        coordinator = AppCoordinator(
            preferences: storedPreferences,
            isDemoMode: DemoMode.isEnabled(),
            quotaSources: quotaSources(),
            activitySources: activitySources(),
            usageSources: usageSources(),
            statusSources: statusSources(),
            planSources: planSources()
        )

        coordinator.start()
        updateTooltip()
        _ = SetTimer(createdWindow, trayRenderTimerID, renderIntervalMilliseconds, nil)

        await runMessagePump()
        unregisterWindowClass(instance: instance)
    }

    // MARK: Window lifecycle

    private static func registerWindowClass(instance: HINSTANCE) -> Bool {
        windowClassName.withWideCString { className in
            var windowClass = WNDCLASSEXW()
            windowClass.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            windowClass.lpfnWndProc = meterUsageWindowProcedure
            windowClass.hInstance = instance
            windowClass.hIcon = LoadIconW(nil, IDI_APPLICATION)
            windowClass.hIconSm = LoadIconW(nil, IDI_APPLICATION)
            windowClass.hCursor = LoadCursorW(nil, IDC_ARROW)
            windowClass.lpszClassName = className
            return RegisterClassExW(&windowClass) != 0
        }
    }

    private static func createWindow(instance: HINSTANCE) -> HWND? {
        windowClassName.withWideCString { className in
            windowTitle.withWideCString { title in
                CreateWindowExW(
                    0,
                    className,
                    title,
                    0,
                    0,
                    0,
                    0,
                    0,
                    nil,
                    nil,
                    instance,
                    nil
                )
            }
        }
    }

    private static func unregisterWindowClass(instance: HINSTANCE) {
        windowClassName.withWideCString { className in
            _ = UnregisterClassW(className, instance)
        }
    }

    /// GetMessageW blocks the main actor and prevents coordinator refresh tasks
    /// from publishing state. PeekMessageW keeps Win32 responsive and yields
    /// the actor between bounded message sweeps.
    private static func runMessagePump() async {
        var message = MSG()

        while !shouldStop {
            while PeekMessageW(&message, nil, 0, 0, UINT(PM_REMOVE)) != 0 {
                if message.message == WM_QUIT {
                    shouldStop = true
                    break
                }
                _ = TranslateMessage(&message)
                _ = DispatchMessageW(&message)
            }

            guard !shouldStop else { break }
            try? await Task.sleep(nanoseconds: messagePollNanoseconds)
        }
    }

    static func quit() {
        guard let window else {
            shouldStop = true
            return
        }
        _ = KillTimer(window, trayRenderTimerID)
        _ = DestroyWindow(window)
        self.window = nil
    }

    // MARK: Tray icon

    private static func addTrayIcon(to window: HWND) -> Bool {
        guard let stockIcon = LoadIconW(nil, IDI_APPLICATION) else { return false }

        var iconData = NOTIFYICONDATAW()
        iconData.cbSize = UINT(MemoryLayout<NOTIFYICONDATAW>.size)
        iconData.hWnd = window
        iconData.uID = trayIconID
        iconData.uCallbackMessage = trayCallbackMessage
        iconData.uFlags = UINT(NIF_MESSAGE | NIF_ICON | NIF_TIP)
        iconData.hIcon = stockIcon
        writeFixedWideString("MeterUsage - Loading...", to: &iconData.szTip)
        return Shell_NotifyIconW(NIM_ADD, &iconData) != 0
    }

    static func updateTooltip() {
        guard let window, coordinator != nil else { return }

        var lines = ["MeterUsage"]
        if coordinator.isRefreshing {
            lines.append("Refreshing...")
        } else if let mostConstrained = coordinator.mostConstrained {
            let provider = mostConstrained.provider.displayName
            let percent = Fmt.percent(mostConstrained.window.usedPercent)
            lines.append("\(provider): \(percent) used")
        } else if let message = firstUnavailableMessage() {
            lines.append(message)
        } else {
            lines.append("Loading usage...")
        }

        var iconData = NOTIFYICONDATAW()
        iconData.cbSize = UINT(MemoryLayout<NOTIFYICONDATAW>.size)
        iconData.hWnd = window
        iconData.uID = trayIconID
        iconData.uFlags = UINT(NIF_TIP)
        writeFixedWideString(lines.joined(separator: "\r\n"), to: &iconData.szTip)
        _ = Shell_NotifyIconW(NIM_MODIFY, &iconData)
    }

    private static func firstUnavailableMessage() -> String? {
        for provider in coordinator.visibleQuotaProviders {
            if case .missing(let reason)? = coordinator.quotas[provider] {
                return reason.userFacingMessage
            }
        }
        return nil
    }

    // MARK: Context menu

    static func showMenu() {
        guard let window, let menu = CreatePopupMenu(), coordinator != nil else { return }
        defer { _ = DestroyMenu(menu) }

        appendDisabledItem(to: menu, title: "MeterUsage")
        appendSeparator(to: menu)

        if coordinator.isRefreshing {
            appendDisabledItem(to: menu, title: "Refreshing...")
        }
        appendQuotaRows(to: menu)
        appendSeparator(to: menu)

        appendDisabledItem(to: menu, title: "Providers")
        for provider in Provider.allCases {
            let checkedFlag: UINT = preferences.isEnabled(provider) ? UINT(MF_CHECKED) : UINT(MF_UNCHECKED)
            appendItem(
                to: menu,
                flags: UINT(MF_STRING) | checkedFlag,
                command: MenuCommand.id(for: provider),
                title: provider.displayName
            )
        }

        appendSeparator(to: menu)
        let refreshFlags: UINT = coordinator.isRefreshing
            ? UINT(MF_STRING | MF_GRAYED)
            : UINT(MF_STRING)
        appendItem(
            to: menu,
            flags: refreshFlags,
            command: MenuCommand.refresh,
            title: "Refresh"
        )
        appendItem(to: menu, flags: UINT(MF_STRING), command: MenuCommand.quit, title: "Quit")

        var cursor = POINT()
        guard GetCursorPos(&cursor) != 0 else { return }
        _ = SetForegroundWindow(window)
        let selected = TrackPopupMenu(
            menu,
            UINT(TPM_RIGHTBUTTON | TPM_RETURNCMD),
            cursor.x,
            cursor.y,
            0,
            window,
            nil
        )
        _ = PostMessageW(window, WM_NULL, 0, 0)

        handle(command: UINT_PTR(truncatingIfNeeded: selected))
    }

    private static func appendQuotaRows(to menu: HMENU) {
        let providers = coordinator.visibleQuotaProviders
        guard !providers.isEmpty else {
            appendDisabledItem(to: menu, title: "No quota providers enabled")
            return
        }

        for provider in providers {
            let state: Loaded<ProviderQuota> = coordinator.quotas[provider] ?? .idle
            switch state {
            case .idle:
                appendDisabledItem(to: menu, title: "\(provider.displayName): Loading...")

            case .missing(let reason):
                appendDisabledItem(to: menu, title: reason.userFacingMessage)

            case .value(let quota):
                appendQuotaRows(for: quota, to: menu)
            }
        }
    }

    private static func appendQuotaRows(for quota: ProviderQuota, to menu: HMENU) {
        var rowCount = 0

        if quota.groups.isEmpty {
            for quotaWindow in quota.windows {
                appendQuotaWindow(quotaWindow, provider: quota.provider, groupTitle: nil, to: menu)
                rowCount += 1
            }
        } else {
            for group in quota.groups {
                for quotaWindow in group.windows {
                    appendQuotaWindow(quotaWindow, provider: quota.provider, groupTitle: group.title, to: menu)
                    rowCount += 1
                }
            }
        }

        if let credits = quota.credits {
            let value: String
            if credits.unlimited {
                value = "Unlimited"
            } else if !credits.hasCredits {
                value = "None"
            } else {
                switch credits.unit {
                case .credits:
                    value = "\(Fmt.credits(credits.balance)) credits"
                case .dollars:
                    value = Fmt.usd(credits.balance)
                }
            }
            appendDisabledItem(to: menu, title: "\(quota.provider.displayName) credits: \(value)")
            rowCount += 1
        }

        if rowCount == 0 {
            appendDisabledItem(to: menu, title: "\(quota.provider.displayName): No quota data")
        }
    }

    private static func appendQuotaWindow(
        _ quotaWindow: QuotaWindow,
        provider: Provider,
        groupTitle: String?,
        to menu: HMENU
    ) {
        let group = groupTitle.flatMap { $0.isEmpty ? nil : $0 + " " } ?? ""
        var title = "\(provider.displayName) \(group)\(quotaWindow.label): \(Fmt.percent(quotaWindow.usedPercent)) used"
        if let resetsAt = quotaWindow.resetsAt, let remaining = Fmt.timeUntil(resetsAt) {
            title += ", resets in \(remaining)"
        }
        appendDisabledItem(to: menu, title: title)
    }

    private static func handle(command: UINT_PTR) {
        switch command {
        case MenuCommand.refresh:
            coordinator.refresh()
            updateTooltip()

        case MenuCommand.quit:
            quit()

        default:
            guard let provider = MenuCommand.provider(for: command) else { return }
            preferences.setProvider(provider, enabled: !preferences.isEnabled(provider))
            coordinator.preferencesDidChange()
            coordinator.refresh()
            updateTooltip()
        }
    }

    private static func appendDisabledItem(to menu: HMENU, title: String) {
        appendItem(to: menu, flags: UINT(MF_STRING | MF_GRAYED), command: 0, title: title)
    }

    private static func appendSeparator(to menu: HMENU) {
        _ = AppendMenuW(menu, UINT(MF_SEPARATOR), 0, nil)
    }

    private static func appendItem(
        to menu: HMENU,
        flags: UINT,
        command: UINT_PTR,
        title: String
    ) {
        title.withWideCString { wideTitle in
            _ = AppendMenuW(menu, flags, command, wideTitle)
        }
    }

    // MARK: Composition root

    private static func quotaSources() -> [QuotaSource] {
        if DemoMode.isEnabled() {
            return [
                DemoClaudeQuotaSource(),
                DemoCodexQuotaSource(),
                DemoOpenRouterQuotaSource(),
                DemoOpenCodeGoQuotaSource(),
                DemoGrokQuotaSource(),
            ]
        }
        return [
            CodexQuotaSource(),
            OpenRouterQuotaSource(),
            OpenCodeGoQuotaSource(),
            GrokQuotaSource(),
            OptionalQuotaFileSource(),
        ]
    }

    private static func activitySources() -> [LocalActivitySource] {
        DemoMode.isEnabled()
            ? [DemoLocalActivitySource(), DemoCodexActivitySource()]
            : [ClaudeLocalSource(), CodexLocalSource()]
    }

    private static func usageSources() -> [UsageSource] {
        DemoMode.isEnabled() ? [DemoAntigravityUsageSource()] : [AntigravityUsageSource()]
    }

    private static func statusSources() -> [StatusSource] {
        if DemoMode.isEnabled() {
            return [.codex, .claude].map { DemoStatusSource(provider: $0) }
        }
        return [
            StatusPageSource(provider: .codex),
            StatusPageSource(provider: .claude),
        ]
    }

    private static func planSources() -> [PlanSource] {
        DemoMode.isEnabled() ? [DemoPlanSource()] : [ClaudePlanSource()]
    }
}

private enum MenuCommand {
    static let refresh: UINT_PTR = 1
    static let quit: UINT_PTR = 2

    static func id(for provider: Provider) -> UINT_PTR {
        switch provider {
        case .codex: return 101
        case .antigravity: return 102
        case .grok: return 103
        case .openCodeGo: return 104
        case .openRouter: return 105
        case .claude: return 106
        }
    }

    static func provider(for command: UINT_PTR) -> Provider? {
        switch command {
        case 101: return .codex
        case 102: return .antigravity
        case 103: return .grok
        case 104: return .openCodeGo
        case 105: return .openRouter
        case 106: return .claude
        default: return nil
        }
    }
}

private extension String {
    /// Keeps UTF-16 storage alive for the full WinSDK call. Win32 copies these
    /// class, title, and menu strings before the closure returns.
    func withWideCString<Result>(_ body: (UnsafePointer<WCHAR>) -> Result) -> Result {
        let units: [WCHAR] = utf16.map { WCHAR($0) } + [0]
        return units.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}

/// Writes UTF-16 into an imported WinSDK fixed WCHAR tuple without assigning
/// an Array to the tuple or keeping a pointer beyond this call.
private func writeFixedWideString<Field>(_ value: String, to field: inout Field) {
    withUnsafeMutableBytes(of: &field) { rawBuffer in
        for index in rawBuffer.indices {
            rawBuffer[index] = 0
        }

        let target = rawBuffer.bindMemory(to: WCHAR.self)
        guard target.count > 0 else { return }
        var units = Array(value.utf16.prefix(target.count - 1))
        if let last = units.last, (0xD800...0xDBFF).contains(last) {
            units.removeLast()
        }
        for (index, codeUnit) in units.enumerated() {
            target[index] = WCHAR(codeUnit)
        }
    }
}

await MeterUsageWindowsApp.run()
#endif
