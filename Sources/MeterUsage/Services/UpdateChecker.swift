import Foundation
import Combine

/// Checks GitHub Releases for a version newer than the running build.
///
/// The check is one unauthenticated GET against `api.github.com`, issued at
/// most once every 24 hours and never more often than that no matter how many
/// times the popover opens or the Mac wakes. A failed or rate-limited check is
/// silent by design: an update notice is a courtesy, and a network error must
/// never surface as an error state next to real usage data. No token is sent,
/// no request body exists, and the only thing the request reveals is the
/// caller's IP — the same as any web visit.
///
/// The user can dismiss a banner for a given version; that version then stays
/// dismissed even if later checks keep returning the same release. A genuinely
/// newer release re-arms the banner and fires `onNewRelease` again.
@MainActor
final class UpdateChecker: ObservableObject {

    struct Release: Equatable {
        /// Version without the leading "v" (e.g. "0.2.2"), ready to compare
        /// and display.
        let version: String
        let tagName: String
        let url: URL?
    }

    /// The newest release found, if any — including ones the user dismissed.
    /// Views read `visibleRelease`, which applies the dismissal.
    @Published private(set) var available: Release?

    /// Called once per newly discovered version. Fired on first discovery
    /// only: a relaunch that re-finds the same release stays quiet, because
    /// the announced version is persisted.
    var onNewRelease: ((Release) -> Void)?

    private let endpoint: URL
    private let session: URLSession
    private let defaults: UserDefaults
    private var checkTask: Task<Void, Never>?

    /// One check per day. There is no release cadence that justifies more.
    nonisolated static let checkInterval: TimeInterval = 24 * 60 * 60

    init(
        endpoint: URL = URL(string: "https://api.github.com/repos/pekth/meterusage/releases/latest")!,
        session: URLSession = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.endpoint = endpoint
        self.session = session
        self.defaults = defaults
    }

    // MARK: Checking

    /// Runs a check if the daily interval has elapsed. Cheap enough to call
    /// from every refresh sweep; the guard makes it a no-op until due.
    func checkIfDue(now: Date = Date(), interval: TimeInterval = UpdateChecker.checkInterval) {
        guard checkTask == nil else { return }
        if let last = lastCheckDate, now.timeIntervalSince(last) < interval { return }
        lastCheckDate = now
        checkTask = Task { [weak self] in
            await self?.performCheck()
            self?.checkTask = nil
        }
    }

    /// Clears discovered state and abandons any in-flight check. Called when
    /// the user switches update checks off, so a banner already on screen
    /// disappears with the setting instead of lingering until relaunch.
    func reset() {
        checkTask?.cancel()
        checkTask = nil
        available = nil
    }

    private func performCheck() async {
        guard let release = try? await Self.fetch(endpoint: endpoint, session: session) else { return }
        guard Self.isNewer(release.version, than: AppInfo.version) else { return }
        let isNewDiscovery = available?.version != release.version
        available = release
        guard isNewDiscovery else { return }
        // Notify at most once per version, across relaunches.
        guard announcedVersion != release.version else { return }
        announcedVersion = release.version
        onNewRelease?(release)
    }

    /// Fetches and shapes the latest release. Throws on any network or shape
    /// problem; the caller treats every throw as "no news".
    nonisolated static func fetch(endpoint: URL, session: URLSession) async throws -> Release {
        var request = URLRequest(url: endpoint)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("meterusage/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try parse(data: data)
    }

    nonisolated static func parse(data: Data) throws -> Release {
        struct Payload: Decodable {
            let tag_name: String
            let html_url: String?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = normalizedVersion(payload.tag_name)
        guard !version.isEmpty else { throw URLError(.cannotParseResponse) }
        return Release(
            version: version,
            tagName: payload.tag_name,
            url: payload.html_url.flatMap(URL.init(string:))
        )
    }

    // MARK: Version comparison

    /// Strips a leading "v" so both "v0.2.2" and "0.2.2" compare the same.
    nonisolated static func normalizedVersion(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        return value
    }

    /// Numeric component-wise semver comparison: "0.10.0" beats "0.9.9",
    /// missing components count as zero ("1.0" equals "1.0.0"). Anything
    /// non-numeric in a component stops that component's parse at zero, so a
    /// malformed tag can only ever read as *not newer* — an update notice is
    /// never fired on garbage.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = numericComponents(candidate)
        let currentParts = numericComponents(current)
        for index in 0..<max(candidateParts.count, currentParts.count) {
            let c = index < candidateParts.count ? candidateParts[index] : 0
            let cur = index < currentParts.count ? currentParts[index] : 0
            if c != cur { return c > cur }
        }
        return false
    }

    nonisolated private static func numericComponents(_ version: String) -> [Int] {
        normalizedVersion(version)
            .split(separator: ".")
            .map { component in
                let digits = component.prefix(while: \.isNumber)
                return Int(digits) ?? 0
            }
    }

    // MARK: Dismissal

    /// The release the banner should show, or `nil` when there is none or the
    /// user dismissed this version.
    var visibleRelease: Release? {
        guard let available else { return nil }
        guard dismissedVersion != available.version else { return nil }
        return available
    }

    func dismiss() {
        guard let available else { return }
        dismissedVersion = available.version
    }

    // MARK: Persisted state

    /// Test seam: plants a discovered release without touching the network.
    func testOnly_setAvailable(_ release: Release) {
        available = release
    }

    private var lastCheckDate: Date? {
        get { defaults.object(forKey: PrefKey.updateLastCheck) as? Date }
        set { defaults.set(newValue, forKey: PrefKey.updateLastCheck) }
    }

    private var dismissedVersion: String? {
        get { defaults.string(forKey: PrefKey.updateDismissedVersion) }
        set { defaults.set(newValue, forKey: PrefKey.updateDismissedVersion) }
    }

    private var announcedVersion: String? {
        get { defaults.string(forKey: PrefKey.updateAnnouncedVersion) }
        set { defaults.set(newValue, forKey: PrefKey.updateAnnouncedVersion) }
    }
}
