import Foundation

/// A bounded, allowlisted summary of app state. No source is polled here.
enum DiagnosticsReport {
    static let maximumSlots = 12
    static let maximumWindows = 8
    static let maximumOutcomes = 24

    enum Architecture: String {
        case arm64, x86_64, unknown
        static var current: Self {
            #if arch(arm64)
            return .arm64
            #elseif arch(x86_64)
            return .x86_64
            #else
            return .unknown
            #endif
        }
    }

    enum Presence: String { case present, notDirectory, notObserved, unknown, notUsed }
    enum Stage: String { case quota, activity, usage, status, plan }

    struct FileObservation {
        enum Role: String { case sessions, quotaCandidate }
        enum Kind: String { case missing, file, directory, other, unreadable }
        let role: Role
        let kind: Kind
        let readable: Bool
        let bytes: Int64?
        let modifiedAt: Date?

        static func inspect(_ url: URL, role: Role, fileManager: FileManager = .default) -> Self {
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                let type = attributes[.type] as? FileAttributeType
                return Self(role: role, kind: type == .typeDirectory ? .directory : (type == .typeRegular ? .file : .other),
                            readable: fileManager.isReadableFile(atPath: url.path),
                            bytes: (attributes[.size] as? NSNumber)?.int64Value,
                            modifiedAt: attributes[.modificationDate] as? Date)
            } catch {
                let error = error as NSError
                let missing = error.domain == NSCocoaErrorDomain && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError)
                return Self(role: role, kind: missing ? .missing : .unreadable,
                            readable: false, bytes: nil, modifiedAt: nil)
            }
        }
    }

    struct SlotState {
        let slot: ProviderSlot
        /// A mounted source, not proof of authentication or local data.
        let configured: Bool?
        let enabled: Bool
        let visible: Bool
    }

    struct SafeError {
        enum Domain: String { case url, cocoa, posix, processExit }
        let domain: Domain
        let code: Int

        init?(error: Error) {
            if let transport = error as? JSONRPCTransportError,
               case let .processExited(status, _) = transport {
                domain = .processExit
                code = Int(status)
                return
            }
            let value = error as NSError
            switch value.domain {
            case NSURLErrorDomain: domain = .url
            case NSCocoaErrorDomain: domain = .cocoa
            case NSPOSIXErrorDomain: domain = .posix
            default: return nil
            }
            code = value.code
        }
    }

    struct RefreshOutcome {
        let slot: ProviderSlot
        let stage: Stage
        let finishedAt: Date
        let duration: TimeInterval
        let unavailable: SourceUnavailable?
        let error: SafeError?
    }

    /// Defaults keep existing Copy diagnostics callers and synthetic fixtures valid.
    static func build(
        appName: String,
        appVersion: String,
        isDemoMode: Bool,
        refreshInterval: TimeInterval,
        lastRefreshedAt: Date?,
        now: Date,
        enabledSlots: [ProviderSlot],
        quotas: [ProviderSlot: Loaded<ProviderQuota>],
        activities: [ProviderSlot: Loaded<LocalActivity>],
        usages: [ProviderSlot: Loaded<ProviderUsage>],
        statuses: [Provider: Loaded<ServiceStatus>],
        plans: [ProviderSlot: Loaded<PlanTier>],
        historyError: DurableHistoryStoreError? = nil,
        appBuild: String? = nil,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
        architecture: Architecture = .current,
        slotStates: [SlotState]? = nil,
        isRefreshing: Bool = false,
        cacheDirectory: Presence = .unknown,
        archivedQuotas: [ProviderSlot: ProviderQuota] = [:],
        recentOutcomes: [RefreshOutcome] = [],
        sourceFiles: [ProviderSlot: [FileObservation]] = [:],
        codexCLIAvailable: [ProviderSlot: Bool] = [:]
    ) -> String {
        // App identity accepts only the product name and numeric version components.
        var lines = ["MeterUsage \(version(appVersion))", "diagnostics schema: 2",
                     "app build: \(version(appBuild))",
                     "os version: \(max(0, osVersion.majorVersion)).\(max(0, osVersion.minorVersion)).\(max(0, osVersion.patchVersion))",
                     "architecture: \(architecture.rawValue)",
                     isDemoMode ? "mode: demo" : "mode: live",
                     "refresh interval: \(number(refreshInterval))s",
                     "refresh in progress: \(isRefreshing)",
                     "last refresh: \(lastRefreshedAt.map { age($0, now: now) } ?? "never")"]
        let states = slotStates ?? enabledSlots.map {
            SlotState(slot: $0, configured: nil, enabled: true, visible: true)
        }
        // Additional accounts use report-local ordinals, never persisted IDs or labels.
        var ordinals: [Provider: Int] = [:]
        var names: [ProviderSlot: String] = [:]
        for state in states {
            let slot = state.slot
            if names[slot] != nil { continue }
            if slot.isPrimary {
                names[slot] = slot.provider.rawValue
            } else {
                ordinals[slot.provider, default: 1] += 1
                names[slot] = "\(slot.provider.rawValue)#\(ordinals[slot.provider]!)"
            }
        }
        let shown = Array(states.prefix(maximumSlots))
        lines.append("enabled: \(shown.filter(\.enabled).compactMap { names[$0.slot] }.sorted().joined(separator: ", "))")
        lines.append("slots: \(states.count); omitted slots: \(max(0, states.count - shown.count))")
        lines.append("cache directory: \(cacheDirectory.rawValue) (metadata only)")
        lines.append("history: \(isDemoMode ? "not used (demo)" : historyError?.rawValue ?? "no recorded persistence error")")
        lines.append("archived quota slots: \(archivedQuotas.count) (validity not observed)")
        lines.append("omitted observations: CLI version and source paths; cache contents and history validity; credentials and authentication probes; raw logs and error text; discarded reset-race quota results; account, model, project and window labels; identifiers")
        lines.append("")

        for state in shown {
            let slot = state.slot
            lines.append("[\(names[slot]!)]")
            lines.append("  source configured: \(state.configured.map { String($0) } ?? "unknown"); enabled: \(state.enabled); visible: \(state.visible)")
            if slot.provider == .codex {
                line(&lines, "CLI executable discoverable", codexCLIAvailable[slot].map(String.init) ?? "unknown")
            }
            for (index, file) in (sourceFiles[slot] ?? []).enumerated() {
                line(&lines, "source \(index + 1) \(file.role.rawValue)", "\(file.kind.rawValue); readable=\(file.readable); bytes=\(file.bytes.map(String.init) ?? "unknown"); modified age=\(file.modifiedAt.map { age($0, now: now) } ?? "unknown")")
            }
            line(&lines, "quota", describe(quotas[slot]))
            if let quota = quotas[slot]?.value {
                line(&lines, "quota age", age(quota.capturedAt, now: now))
                let windows = Array(quota.windows.prefix(maximumWindows))
                line(&lines, "windows", "\(quota.windows.count); omitted windows: \(quota.windows.count - windows.count)")
                for (index, window) in windows.enumerated() {
                    line(&lines, "window \(index + 1)", "used percent=\(number(window.usedPercent)); duration minutes=\(window.windowDurationMins.map(String.init) ?? "unknown"); reset in seconds=\(number(window.resetsAt?.timeIntervalSince(now)))")
                }
                line(&lines, "quota groups", "\(quota.groups.count); omitted groups: \(max(0, quota.groups.count - maximumWindows))")
                for (groupIndex, group) in quota.groups.prefix(maximumWindows).enumerated() {
                    line(&lines, "group \(groupIndex + 1) omitted windows", String(max(0, group.windows.count - maximumWindows)))
                    for (index, window) in group.windows.prefix(maximumWindows).enumerated() {
                        line(&lines, "group \(groupIndex + 1) window \(index + 1)", "used percent=\(number(window.usedPercent)); duration minutes=\(window.windowDurationMins.map(String.init) ?? "unknown"); reset in seconds=\(number(window.resetsAt?.timeIntervalSince(now)))")
                    }
                }
                if quota.resetCreditCount != nil || !quota.resetCredits.isEmpty {
                    line(&lines, "reset credits", String(quota.resetCreditCount ?? quota.resetCredits.count))
                }
                if let credits = quota.credits {
                    let unit = credits.unit == .credits ? "credits" : "dollars"
                    line(&lines, "balance", "\(number(credits.balance)) \(unit); unlimited=\(credits.unlimited); used dollars=\(number(credits.usedDollars)); limit dollars=\(number(credits.limitDollars))")
                }
            }
            if let archived = archivedQuotas[slot] {
                line(&lines, "archived quota age", age(archived.capturedAt, now: now))
            }
            line(&lines, "activity", describe(activities[slot]))
            if let activity = activities[slot]?.value {
                line(&lines, "activity age", age(activity.scannedAt, now: now))
                line(&lines, "activity aggregates", "sessions=\(activity.sessions.count); daily buckets=\(activity.daily.count); messages=\(sum(activity.sessions.map(\.messageCount)))")
                line(&lines, "activity session tokens", tokens(activity.sessions.map(\.tokens)))
                line(&lines, "activity daily tokens", tokens(activity.daily.map(\.tokens)))
            }
            line(&lines, "local source availability", localAvailability(activity: activities[slot], usage: usages[slot]))
            line(&lines, "usage", describe(usages[slot]))
            if let usage = usages[slot]?.value {
                line(&lines, "usage age", age(usage.capturedAt, now: now))
                line(&lines, "usage aggregates", "sessions=\(usage.sessionCount); messages=\(usage.messageCount); today sessions=\(usage.todaySessionCount); today messages=\(usage.todayMessageCount)")
                line(&lines, "usage tokens", usage.tokens.map { tokens([$0]) } ?? "unknown")
                line(&lines, "today tokens", usage.todayTokens.map { tokens([$0]) } ?? "unknown")
                line(&lines, "week tokens", usage.weekTokens.map { tokens([$0]) } ?? "unknown")
                line(&lines, "estimated cost USD", number(usage.estimatedCostUSD))
                line(&lines, "omitted usage windows", usage.usageWindows.map { String(max(0, $0.count - maximumWindows)) } ?? "unknown")
                for (index, window) in (usage.usageWindows ?? []).prefix(maximumWindows).enumerated() {
                    line(&lines, "usage window \(index + 1)", "sessions=\(window.sessionCount); messages=\(window.messageCount); \(tokens([window.tokens])); estimated cost USD=\(number(window.estimatedCostUSD))")
                }
            }
            line(&lines, "status", describe(statuses[slot.provider]))
            if let status = statuses[slot.provider]?.value {
                line(&lines, "status severity", String(status.severity.rawValue))
                line(&lines, "status age", age(status.checkedAt, now: now))
            }
            line(&lines, "plan", describe(plans[slot]))
            lines.append("")
        }

        let outcomes = recentOutcomes.suffix(maximumOutcomes)
        var omitted = recentOutcomes.count - outcomes.count
        lines.append("recent refresh outcomes: \(outcomes.count) (completion order, memory only)")
        for outcome in outcomes {
            guard let name = names[outcome.slot], shown.contains(where: { $0.slot == outcome.slot }) else {
                omitted += 1
                continue
            }
            let error = outcome.error.map { "\($0.domain.rawValue) code=\($0.code)" } ?? "not captured"
            lines.append("  \(name) \(outcome.stage.rawValue): \(outcome.unavailable.map(category) ?? "ok"); age=\(age(outcome.finishedAt, now: now)); duration seconds=\(number(outcome.duration)); error=\(error)")
        }
        lines.append("omitted refresh outcomes: \(omitted); earlier outcomes are not retained")
        return lines.joined(separator: "\n")
    }

    private static func version(_ value: String?) -> String {
        guard let value, !value.isEmpty, value.utf8.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }),
              value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty }) else { return "unknown" }
        return value
    }

    private static func number(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        guard value.isFinite, abs(value) <= 1e15 else { return "invalid" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func age(_ date: Date, now: Date) -> String {
        "\(number(now.timeIntervalSince(date)))s ago"
    }

    private static func sum(_ values: [Int]) -> String {
        var total = 0
        for value in values {
            guard value >= 0 else { return "invalid" }
            let result = total.addingReportingOverflow(value)
            guard !result.overflow else { return "invalid" }
            total = result.partialValue
        }
        return String(total)
    }

    private static func tokens(_ values: [TokenTotals]) -> String {
        "input=\(sum(values.map(\.input))); output=\(sum(values.map(\.output))); reasoning=\(sum(values.map(\.reasoning))); cache read=\(sum(values.map(\.cacheRead))); cache write=\(sum(values.map(\.cacheWrite)))"
    }

    private static func localAvailability(activity: Loaded<LocalActivity>?, usage: Loaded<ProviderUsage>?) -> String {
        if activity?.value != nil { return "activity source returned data" }
        if case .missing(.dataNotFound)? = activity { return "activity source dataNotFound" }
        // Usage may be remote (OpenRouter), so success does not prove a local store.
        if case .missing(.dataNotFound)? = usage { return "usage source dataNotFound" }
        return "unknown (no direct probe)"
    }

    private static func line(_ lines: inout [String], _ label: String, _ description: String) {
        lines.append("  \(label): \(description)")
    }

    private static func describe<T>(_ state: Loaded<T>?) -> String {
        switch state {
        case .idle?, nil: return "not checked yet"
        case .value?: return "ok"
        case .missing(let reason)?: return "unavailable (\(category(reason)))"
        }
    }

    private static func category(_ reason: SourceUnavailable) -> String {
        switch reason {
        case .cliNotFound: return "cliNotFound"
        case .notSignedIn: return "notSignedIn"
        case .offline: return "offline"
        case .failed: return "failed"
        case .noData: return "noData"
        case .dataNotFound: return "dataNotFound"
        }
    }
}
