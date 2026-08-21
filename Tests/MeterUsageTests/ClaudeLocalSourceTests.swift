import XCTest
@testable import MeterUsageCore

// MARK: - Test helpers

/// Builds a throwaway `~/.claude/projects`-shaped tree under a temp
/// directory so `ClaudeLocalSource` is never pointed at the real home
/// directory in tests.
private final class FixtureTree {
    let base: URL
    let root: URL
    /// A per-test, isolated location for `ClaudeLocalSource`'s persistent
    /// disk cache. Every test must pass this explicitly — the default
    /// (`~/Library/Application Support/MeterUsage/...`) would otherwise
    /// read and write the real machine's cache during `swift test`.
    let cacheFileURL: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("projects", isDirectory: true)
        cacheFileURL = base.appendingPathComponent("scan-cache.json")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Convenience for building a `ClaudeLocalSource` pointed at this tree,
    /// so every call site gets the isolated cache path automatically.
    func makeSource() -> ClaudeLocalSource {
        ClaudeLocalSource(root: root, cacheFileURL: cacheFileURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: base)
    }

    /// Copies the shared sample transcript into `<root>/<projectDirName>/<sessionFileName>.jsonl`.
    @discardableResult
    func addSession(
        projectDirName: String = "-Users-testuser-Developer-samplerepo",
        sessionFileName: String = UUID().uuidString,
        from fixtureName: String = "claude_session_sample"
    ) throws -> URL {
        let projectDir = root.appendingPathComponent(projectDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)

        guard let source = Bundle.module.url(forResource: fixtureName, withExtension: "jsonl", subdirectory: "Fixtures") else {
            XCTFail("missing fixture \(fixtureName).jsonl")
            return projectDir
        }
        let destination = projectDir.appendingPathComponent("\(sessionFileName).jsonl")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// Writes an arbitrary raw line file directly, for malformed-content cases
    /// not covered by the shared fixture.
    func addRawSession(
        projectDirName: String = "-Users-testuser-Developer-samplerepo",
        sessionFileName: String = UUID().uuidString,
        contents: String
    ) throws {
        let projectDir = root.appendingPathComponent(projectDirName, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        let destination = projectDir.appendingPathComponent("\(sessionFileName).jsonl")
        try contents.write(to: destination, atomically: true, encoding: .utf8)
    }
}

private func utcDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: DateComponents(year: y, month: m, day: d))!
}

// MARK: - ClaudeLocalSource

final class ClaudeLocalSourceTests: XCTestCase {

    func testMissingDirectoryThrowsNoData() async {
        let missingRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)", isDirectory: true)
        let cacheFileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-tests-cache-\(UUID().uuidString).json")
        let source = ClaudeLocalSource(root: missingRoot, cacheFileURL: cacheFileURL)

