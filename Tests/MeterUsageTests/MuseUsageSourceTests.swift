import AppKit
import SwiftUI
import XCTest
@testable import MeterUsage

final class MuseUsageSourceTests: XCTestCase {
    private func record(_ sequence: Int, at date: Date, kind: String,
                        event: String, extra: [String: Any] = [:]) throws -> Data {
        var fields = extra
        fields["kind"] = event
        return try JSONSerialization.data(withJSONObject: [
            "schema_version": 1, "record_type": "event", "sequence": sequence,
            "recorded_at": date.timeIntervalSince1970 * 1_000_000,
            "payload_type": "runtime.session",
            "payload": ["kind": kind, "event": fields]
        ])
    }

    private func log(at date: Date) throws -> Data {
        let user = try record(1, at: date, kind: "run", event: "started", extra: [
            "prompt": ["private": "ignored"], "workspace_root": "/Users/testuser/example"
        ])
        let assistant = try record(2, at: date, kind: "run",
                                   event: "assistant_message_committed", extra: ["text": ["ignored"]])
        let task = try record(3, at: date, kind: "task", event: "started")
        let lines = [user, assistant, assistant, task, Data("{\"truncated\":".utf8)]
        return lines.reduce(into: Data()) { result, line in
            if !result.isEmpty { result.append(0x0A) }
            result.append(line)
        }
    }

    func testNativeLogCountsOnlyUserAndAssistantMessages() throws {
        let now = Date(timeIntervalSince1970: 1_791_072_000)
        let summary = try XCTUnwrap(MuseUsageSource.parse(data: log(at: now)))
        XCTAssertEqual(summary.messages, 2)
        XCTAssertEqual(summary.updatedAt, now)
    }

    func testUnterminatedLastRecordIsRead() throws {
        let data = try record(1, at: Date(), kind: "run", event: "started")
        XCTAssertEqual(MuseUsageSource.parse(data: data)?.messages, 1)
    }

    func testUnsupportedAndEmptyLogsAreNotReportedAsZeroUsage() {
        XCTAssertNil(MuseUsageSource.parse(data: Data()))
        XCTAssertNil(MuseUsageSource.parse(data: Data("{\"schema_version\":2}".utf8)))
        XCTAssertNil(MuseUsageSource.parse(data: Data("{\"children\":[]}".utf8)))
    }

    func testMissingHistoryDoesNotCreateFiles() async throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await MuseUsageSource(sessionsDirectory: missing).fetchUsage()
            XCTFail("missing history must stay unavailable")
        } catch let error as SourceUnavailable {
            XCTAssertEqual(error, .dataNotFound("Muse local history"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testDiscoveryAndDayCountsUseNativeSessionLogsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3_600)
        for (name, date) in [("today", now.addingTimeInterval(-600)),
                             ("yesterday", now.addingTimeInterval(-86_400))] {
            let directory = root.appendingPathComponent("2026/10/03/\(name)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try log(at: date).write(to: directory.appendingPathComponent("session.jsonl"))
            try log(at: date).write(to: directory.appendingPathComponent("run.jsonl"))
        }
        let usage = try MuseUsageSource.readUsage(in: root, now: now)
        XCTAssertEqual(usage.provider, .muse)
        XCTAssertEqual(usage.sessionCount, 2)
        XCTAssertEqual(usage.messageCount, 4)
        XCTAssertEqual(usage.todaySessionCount, 1)
        XCTAssertEqual(usage.todayMessageCount, 2)
        XCTAssertEqual(usage.capturedAt, now.addingTimeInterval(-600))
        XCTAssertNil(usage.tokens)
        XCTAssertNil(usage.estimatedCostUSD)
        XCTAssertNil(usage.usageWindows)
    }

    func testEmptyHistoryIsUnavailable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try MuseUsageSource.readUsage(in: root, now: Date())) { error in
            XCTAssertEqual(error as? SourceUnavailable, .noData)
        }
    }

    @MainActor
    func testMuseOptInPersistsAndRoutesToUsageCard() async throws {
        let suite = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(Preferences(defaults: defaults).isEnabled(.muse))
        defaults.set(true, forKey: PrefKey.showMuse)
        defaults.set(false, forKey: PrefKey.menuBarMuse)
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.isEnabled(.muse))
        XCTAssertFalse(preferences.showsInMenuBar(.muse))

        let coordinator = AppCoordinator(preferences: preferences, isDemoMode: true,
                                         usageSources: [DemoMuseUsageSource()])
        let refreshed = expectation(description: "Muse usage published")
        coordinator.didPublishSnapshot = { _ in refreshed.fulfill() }
        coordinator.refresh()
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(coordinator.visibleUsageProviders, [.muse])
        XCTAssertTrue(coordinator.visibleQuotaSlots.isEmpty)
        XCTAssertEqual(coordinator.usages[.muse]?.value?.messageCount, 78)
        XCTAssertNil(coordinator.usages[.muse]?.value?.tokens)
        XCTAssertNil(coordinator.quotas[.muse]?.value)
    }

    func testCompositionIncludesMuseWithoutFabricatedQuota() {
        XCTAssertTrue(Composition.usageSources().contains { $0.provider == .muse })
        XCTAssertFalse(Composition.quotaSources().contains { $0.provider == .muse })
        XCTAssertNil(Provider.muse.statusPageURL)
        XCTAssertNotNil(NSImage(systemSymbolName: ProviderMark.symbol(for: .muse), accessibilityDescription: nil))
    }

    @MainActor
    func testMuseUsageCardRendersWithSyntheticData() async throws {
        let usage = try await DemoMuseUsageSource().fetchUsage()
        let renderer = ImageRenderer(content: ProviderUsageSection(
            usages: [.muse: .value(usage)], providers: [.muse], now: Date()
        ).padding().frame(width: 360).environment(\.colorScheme, .dark))
        let image = try XCTUnwrap(renderer.nsImage)
        XCTAssertEqual(image.size.width, 360)
        XCTAssertGreaterThan(image.size.height, 50)
        if let path = ProcessInfo.processInfo.environment["METERUSAGE_MUSE_CAPTURE"],
           let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
