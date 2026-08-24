import AppKit
import SwiftUI

// MARK: - Per-widget display options
//
// Static widgets cannot host items in the system's right-click menu, so
// clicking a provider widget opens this panel instead (via the
// meterusage://widget/<provider> URL). Choices are stored per provider in
// UserDefaults and reach the widget through the snapshot's widget_options.

@MainActor
final class WidgetOptionsWindowController {
    static let shared = WidgetOptionsWindowController()

    private var window: NSWindow?
    weak var coordinator: AppCoordinator?

    func show(providerRaw: String) {
        let displayName = Provider(rawValue: providerRaw)?.displayName ?? providerRaw
        let key = "widgetAllWindows.\(providerRaw)"

        if let window {
            window.title = "\(displayName) widget display"
            window.contentView = NSHostingView(rootView: WidgetOptionsView(
                displayName: displayName,
                initialAllWindows: UserDefaults.standard.object(forKey: key) as? Bool ?? false,
                onChange: { [weak self] value in
                    UserDefaults.standard.set(value, forKey: key)
                    self?.coordinator?.refresh()
                }))
            window.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 120),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.title = "\(displayName) widget display"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WidgetOptionsView(
            displayName: displayName,
            initialAllWindows: UserDefaults.standard.object(forKey: key) as? Bool ?? false,
            onChange: { [weak self] value in
                UserDefaults.standard.set(value, forKey: key)
                self?.coordinator?.refresh()
            }))
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct WidgetOptionsView: View {
    let displayName: String
    @State var allWindows: Bool
    let onChange: (Bool) -> Void

    init(displayName: String, initialAllWindows: Bool, onChange: @escaping (Bool) -> Void) {
        self.displayName = displayName
        self._allWindows = State(initialValue: initialAllWindows)
        self.onChange = onChange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: Binding(
                get: { allWindows },
                set: { allWindows = $0; onChange($0) }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Show all windows (medium)")
                        .font(.system(size: 12, weight: .medium))
                    Text("Off: current and weekly only.")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .toggleStyle(.switch)
            Text("Applies to every \(displayName) widget within a refresh cycle.")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