        do {
            _ = try await source.scan()
            XCTFail("expected SourceUnavailable.noData")
        } catch SourceUnavailable.noData {
            // expected
        } catch {
            XCTFail("expected .noData, got \(error)")
        }
    }

    func testEmptyDirectoryThrowsNoData() async throws {
        let tree = FixtureTree()
        let source = tree.makeSource()

        do {
            _ = try await source.scan()
            XCTFail("expected SourceUnavailable.noData")
        } catch SourceUnavailable.noData {
            // expected
        }
    }

    func testSingleSessionAggregation() async throws {
        let tree = FixtureTree()
        try tree.addSession(sessionFileName: "session-one")
        let source = tree.makeSource()

        let activity = try await source.scan()
        XCTAssertEqual(activity.sessions.count, 1)

        let session = activity.sessions[0]
        // The fixture has 4 assistant/usage lines but the last is a
        // deliberately truncated (unterminated) line, so only 3 should
        // parse — proving malformed trailing content doesn't blow up the
        // scan and doesn't get silently counted.
        XCTAssertEqual(session.messageCount, 3)
        XCTAssertEqual(session.tokens.input, 3300)
        XCTAssertEqual(session.tokens.output, 650)
        XCTAssertEqual(session.tokens.cacheRead, 500)
        XCTAssertEqual(session.tokens.cacheWrite, 100)
        // Model of the most recent assistant message in the fixture.
        XCTAssertEqual(session.model, "claude-mystery-9")
        XCTAssertGreaterThan(session.estimatedCostUSD, 0)
    }

    func testMultiSessionAggregation() async throws {
        let tree = FixtureTree()
        try tree.addSession(projectDirName: "-Users-testuser-Developer-repoA", sessionFileName: "session-a")
        try tree.addSession(projectDirName: "-Users-testuser-Developer-repoB", sessionFileName: "session-b")
        let source = tree.makeSource()

        let activity = try await source.scan()
        XCTAssertEqual(activity.sessions.count, 2)

        let totals = activity.totalTokens
        XCTAssertEqual(totals.input, 6600)   // 3300 * 2 sessions
        XCTAssertEqual(totals.output, 1300)  // 650 * 2
        XCTAssertEqual(activity.totalCostUSD, activity.sessions.reduce(0) { $0 + $1.estimatedCostUSD }, accuracy: 0.0001)

        let names = Set(activity.sessions.map(\.projectName))
        XCTAssertEqual(names, ["repoA", "repoB"])
    }

    func testDailyRollupCorrectness() async throws {
        let tree = FixtureTree()
        try tree.addSession(sessionFileName: "session-one")
        let source = tree.makeSource()

        let activity = try await source.scan()
        let byDay = Dictionary(uniqueKeysWithValues: activity.daily.map { ($0.day, $0) })

        // Fixture: two usage lines on 2026-06-01, one on 2026-06-02.
        let day1 = byDay[utcDay(2026, 6, 1)]
        XCTAssertNotNil(day1)
        XCTAssertEqual(day1?.tokens.input, 3000)
        XCTAssertEqual(day1?.tokens.output, 600)
        XCTAssertEqual(day1?.tokens.cacheRead, 500)
        XCTAssertEqual(day1?.tokens.cacheWrite, 100)

        let day2 = byDay[utcDay(2026, 6, 2)]
        XCTAssertNotNil(day2)
        XCTAssertEqual(day2?.tokens.input, 300)
        XCTAssertEqual(day2?.tokens.output, 50)
    }

    func testMalformedAndTruncatedLinesAreSkippedNotFatal() async throws {
        let tree = FixtureTree()
        let garbage = """
        not json at all
        {"type":"assistant","message":{"model":"claude-sonnet-5"}}
        {"type":"assistant","timestamp":"2026-06-03T00:00:00Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        {"type":"assistant","timestamp":"2026-06-03T00:01:00Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,truncated-garbage-not-closed
        """
        try tree.addRawSession(sessionFileName: "garbage-session", contents: garbage)
        let source = tree.makeSource()

        let activity = try await source.scan()
        XCTAssertEqual(activity.sessions.count, 1)
        // Line 1: not JSON -> skipped.
        // Line 2: valid JSON, assistant type, but no "usage" object -> skipped.
        // Line 3: fully valid -> counted.
        // Line 4: truncated JSON -> skipped.
        XCTAssertEqual(activity.sessions[0].messageCount, 1)
        XCTAssertEqual(activity.sessions[0].tokens.input, 10)
    }

    /// Pins the byte-level `containsUsageMarkers` prefilter against a
    /// false NEGATIVE: it must not drop a line it should have counted.
    /// JSON key order isn't guaranteed, and a real transcript line puts
    /// `"usage"` (nested under `message`) before the top-level
    /// `"type":"assistant"` — the opposite order from every other fixture
    /// line in this file, which all happen to have `"type"` first. If the
    /// prefilter secretly depended on order (e.g. an `hasPrefix`/anchored
    /// check instead of a presence check), this line would be silently
    /// skipped and this test would fail.
    func testPrefilterDoesNotDropValidUsageLineWithReversedKeyOrder() async throws {
        let tree = FixtureTree()
        let reversed = """
        {"message":{"usage":{"input_tokens":7,"output_tokens":3,"cache_read_input_tokens":0,"cache_creation_input_tokens":0},"model":"claude-sonnet-5"},"type":"assistant","timestamp":"2026-06-05T00:00:00Z"}
        """
        try tree.addRawSession(sessionFileName: "reversed-order-session", contents: reversed)
        let source = tree.makeSource()

        let activity = try await source.scan()
        XCTAssertEqual(activity.sessions.count, 1)
        XCTAssertEqual(activity.sessions[0].messageCount, 1)
        XCTAssertEqual(activity.sessions[0].tokens.input, 7)
        XCTAssertEqual(activity.sessions[0].tokens.output, 3)
    }

    func testUnknownModelUsesFallbackPricingWithoutCrashing() async throws {
        let tree = FixtureTree()
        try tree.addSession(sessionFileName: "session-one")
        let source = tree.makeSource()

        let activity = try await source.scan()
        let session = activity.sessions[0]
        // Session's dominant model ("claude-mystery-9") is unrecognised;
        // cost must still be computed (via fallback) rather than zeroed.
        XCTAssertTrue(Pricing.rate(forModel: session.model).isFallback)
        XCTAssertGreaterThan(session.estimatedCostUSD, 0)
    }

    func testRescanSkipsUnchangedFilesViaCache() async throws {
        let tree = FixtureTree()
        try tree.addSession(sessionFileName: "session-one")
        let source = tree.makeSource()

        let first = try await source.scan()
        let second = try await source.scan()
        // Re-scanning an unchanged tree must produce identical results
        // (this exercises the mtime-based cache path, not just cold parse).
        XCTAssertEqual(first.sessions.count, second.sessions.count)
        XCTAssertEqual(first.totalTokens, second.totalTokens)
    }

    /// Proves the cache actually round-trips through disk — not just that
    /// the same actor instance remembers its own in-memory state, which
    /// `testRescanSkipsUnchangedFilesViaCache` above already covers. A
    /// *second, brand-new* `ClaudeLocalSource` pointed at the same
    /// `cacheFileURL` must produce identical results by reading the
    /// persisted cache, which is what makes the second app launch fast.
    func testDiskCachePersistsAcrossFreshInstances() async throws {
        let tree = FixtureTree()
        try tree.addSession(sessionFileName: "session-one")

        let first = try await tree.makeSource().scan()
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.cacheFileURL.path), "expected a cache file to be written")

        let second = try await tree.makeSource().scan() // fresh actor instance, same cache file
        XCTAssertEqual(first.sessions.count, second.sessions.count)
        XCTAssertEqual(first.totalTokens, second.totalTokens)
        XCTAssertEqual(first.sessions.first?.model, second.sessions.first?.model)
    }

    /// A corrupt or half-written cache file (partial write, disk error,
    /// format change across app versions) must degrade to a full re-scan,
    /// never throw or produce an empty result.
    func testCorruptDiskCacheFallsBackToFullScanInsteadOfThrowing() async throws {
        let tree = FixtureTree()
        try tree.addSession(sessionFileName: "session-one")
        try "{ this is not valid cache json".write(to: tree.cacheFileURL, atomically: true, encoding: .utf8)

        let activity = try await tree.makeSource().scan()
        XCTAssertEqual(activity.sessions.count, 1)
        XCTAssertEqual(activity.sessions[0].tokens.input, 3300)
    }

    func testNoSessionSummaryLeaksPathOrUsername() async throws {
        let tree = FixtureTree()
        try tree.addSession(
            projectDirName: "-Users-realname-secret-Developer-topsecretrepo",
            sessionFileName: "should-be-opaque"
        )
        let source = tree.makeSource()

        let activity = try await source.scan()
        for session in activity.sessions {
            XCTAssertFalse(session.projectName.contains("/"), "leaked a path separator")
            XCTAssertFalse(session.projectName.contains("Users"), "leaked the home-directory prefix")
            XCTAssertFalse(session.id.contains("/"), "leaked a path separator in id")
            XCTAssertFalse(session.id.contains("Users"), "leaked the home-directory prefix in id")
            XCTAssertFalse(session.id.contains("should-be-opaque"), "raw session id leaked into the model")
        }
    }
}

