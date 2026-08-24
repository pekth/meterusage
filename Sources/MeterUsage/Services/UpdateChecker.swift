import Foundation
import Combine
import CryptoKit
import AppKit

/// Checks GitHub Releases for a version newer than the running build, and on
/// the user's click downloads, verifies, and installs it.
///
/// The check is one unauthenticated GET against `api.github.com`, issued at
/// most once every 24 hours and never more often than that no matter how many
/// times the popover opens or the Mac wakes. A failed or rate-limited check is
/// silent by design: an update notice is a courtesy, and a network error must
/// never surface as an error state next to real usage data. No token is sent,
/// no request body exists, and the only thing the request reveals is the
/// caller's IP — the same as any web visit.
///
/// Installation only ever happens on an explicit user click. The archive is
/// downloaded over HTTPS and its SHA-256 must match the digest GitHub
/// publishes alongside the release asset; a missing or mismatched digest
/// aborts the install rather than swapping a bundle of unknown provenance.
///
/// The user can dismiss a banner for a given version; that version then stays
/// dismissed even if later checks keep returning the same release. A genuinely
/// newer release re-arms the banner and fires `onNewRelease` again.
@MainActor
final class UpdateChecker: ObservableObject {

    struct Asset: Equatable {
        let name: String
        let url: URL
        /// GitHub's `sha256:<hex>` digest for the asset, when published.
        let digest: String?
    }

    struct Release: Equatable {
        /// Version without the leading "v" (e.g. "0.2.2"), ready to compare
        /// and display.
        let version: String
        let tagName: String
        let url: URL?
        let assets: [Asset]

        /// The app-bundle zip for this release, named the way
        /// `Scripts/make-app.sh` and the release workflow name them.
        var appZip: Asset? {
            assets.first { $0.name == "MeterUsage-\(version).zip" }
        }
    }

    enum InstallState: Equatable {
        case idle
        case downloading
        case installing
        case failed
    }

    /// The newest release found, if any — including ones the user dismissed.
    /// Views read `visibleRelease`, which applies the dismissal.
    @Published private(set) var available: Release?
    /// Progress of a user-initiated install. `failed` is sticky until the
    /// user retries, so a transient network error never looks like success.
    @Published private(set) var installState: InstallState = .idle

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
            struct AssetPayload: Decodable {
                let name: String
                let browser_download_url: URL
                let digest: String?
            }
            let tag_name: String
            let html_url: String?
            let assets: [AssetPayload]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        let version = normalizedVersion(payload.tag_name)
        guard !version.isEmpty else { throw URLError(.cannotParseResponse) }
        return Release(
            version: version,
            tagName: payload.tag_name,
            url: payload.html_url.flatMap(URL.init(string:)),
            assets: (payload.assets ?? []).map {
                Asset(name: $0.name, url: $0.browser_download_url, digest: $0.digest)
            }
        )
    }

    // MARK: Download, verify, install

    /// Downloads the release's app zip, verifies its SHA-256 against the
    /// digest GitHub published for the asset, unzips it, and returns the
    /// staged `.app`. Every failure throws; the caller maps that to
    /// `.failed` so the user can retry.
    func downloadAndStage(_ release: Release) async throws -> URL {
        guard let zip = release.appZip else {
            throw URLError(.fileDoesNotExist)
        }
        installState = .downloading
        defer { if installState == .downloading { installState = .idle } }

        let (data, response) = try await session.data(for: URLRequest(url: zip.url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        try Self.verifyDigest(data, expected: zip.digest)

        // Stage under a per-version temp directory, so a retry never races a
        // previous attempt's leftovers.
        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterUsageUpdate-\(release.version)", isDirectory: true)
        try? FileManager.default.removeItem(at: stage)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let zipURL = stage.appendingPathComponent(zip.name)
        try data.write(to: zipURL, options: .atomic)
        try await Self.unzip(zipURL, into: stage)
        return stage.appendingPathComponent("MeterUsage.app")
    }

    /// Swaps the staged bundle in over the running one and relaunches.
    ///
    /// A detached helper script does the swap one second after this process
    /// terminates — a running app cannot replace its own bundle, but it can
    /// leave behind a script that does the moment it is gone.
    func install(stagedApp: URL) throws {
        let current = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(
            atPath: current.deletingLastPathComponent().path
        ) else {
            throw URLError(.cannotWriteToFile)
        }
        installState = .installing
        let script = """
        #!/bin/bash
        sleep 1
        rm -rf '\(current.path)'
        cp -R '\(stagedApp.path)' '\(current.path)'
        open '\(current.path)'
        """
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeterUsageUpdateInstall.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// Runs the install end to end: download, verify, stage, swap, relaunch.
    /// Sets `.failed` on any error so the banner offers a retry.
    func downloadAndInstall(_ release: Release) {
        guard installState == .idle || installState == .failed else { return }
        installState = .downloading
        Task { [weak self] in
            guard let self else { return }
            do {
                let staged = try await self.downloadAndStage(release)
                try self.install(stagedApp: staged)
            } catch {
                self.installState = .failed
            }
        }
    }

    /// The archive is only trusted if its SHA-256 matches the digest GitHub
    /// published in the same API response that advertised the release. A
    /// missing digest is treated as a mismatch: no fingerprint, no swap.
    nonisolated static func verifyDigest(_ data: Data, expected: String?) throws {
        guard let expected, expected.hasPrefix("sha256:") else {
            throw URLError(.cannotParseResponse)
        }
        let expectedHex = String(expected.dropFirst("sha256:".count)).lowercased()
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == expectedHex else { throw URLError(.cannotDecodeContentData) }
    }

    nonisolated private static func unzip(_ zipURL: URL, into directory: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, directory.path]
        // ditto writes extraction errors to stderr; capture and drop them —
        // a non-zero exit is the signal, and the stderr could carry paths.
        process.standardError = Pipe()
        try process.run()
        await withCheckedContinuation { continuation in
            process.terminationHandler = { _ in continuation.resume() }
        }
        guard process.terminationStatus == 0 else { throw URLError(.badServerResponse) }
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
