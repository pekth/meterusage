import AppKit
import Combine
import SwiftUI

// MARK: - Side notch panel
//
// An opt-in floating strip of usage rings pinned to the right edge of the
// screen, just below the menu bar — the "side notch" surface. Hovering expands
// a detail card beside the strip with per-window bars and reset times.
//
// Deliberately *not* anchored to the display notch: the strip hugs the screen's
// right edge, so it behaves identically on notched and notch-less Macs and
// never depends on safe-area geometry.
//
// The strip can be dragged anywhere. Until the user drags it, placement stays
// at the default right-edge anchor; a drag records the window's top-right
// corner, which is then restored across launches and screen changes. The
// corner (not the origin) is what persists, so expanding keeps growing
// leftward from wherever the user parked the strip.
//
// The window is a borderless, non-activating `NSPanel` that joins every space
// (including fullscreen) and floats at the status-bar level. It accepts mouse
// events only on itself, so clicks pass through everywhere else.

/// Pure placement math for the side notch panel.
///
/// Kept free of any screen lookup so tests can assert the geometry without a
/// display: the frame hugs the right edge of `screenFrame`, its top edge sits
/// `topInset` points below the menu bar, and its top-right corner is fixed so
/// the expansion grows leftward and downward while the strip stays put.
enum SideNotchPanelLayout {

    /// Fixed gap between the strip and the screen's right edge.
    static let rightInset: CGFloat = 4

    static func frame(
        contentSize: CGSize,
        screenFrame: NSRect,
        rightInset: CGFloat = SideNotchPanelLayout.rightInset,
        topInset: CGFloat
    ) -> NSRect {
        NSRect(
            x: screenFrame.maxX - contentSize.width - rightInset,
            y: screenFrame.maxY - topInset - contentSize.height,
            width: contentSize.width,
            height: contentSize.height
        )
    }

    // MARK: Dragged position

    /// Frame whose top-right corner is `corner`, clamped so the whole panel
    /// stays inside `screenFrame` — a strip dragged to a screen's edge must
    /// survive that screen disappearing or changing resolution.
    static func frame(corner: CGPoint, contentSize: CGSize, screenFrame: NSRect) -> NSRect {
        let maxX = min(corner.x, screenFrame.maxX - rightInset)
        let maxY = min(corner.y, screenFrame.maxY)
        return NSRect(
            x: max(maxX - contentSize.width, screenFrame.minX),
            y: max(maxY - contentSize.height, screenFrame.minY),
            width: contentSize.width,
            height: contentSize.height
        )
    }

    /// The corner persists as a compact "x,y" string — debuggable in
    /// `defaults`, and cheap to parse defensively.
    static func cornerString(_ corner: CGPoint) -> String {
        "\(corner.x),\(corner.y)"
    }

    /// Parses a stored corner. Any malformed or partial value means "no saved
    /// position" and falls back to the default anchor rather than a wrong one.
    static func restoredCorner(_ stored: String?) -> CGPoint? {
        guard let stored else { return nil }
        let parts = stored.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
    }
}

@MainActor
final class SideNotchPanelController {

    private let panel: NSPanel
    /// Content size last reported by the SwiftUI view; reused when the screen
    /// arrangement changes so the panel can re-place itself without waiting
    /// for a data refresh.
    private var contentSize: CGSize = .zero
    /// Top-right corner recorded from the user's last drag. `nil` until the
    /// first drag, which is when the default right-edge anchor still applies.
    private var userCorner: CGPoint?
    /// True while a programmatic placement is in flight, so the move observer
    /// below can tell our own `setFrame` calls from a real drag. Without it,
    /// an expansion resize would be recorded as a "drag" and freeze the
    /// position even though the user never moved anything.
    private var isPlacing = false
    /// True once the first programmatic placement has run. AppKit resizes a
    /// borderless panel by itself when its content view first lays out, and
    /// that launch frame must never be recorded as a drag. After the first
    /// placement, every move that is not one of ours is a user drag — note
    /// that `NSApp.currentEvent` cannot be the discriminator: during AppKit's
    /// own background-drag session it does not reliably report a
    /// `leftMouseDragged` event, and a guard on it silently rejected every
    /// real drag.
    private var hasPlaced = false
    private var cancellables = Set<AnyCancellable>()

    init(coordinator: AppCoordinator) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // Drag anywhere on the strip or the expanded card. The content is
        // plain shapes, so nothing on it needs to claim a mouse-down.
        panel.isMovableByWindowBackground = true
        // A floating surface must not vanish when the user focuses another app.
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false
        self.panel = panel

        userCorner = SideNotchPanelLayout.restoredCorner(
            UserDefaults.standard.string(forKey: PrefKey.sideNotchPanelCorner)
        )

        let host = NSHostingView(
            rootView: SideNotchPanelView(
                coordinator: coordinator,
                onSizeChange: { [weak self, weak panel] size in
                    guard let self, let panel else { return }
                    self.contentSize = size
                    self.place(panel: panel, on: panel.screen ?? NSScreen.main)
                }
            )
        )
        // NSWindow positions and resizes its contentView to track the panel's
        // frame by itself; no constraints are wanted here. (Constraining the
        // contentView to itself pins nothing and leaves its layout ambiguous,
        // which misaligned the expanded card inside the panel.)
        panel.contentView = host

        // Every user-initiated move records the corner so it survives
        // relaunches, screen changes, and expansion. Programmatic placements
        // are excluded by the `isPlacing` window around our own `setFrame`
        // calls, and the one-time launch auto-fit by `hasPlaced`.
        NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, !self.isPlacing, self.hasPlaced else { return }
                let corner = CGPoint(x: self.panel.frame.maxX, y: self.panel.frame.maxY)
                self.userCorner = corner
                UserDefaults.standard.set(
                    SideNotchPanelLayout.cornerString(corner),
                    forKey: PrefKey.sideNotchPanelCorner
                )
            }
            .store(in: &cancellables)

        // Re-place on display changes (resolution, monitor plug/unplug) so the
        // strip stays pinned to the right edge of the current main screen.
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                guard let self, self.panel.isVisible else { return }
                self.place(panel: self.panel, on: NSScreen.main)
            }
            .store(in: &cancellables)
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func place(panel: NSPanel, on screen: NSScreen?) {
        guard let screen, contentSize.width > 0, contentSize.height > 0 else { return }
        let frame: NSRect
        if let userCorner {
            // Keep the corner the user dragged to. `visibleFrame` excludes the
            // menu bar and Dock, so a parked strip never hides behind either.
            frame = SideNotchPanelLayout.frame(
                corner: userCorner,
                contentSize: contentSize,
                screenFrame: screen.visibleFrame
            )
        } else {
            // Notchless Macs report a zero top safe-area inset even though the
            // menu bar is there, so fall back to its usual height.
            let topInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 25
            frame = SideNotchPanelLayout.frame(
                contentSize: contentSize,
                screenFrame: screen.frame,
                topInset: topInset
            )
        }
        isPlacing = true
        panel.setFrame(frame, display: false)
        isPlacing = false
        hasPlaced = true
    }
}