// MARK: - OptionalQuotaFileSource
//
// Lives in this file rather than a dedicated test file because the task's
// file ownership list only grants ClaudeLocalSourceTests.swift and
// PricingTests.swift under Tests/ — a second top-level XCTestCase here
// covers OptionalQuotaFileSource without creating an unowned file.

final class OptionalQuotaFileSourceTests: XCTestCase {

    private func fixtureURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "optional_quota", withExtension: "json", subdirectory: "Fixtures") else {
            XCTFail("missing optional_quota.json fixture")
            throw SourceUnavailable.noData
        }
        return url
    }

    func testMissingFileThrowsNoData() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-file-\(UUID().uuidString).json")
        let source = OptionalQuotaFileSource(candidatePaths: [missing])

        do {
            _ = try await source.fetchQuota()
            XCTFail("expected SourceUnavailable.noData")
        } catch SourceUnavailable.noData {
            // expected — absence is the normal, everyday case.
        } catch {
            XCTFail("expected .noData, got \(error)")
        }
    }

    /// Writes an arbitrary JSON string to a temp file and returns its URL.
    /// Used for shapes deliberately NOT baked into the shared fixture
    /// (e.g. the spec-only `weekly` array, or an enabled `extra_usage`) so
    /// the fixture itself can stay a faithful mirror of the one real
    /// payload actually observed on disk.
    private func tempQuotaFile(_ json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("meterusage-quota-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("quota.json")
        try json.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// `weekly` is SPEC-driven, not observed — the real file captured
    /// 2026-07-31 has no `weekly` key at all (see the header comment in
    /// OptionalQuotaFileSource.swift). This exercises the precedence logic
    /// via a synthetic payload rather than the fixture, so the fixture can
    /// keep mirroring the real, `weekly`-less shape.
    func testWeeklyArrayTakesPrecedenceOverSevenDay() async throws {
        let file = try tempQuotaFile("""
        {
          "seven_day": { "used_percentage": 24, "resets_at": 1790500000 },
          "weekly": [
            { "label": "Sonnet weekly", "used_percentage": 30, "resets_at": 1790500000 },
            { "label": "Opus weekly", "used_percentage": 5, "resets_at": 1790500000 }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        let labels = quota.windows.map(\.label)
        XCTAssertTrue(labels.contains("Sonnet weekly"))
        XCTAssertTrue(labels.contains("Opus weekly"))
        // The coarse "7-day" window must NOT appear once `weekly` is present.
        XCTAssertFalse(labels.contains("7-day"))
    }

    /// Values in the real file arrive as bare JSON integers (`50`, not
    /// `50.0`). The fixture now mirrors that. This pins `JSONDecoder`
    /// widening an integer literal into the `Double`-typed
    /// `QuotaWindow.usedPercent` — the earlier fixture used float literals
    /// and would have passed even if integer decoding were broken.
    func testFiveHourWindowParsesIntegerLiteralAsDouble() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        let fiveHour = quota.windows.first { $0.label == "5-hour" }
        XCTAssertNotNil(fiveHour)
        XCTAssertEqual(fiveHour?.usedPercent, 61.0)
        XCTAssertNotNil(fiveHour?.resetsAt)
    }

    func testSevenDayAlsoParsesIntegerLiteral() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        let sevenDay = quota.windows.first { $0.label == "7-day" }
        XCTAssertNotNil(sevenDay)
        XCTAssertEqual(sevenDay?.usedPercent, 24.0)
    }

    /// Real-world default: `extra_usage.is_enabled == false` with every
    /// other field `null`. This must decode without throwing AND must
    /// surface as `credits == nil` — not as a `CreditBalance` with a
    /// balance of 0, which would misleadingly read as "verified zero
    /// credits used" rather than "credits not enabled".
    func testDisabledNullExtraUsageProducesNilCreditsNotZero() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        XCTAssertNil(quota.credits)
    }

    /// Enabled shape is spec-driven (not observed in the live file, which
    /// currently has `is_enabled: false`), but the schema documents it and
    /// the cents->dollars conversion needs coverage.
    func testEnabledExtraUsageCentsConvertToDollars() async throws {
        let file = try tempQuotaFile("""
        {
          "extra_usage": {
            "is_enabled": true,
            "used_percentage": 12,
            "used_credits": 250,
            "monthly_limit": 2000
          }
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        // monthly_limit=2000c, used_credits=250c -> 1750c remaining -> $17.50
        let credits = try XCTUnwrap(quota.credits)
        XCTAssertEqual(credits.balance, 17.50, accuracy: 0.0001)
        XCTAssertEqual(credits.hasCredits, true)
        XCTAssertEqual(credits.unlimited, false)
    }

    /// The real file carries an undocumented `gemini` block (and
    /// `updated_at`) alongside the Claude fields. An unknown top-level key
    /// must never fail the parse — `Payload` only declares the keys it
    /// cares about, so `gemini`/`updated_at` are silently ignored while
    /// `five_hour`/`seven_day` still decode correctly.
    func testUnknownTopLevelBlockIsIgnoredWithoutError() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        // Fixture includes a "gemini": {...} block and "updated_at" — if
        // either caused a decode failure this call would have already
        // thrown .noData instead of returning a populated quota.
        XCTAssertFalse(quota.windows.isEmpty)
    }

    func testSecondCandidatePathUsedWhenFirstMissing() async throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("no-such-file-\(UUID().uuidString).json")
        let source = OptionalQuotaFileSource(candidatePaths: [missing, try fixtureURL()])

        let quota = try await source.fetchQuota()
        XCTAssertFalse(quota.windows.isEmpty)
    }

    func testMalformedJSONFileTreatedAsNoData() async throws {
        let badFile = try tempQuotaFile("{ not valid json")
        let source = OptionalQuotaFileSource(candidatePaths: [badFile])
        do {
            _ = try await source.fetchQuota()
            XCTFail("expected SourceUnavailable.noData")
        } catch SourceUnavailable.noData {
            // expected
        }
    }

    // MARK: - Per-model 7-day windows (TASK 1)

    /// The fixture mirrors the real, `seven_day_opus`/`seven_day_sonnet`-less
    /// payload observed on this machine (2026-07-31). Absence of both keys
    /// must produce zero extra windows and no error — this is the everyday
    /// case, not an edge case.
    func testAbsentPerModelSevenDayKeysProduceNoExtraWindows() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        XCTAssertFalse(quota.windows.contains { $0.label.hasPrefix("7-day (") })
        // The coarse window is still there.
        XCTAssertTrue(quota.windows.contains { $0.label == "7-day" })
    }

    /// `seven_day_opus` / `seven_day_sonnet`, when present, are ADDITIVE to
    /// the overall `seven_day` window — not a replacement for it, unlike
    /// `weekly` vs `seven_day`.
    func testPerModelSevenDayWindowsParseAndLabelWhenPresent() async throws {
        let file = try tempQuotaFile("""
        {
          "seven_day": { "used_percentage": 40, "resets_at": 1790500000 },
          "seven_day_opus": { "used_percentage": 15, "resets_at": 1790500000 },
          "seven_day_sonnet": { "used_percentage": 62, "resets_at": 1790500000 }
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        let labels = quota.windows.map(\.label)
        XCTAssertTrue(labels.contains("7-day"))
        XCTAssertTrue(labels.contains("7-day (Opus)"))
        XCTAssertTrue(labels.contains("7-day (Sonnet)"))

        let opus = quota.windows.first { $0.label == "7-day (Opus)" }
        XCTAssertEqual(opus?.usedPercent, 15.0)
        let sonnet = quota.windows.first { $0.label == "7-day (Sonnet)" }
        XCTAssertEqual(sonnet?.usedPercent, 62.0)
    }

    /// One of the two present, the other explicitly `null` — the `null` one
    /// must not produce a window and must not fail the parse.
    func testOnePerModelKeyNullProducesNoWindowForThatModelOnly() async throws {
        let file = try tempQuotaFile("""
        {
          "seven_day_opus": { "used_percentage": 8, "resets_at": 1790500000 },
          "seven_day_sonnet": null
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        let labels = quota.windows.map(\.label)
        XCTAssertTrue(labels.contains("7-day (Opus)"))
        XCTAssertFalse(labels.contains { $0.hasPrefix("7-day (Sonnet") })
    }

    /// SPECULATIVE for this exact key spelling: no `seven_day_fable` key has
    /// been observed. Fable DOES have its own real weekly plan-quota window
    /// (confirmed 2026-07-31 against the Claude app's own usage
    /// usage screenshot plus the raw cached API response — see
    /// OptionalQuotaFileSource.swift's header comment) — it just arrives via
    /// the API's `limits` array / this file's `weekly` array, not via a
    /// `seven_day_fable` sibling key. This test only proves the parser is
    /// forward-compatible via the generic `seven_day_<model>` scan in case
    /// that key spelling is ever added too; it is not a claim that Fable
    /// bills only through `extra_usage` (see the credits tests below, which
    /// cover a real but separate mechanism).
    func testSpeculativeSevenDayFableKeyParsesAndLabelsIfEverPresent() async throws {
        let file = try tempQuotaFile("""
        {
          "seven_day_fable": { "used_percentage": 33, "resets_at": 1790500000 }
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        let fable = quota.windows.first { $0.label == "7-day (Fable)" }
        XCTAssertNotNil(fable)
        XCTAssertEqual(fable?.usedPercent, 33.0)
    }

    /// A `seven_day_*`-shaped key that isn't `{used_percentage, resets_at}`
    /// (e.g. the real `seven_day_overage_included` boolean field) must be
    /// skipped, not treated as a parse failure for the whole file.
    func testMismatchedShapeSevenDayKeyIsSkippedNotFatal() async throws {
        let file = try tempQuotaFile("""
        {
          "seven_day": { "used_percentage": 10, "resets_at": 1790500000 },
          "seven_day_overage_included": true
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertTrue(quota.windows.contains { $0.label == "7-day" })
        XCTAssertFalse(quota.windows.contains { $0.label.hasPrefix("7-day (Overage") })
    }

    // MARK: - Usage credits (TASK 2)

    /// Real-world default (`is_enabled: false`, everything else `null`)
    /// must still yield no `CreditBalance` at all — already pinned by
    /// `testDisabledNullExtraUsageProducesNilCreditsNotZero` above; this
    /// adds the same assertion for the used/limit fields specifically, so a
    /// regression that starts synthesizing a zeroed used/limit pair would
    /// be caught even if `credits` itself were made non-nil by mistake.
    func testDisabledExtraUsageHasNoUsedOrLimitDollars() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        XCTAssertNil(quota.credits?.usedDollars)
        XCTAssertNil(quota.credits?.limitDollars)
    }

    /// Enabled with both values present: cents on the wire convert to
    /// dollars for `usedDollars`/`limitDollars`, which is what the credits
    /// meter in `QuotaSection` renders.
    func testEnabledExtraUsageExposesUsedAndLimitDollars() async throws {
        let file = try tempQuotaFile("""
        {
          "extra_usage": {
            "is_enabled": true,
            "used_percentage": 12,
            "used_credits": 340,
            "monthly_limit": 1500
          }
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        let credits = try XCTUnwrap(quota.credits)
        let usedDollars = try XCTUnwrap(credits.usedDollars)
        let limitDollars = try XCTUnwrap(credits.limitDollars)
        XCTAssertEqual(usedDollars, 3.40, accuracy: 0.0001)
        XCTAssertEqual(limitDollars, 15.00, accuracy: 0.0001)
        XCTAssertEqual(credits.unlimited, false)
    }

    // MARK: - `limits[]` array (writer plumbing)

    /// The canonical writer shape: `session`, `weekly_all`, and
    /// `weekly_scoped` entries, in the order the API returns them. Labels
    /// and order must both come through untouched.
    func testLimitsArrayParsesAllThreeKindsWithCorrectLabels() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 18, "scope": null,
              "resets_at": "2026-08-01T01:00:00.000000+00:00" },
            { "kind": "weekly_all", "group": "weekly", "percent": 44, "scope": null,
              "resets_at": "2026-08-05T00:00:00.000000+00:00" },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 12,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "resets_at": "2026-08-05T00:00:00.000000+00:00" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["5-hour", "Weekly · All models", "Weekly · Fable"])
        XCTAssertEqual(quota.windows[0].usedPercent, 18)
        XCTAssertEqual(quota.windows[1].usedPercent, 44)
        XCTAssertEqual(quota.windows[2].usedPercent, 12)
        for window in quota.windows {
            XCTAssertNotNil(window.resetsAt)
        }
    }

    /// A `weekly_scoped` entry is labelled from `scope.model.display_name`,
    /// not a hardcoded model name — this pins that the label is genuinely
    /// derived, not coincidentally matching a "Fable" special case.
    func testScopedEntryLabelledFromDisplayName() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 7,
              "scope": { "model": { "id": null, "display_name": "Opus" } },
              "resets_at": "2026-08-05T00:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["Weekly · Opus"])
    }

    /// Absence of `limits` must leave the existing five_hour/seven_day
    /// behaviour completely untouched — the fixture has no `limits` key.
    func testAbsentLimitsArrayLeavesExistingBehaviourUntouched() async throws {
        let source = OptionalQuotaFileSource(candidatePaths: [try fixtureURL()])
        let quota = try await source.fetchQuota()

        let labels = quota.windows.map(\.label)
        XCTAssertTrue(labels.contains("5-hour"))
        XCTAssertTrue(labels.contains("7-day"))
    }

    /// `resets_at` in `limits[]` arrives as an ISO-8601 string; the older
    /// `five_hour`/`seven_day` blocks use an integer epoch. Both must
    /// parse to the same moment in time when equivalent.
    func testLimitsResetsAtParsesBothISO8601AndEpoch() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 10, "scope": null,
              "resets_at": "2026-08-01T12:30:00.384213+00:00" },
            { "kind": "weekly_all", "group": "weekly", "percent": 20, "scope": null,
              "resets_at": 1785585600 }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        let session = try XCTUnwrap(quota.windows.first { $0.label == "5-hour" })
        let sessionReset = try XCTUnwrap(session.resetsAt)
        XCTAssertEqual(sessionReset.timeIntervalSince1970, 1785587400.384213, accuracy: 0.01)

        let weeklyAll = try XCTUnwrap(quota.windows.first { $0.label == "Weekly · All models" })
        let weeklyReset = try XCTUnwrap(weeklyAll.resetsAt)
        XCTAssertEqual(weeklyReset.timeIntervalSince1970, 1785585600, accuracy: 0.01)
    }

    /// A malformed entry (not even a JSON object) must be skipped without
    /// failing the parse of the rest of the array.
    func testMalformedLimitsEntryIsSkippedNotFatal() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 15, "scope": null,
              "resets_at": "2026-08-01T00:00:00Z" },
            "this is not an object",
            { "kind": "weekly_all", "group": "weekly", "percent": 33, "scope": null,
              "resets_at": "2026-08-05T00:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["5-hour", "Weekly · All models"])
    }

    /// An unknown `kind` with a `scope.model.display_name` present still
    /// yields a sensible, non-crashing label; one with no display name at
    /// all is skipped rather than inventing a label for it.
    func testUnknownKindDerivesLabelFromDisplayNameOrIsSkipped() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "some_future_kind", "group": "weekly", "percent": 5,
              "scope": { "model": { "id": null, "display_name": "Haiku" } },
              "resets_at": null },
            { "kind": "another_future_kind", "group": null, "percent": 9,
              "scope": null, "resets_at": null }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.count, 1)
        XCTAssertTrue(quota.windows[0].label.contains("Haiku"))
    }

    /// When `limits[]` is present, it takes precedence over the legacy
    /// `five_hour`/`seven_day` keys entirely — both must be absent from
    /// the resulting windows so the user never sees the same window
    /// rendered twice under two different labels.
    func testLimitsArrayTakesPrecedenceOverLegacyKeys() async throws {
        let file = try tempQuotaFile("""
        {
          "five_hour": { "used_percentage": 61, "resets_at": 1790000000 },
          "seven_day": { "used_percentage": 24, "resets_at": 1790500000 },
          "limits": [
            { "kind": "session", "group": "session", "percent": 99, "scope": null,
              "resets_at": "2026-08-01T00:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["5-hour"])
        XCTAssertEqual(quota.windows[0].usedPercent, 99)
    }

    /// Real Anthropic usage-API `limits[]` entries carry extra keys
    /// (`is_active`, `severity`) that the Claude app's usage screen uses.
    /// They must be ignored, not fatal — and `is_active: false` must NOT
    /// hide a window (observed 2026-07-31: Fable at 99% arrives with
    /// `is_active: false` while still shown on the usage screen).
    func testRealWorldLimitsExtraKeysAreIgnoredAndInactiveStillShows() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 24, "scope": null,
              "is_active": false, "severity": "normal",
              "resets_at": "2026-07-31T12:30:00.546474+00:00" },
            { "kind": "weekly_all", "group": "weekly", "percent": 100, "scope": null,
              "is_active": true, "severity": "critical",
              "resets_at": "2026-08-01T12:00:00.546502+00:00" },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 99,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "is_active": false, "severity": "critical",
              "resets_at": "2026-08-01T11:59:59.546832+00:00" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(
            quota.windows.map(\.label),
            ["5-hour", "Weekly · All models", "Weekly · Fable"]
        )
        XCTAssertEqual(quota.windows.map(\.usedPercent), [24, 100, 99])
    }

    /// `QuotaSection`/`WindowRow`/`MeterBar` render from `QuotaWindow` only —
    /// label, usedPercent, fraction, resetsAt. Pin the Fable-scoped window
    /// produces a distinct non-duplicated label and a MeterBar-ready fraction
    /// without needing a SwiftUI host.
    func testFableScopedWindowDrivesDistinctLabelAndMeterFraction() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "weekly_all", "group": "weekly", "percent": 100, "scope": null,
              "resets_at": "2026-08-01T12:00:00Z" },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 99,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "resets_at": "2026-08-01T12:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.count, 2)
        let labels = quota.windows.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "duplicate window labels would double-render rows")
        XCTAssertFalse(labels.contains("7-day"), "legacy coarse label must not appear alongside limits[]")

        let fable = try XCTUnwrap(quota.windows.first { $0.label == "Weekly · Fable" })
        XCTAssertEqual(fable.usedPercent, 99)
        XCTAssertEqual(fable.fraction, 0.99, accuracy: 0.0001)
        XCTAssertNotNil(fable.resetsAt)
    }

    /// `limits[]` is a full replacement: legacy `seven_day_*` model keys must
    /// not be merged in beside it (that would re-introduce the same weekly
    /// allowance under a second label family).
    func testLimitsDoesNotMergeLegacyPerModelSevenDayKeys() async throws {
        let file = try tempQuotaFile("""
        {
          "seven_day_opus": { "used_percentage": 15, "resets_at": 1790500000 },
          "seven_day_sonnet": { "used_percentage": 62, "resets_at": 1790500000 },
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 99,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "resets_at": "2026-08-01T12:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["Weekly · Fable"])
        XCTAssertFalse(quota.windows.contains { $0.label.hasPrefix("7-day") })
    }

    /// Credits (`extra_usage`) stay independent of `limits[]` precedence —
    /// both can surface in one payload so the plan windows and the credits
    /// meter render together without either suppressing the other.
    func testLimitsAndExtraUsageAreOrthogonal() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 12,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "resets_at": "2026-08-05T00:00:00Z" }
          ],
          "extra_usage": {
            "is_enabled": true,
            "used_percentage": 10,
            "used_credits": 100,
            "monthly_limit": 1000
          }
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["Weekly · Fable"])
        let credits = try XCTUnwrap(quota.credits)
        XCTAssertEqual(try XCTUnwrap(credits.usedDollars), 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(credits.limitDollars), 10.0, accuracy: 0.0001)
    }

    /// A `limits[]` array whose every entry decodes cleanly but yields no
    /// displayable window (unknown kinds, no model names) must NOT suppress
    /// the legacy keys. Gating precedence on the raw entry count instead of
    /// the mapped windows would strand the card with zero windows here,
    /// while `five_hour` sat in the same file with perfectly good data.
    func testUndisplayableLimitsEntriesFallBackToLegacyKeys() async throws {
        let file = try tempQuotaFile("""
        {
          "five_hour": { "used_percentage": 61, "resets_at": 1790000000 },
          "seven_day": { "used_percentage": 24, "resets_at": 1790500000 },
          "limits": [
            { "kind": "some_future_kind", "group": null, "percent": 5,
              "scope": null, "resets_at": null },
            { "kind": "another_future_kind", "group": null, "percent": 9,
              "scope": null, "resets_at": null }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["5-hour", "7-day"])
        XCTAssertEqual(quota.windows[0].usedPercent, 61)
    }

    /// An entry with a known `kind` but no `percent` is skipped, never
    /// rendered as 0% — an empty bar is a positive claim of full headroom,
    /// and the truth for that window might be 99%.
    func testLimitsEntryWithNullPercentIsSkippedNotZeroed() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "session", "group": "session", "percent": 15, "scope": null,
              "resets_at": "2026-08-01T00:00:00Z" },
            { "kind": "weekly_all", "group": "weekly", "percent": null, "scope": null,
              "resets_at": "2026-08-05T00:00:00Z" },
            { "kind": "weekly_scoped", "group": "weekly",
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "resets_at": "2026-08-05T00:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(quota.windows.map(\.label), ["5-hour"])
        XCTAssertFalse(quota.windows.contains { $0.usedPercent == 0 })
    }

    /// Render order is imposed locally, not inherited from the payload:
    /// session, then the all-models weekly window, then the per-model
    /// weekly windows (Fable among them) underneath it — even when the
    /// array arrives scrambled. Same-rank entries keep arrival order.
    func testLimitsRenderOrderIsImposedNotInherited() async throws {
        let file = try tempQuotaFile("""
        {
          "limits": [
            { "kind": "weekly_scoped", "group": "weekly", "percent": 99,
              "scope": { "model": { "id": null, "display_name": "Fable" } },
              "resets_at": "2026-08-05T00:00:00Z" },
            { "kind": "some_future_kind", "group": "weekly", "percent": 3,
              "scope": { "model": { "id": null, "display_name": "Haiku" } },
              "resets_at": null },
            { "kind": "weekly_scoped", "group": "weekly", "percent": 40,
              "scope": { "model": { "id": null, "display_name": "Opus" } },
              "resets_at": "2026-08-05T00:00:00Z" },
            { "kind": "weekly_all", "group": "weekly", "percent": 44, "scope": null,
              "resets_at": "2026-08-05T00:00:00Z" },
            { "kind": "session", "group": "session", "percent": 18, "scope": null,
              "resets_at": "2026-08-01T01:00:00Z" }
          ]
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertEqual(
            quota.windows.map(\.label),
            ["5-hour", "Weekly · All models", "Weekly · Fable", "Weekly · Opus", "Weekly · Haiku"]
        )
    }

    /// `is_enabled: true` but the numeric fields are still `null` (a
    /// plausible future partial-rollout shape) must be treated the same as
    /// disabled — no fabricated $0/$0 credits row.
    func testEnabledExtraUsageWithNullValuesProducesNilCredits() async throws {
        let file = try tempQuotaFile("""
        {
          "extra_usage": {
            "is_enabled": true,
            "used_percentage": null,
            "used_credits": null,
            "monthly_limit": null
          }
        }
        """)
        let source = OptionalQuotaFileSource(candidatePaths: [file])
        let quota = try await source.fetchQuota()

        XCTAssertNil(quota.credits)
    }
}
