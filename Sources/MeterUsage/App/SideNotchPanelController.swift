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

    /// Fixed card width. Single source: the view frames the card with this
    /// and the controller assumes it when the card is hidden (folded, or
    /// mid-drag), so the side is decided before the card mounts instead of
    /// a beat later — which is what used to shift the strip under the cursor.
    static let cardWidth: CGFloat = 250

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

    /// Which side the hover card docks on. Left of the strip by default;
    /// flips right when the strip sits so far left that the card would leave
    /// the screen and the right side has more room. `stripTopRightX` is the
    /// strip's top-right corner — the persisted anchor, so the strip never
    /// moves under the cursor when the card opens, closes, or flips sides.
    static func cardOnRight(
        stripTopRightX x: CGFloat,
        stripWidth: CGFloat,
        screenFrame: NSRect,
        cardWidth: CGFloat
    ) -> Bool {
        let leftAvail = x - stripWidth - screenFrame.minX
        let rightAvail = screenFrame.maxX - x
        return leftAvail < cardWidth && rightAvail > leftAvail
    }

    /// Window frame for the strip with an optional card docked on either
    /// side, clamped so the whole panel stays inside `screenFrame`. The
    /// strip's top-right corner never moves: toggling or flipping the card
    /// grows the window away from the strip, so readings stay put under the
    /// cursor.
    static func notchFrame(
        stripTopRight: CGPoint,
        totalSize: CGSize,
        stripWidth: CGFloat,
        cardOnRight: Bool,
        screenFrame: NSRect
    ) -> NSRect {
        let w = totalSize.width, h = totalSize.height
        var x = cardOnRight ? stripTopRight.x - stripWidth : stripTopRight.x - w
        var y = stripTopRight.y - h
        x = min(max(x, screenFrame.minX), max(screenFrame.maxX - w, screenFrame.minX))
        y = min(max(y, screenFrame.minY), max(screenFrame.maxY - h, screenFrame.minY))
        return NSRect(x: x, y: y, width: w, height: h)
    }
}

@MainActor
final class SideNotchPanelController: ObservableObject {

    private let panel: NSPanel
    /// Which side the hover card docks on. Flips live as the strip is
    /// dragged across the screen; the view re-renders from this.
    @Published var cardOnRight = false
    /// True from the first drag move to the matching mouse-up. The card hides
    /// while dragging (a slim strip tracks the cursor cleanly) and the side
    /// recomputes on drop — never mid-drag, where a re-frame would fight the
    /// cursor.
    @Published var isDragging = false
    /// Content size last reported by the SwiftUI view; reused when the screen
    /// arrangement changes so the panel can re-place itself without waiting
    /// for a data refresh.
    private var contentSize: CGSize = .zero
    /// Strip size last reported by the view. The window follows the full
    /// content, but the persisted corner and the side math track the strip —
    /// the part that must never move under the cursor.
    private var stripSize: CGSize = .zero
    /// Last size a placement actually applied, quantized to whole points.
    /// Countdown ticks and percent text constantly re-measure a point or two
    /// off; re-placing for those rebuilds tracking areas under the cursor for
    /// no visible change, so sub-point wobble is ignored.
    private var lastPlacedSize: CGSize = .zero
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
    /// that launch frame must never be recorded as a drag.
    private var hasPlaced = false
    private var cancellables = Set<AnyCancellable>()
    /// Global mouse-up monitor ending drags. Stored for life; the controller
    /// lives as long as the app.
    private var mouseUpMonitor: Any?

