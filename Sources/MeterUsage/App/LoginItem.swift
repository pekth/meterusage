import MeterUsageCore
import Foundation
#if canImport(ServiceManagement)
import ServiceManagement
#endif

// MARK: - Launch at login (macOS only)
//
// Lives in the macOS app target rather than the core: `SMAppService` has no
// equivalent on Linux or Windows, where autostart is a desktop-environment or
// registry concern handled by each platform shell.

#if os(macOS) && canImport(ServiceManagement)
/// Thin wrapper over `SMAppService`.
///
/// Kept separate from `Preferences` because registration can fail (the user can
/// deny it in System Settings) and the stored toggle must then be corrected to
/// match reality rather than lying about the app's state.
enum LoginItem {

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Returns the state actually achieved, which may differ from `enabled`.
    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration is unavailable when running from a bare binary rather
            // than an installed .app bundle. Nothing to surface beyond the
            // toggle snapping back.
            return isEnabled
        }
        return isEnabled
    }
}
#endif