    init(coordinator: AppCoordinator) {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The notch carries its own black body in every appearance, so it
        // casts no shadow of its own — same call as the reference design.
        panel.hasShadow = false
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
                panel: self,
                onSizeChange: { [weak self, weak panel] size in
                    guard let self, let panel else { return }
                    self.contentSize = size
                    if self.notePlacement(for: size) {
                        self.place(panel: panel, on: panel.screen ?? NSScreen.main)
                    }
                },
                onStripSizeChange: { [weak self, weak panel] size in
                    guard let self, let panel else { return }
                    self.stripSize = size
                    if self.notePlacement(for: self.contentSize) {
                        self.place(panel: panel, on: panel.screen ?? NSScreen.main)
                    }
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
        // are excluded by checking `isPlacing` and requiring an active mouse
        // drag (`pressedMouseButtons != 0`).
        NotificationCenter.default
            .publisher(for: NSWindow.didMoveNotification, object: panel)
            .sink { [weak self] _ in
                guard let self, !self.isPlacing, self.hasPlaced else { return }
                guard NSEvent.pressedMouseButtons != 0 else { return }
                // Persist the strip's top-right corner, not the window's:
                // with the card docked right the window outgrows the strip.
                let stripWidth = self.stripSize.width
                let corner = CGPoint(
                    x: self.cardOnRight && stripWidth > 0
                        ? self.panel.frame.minX + stripWidth
                        : self.panel.frame.maxX,
                    y: self.panel.frame.maxY
                )
                self.userCorner = corner
                UserDefaults.standard.set(
                    SideNotchPanelLayout.cornerString(corner),
                    forKey: PrefKey.sideNotchPanelCorner
                )
                if !self.isDragging { self.isDragging = true }
            }
            .store(in: &cancellables)

        // A drag records its corner per move above but never re-places (that
        // would fight the cursor). The matching mouse-up ends the drag: the
        // side recomputes from the dropped position and the window settles.
        // Global so a drop outside the panel still counts. The callback can
        // arrive off the main thread; placement stays main-bound.
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async { self?.endDrag() }
        }

        // Re-place on display changes (resolution, monitor plug/unplug) so the
        // strip follows its screen instead of stranding on a dead one.
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

    deinit {
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
        }
    }

    /// Ends a drag on mouse-up: clears the flag (the view drops any stale
    /// hover with it) and settles the window, recomputing the card side from
    /// the dropped position. Cheap no-op for ordinary clicks.
    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        guard panel.isVisible else { return }
        place(panel: panel, on: panel.screen ?? NSScreen.main)
    }

    /// Records a measured size and reports whether a placement is owed.
    /// Screen changes place directly and bypass this; drags never place
    /// (re-framing mid-drag would fight the cursor).
    private func notePlacement(for size: CGSize) -> Bool {
        let quantized = CGSize(width: size.width.rounded(), height: size.height.rounded())
        guard quantized != lastPlacedSize else { return false }
        lastPlacedSize = quantized
        return true
    }

    private func place(panel: NSPanel, on screen: NSScreen?) {
        guard let screen, contentSize.width > 0, contentSize.height > 0 else { return }
        // The persisted corner is the strip's top-right, so the strip never
        // moves under the cursor when the card opens, closes, or flips sides.
        let stripTopRight: CGPoint
        let screenFrame: NSRect
        if let userCorner {
            // `visibleFrame` excludes the menu bar and Dock, so a parked
            // strip never hides behind either.
            stripTopRight = userCorner
            screenFrame = screen.visibleFrame
        } else {
            // Notchless Macs report a zero top safe-area inset even though the
            // menu bar is there, so fall back to its usual height.
            let topInset = screen.safeAreaInsets.top > 0 ? screen.safeAreaInsets.top : 25
            stripTopRight = CGPoint(
                x: screen.frame.maxX - SideNotchPanelLayout.rightInset,
                y: screen.frame.maxY - topInset
            )
            screenFrame = screen.frame
        }
        // Assume the known card width while it is hidden (folded strip, or
        // mid-drag with the card suppressed): the side must be decided
        // before the card mounts, or the strip shifts under the cursor when
        // it flips a beat later.
        let measuredCard = contentSize.width - stripSize.width
        let cardWidth: CGFloat
        if stripSize.width > 0, measuredCard > 0 {
            cardWidth = measuredCard
        } else {
            cardWidth = SideNotchPanelLayout.cardWidth
        }
        let onRight = SideNotchPanelLayout.cardOnRight(
            stripTopRightX: stripTopRight.x,
            stripWidth: stripSize.width,
            screenFrame: screenFrame,
            cardWidth: cardWidth
        )
        if onRight != cardOnRight { cardOnRight = onRight }
        let frame = SideNotchPanelLayout.notchFrame(
            stripTopRight: stripTopRight,
            totalSize: contentSize,
            stripWidth: stripSize.width,
            cardOnRight: onRight,
            screenFrame: screenFrame
        )
        isPlacing = true
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        DispatchQueue.main.async { [weak self] in
            self?.isPlacing = false
        }
        hasPlaced = true
    }
}
