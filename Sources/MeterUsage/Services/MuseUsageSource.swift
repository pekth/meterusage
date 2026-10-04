import Foundation

/// Counts sessions and user/assistant messages from Muse Code's native logs.
/// The decoder declares no prompts, message text, paths, or credentials.
public struct MuseUsageSource: UsageSource {
    public let provider: Provider = .muse
    private let sessionsDirectory: URL

    public init(sessionsDirectory: URL? = nil) {
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"]
            .flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? HomeDirectory.real.appendingPathComponent(".local/share", isDirectory: true)
        self.sessionsDirectory = sessionsDirectory
            ?? dataHome.appendingPathComponent("muse/sessions", isDirectory: true)
    }

    public func fetchUsage() async throws -> ProviderUsage {
        try Self.readUsage(in: sessionsDirectory, now: Date())
    }

    static func readUsage(in directory: URL, now: Date) throws -> ProviderUsage {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            throw SourceUnavailable.dataNotFound("Muse local history")
        }
        guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles]) else {
            throw SourceUnavailable.failed(.muse)
        }

        var sessions: [Summary] = []
        for case let url as URL in files where url.lastPathComponent == "session.jsonl" {
            let data: Data
            do {
                data = try Data(contentsOf: url, options: .mappedIfSafe)
            } catch {
                throw SourceUnavailable.failed(.muse)
            }
            if let summary = parse(data: data) { sessions.append(summary) }
        }
        guard !sessions.isEmpty else { throw SourceUnavailable.noData }

        let today = Calendar.current.startOfDay(for: now)
        let todaySessions = sessions.filter { $0.updatedAt >= today && $0.updatedAt <= now }
        return ProviderUsage(
            provider: .muse,
            sessionCount: sessions.count,
            messageCount: sessions.reduce(0) { $0 + $1.messages },
            todaySessionCount: todaySessions.count,
            todayMessageCount: todaySessions.reduce(0) { $0 + $1.messages },
            capturedAt: sessions.map(\.updatedAt).max() ?? now
        )
    }

    struct Summary {
        let updatedAt: Date
        let messages: Int
    }

    static func parse(data: Data) -> Summary? {
        let decoder = JSONDecoder()
        var sequences = Set<Int>()
        var updatedAt: Date?
        var messages = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { start = end < data.endIndex ? data.index(after: end) : end }
            guard let record = try? decoder.decode(Record.self, from: data[start..<end]),
                  record.schema_version == 1, record.record_type == "event",
                  let sequence = record.sequence, sequences.insert(sequence).inserted,
                  let stamp = record.recorded_at, stamp > 0,
                  let type = record.payload_type,
                  type == "runtime.session" || type == "runtime.session.metadata" else { continue }
            let date = Date(timeIntervalSince1970: stamp / 1_000_000)
            updatedAt = max(updatedAt ?? date, date)
            guard type == "runtime.session", record.payload?.kind == "run" else { continue }
            switch record.payload?.event?.kind {
            case "started", "assistant_message_committed": messages += 1
            default: break
            }
        }
        return updatedAt.map { Summary(updatedAt: $0, messages: messages) }
    }

    // Muse 1.4 native record envelopes. Undeclared content is skipped by Decodable.
    private struct Record: Decodable {
        let schema_version: Int?
        let record_type: String?
        let sequence: Int?
        let recorded_at: Double?
        let payload_type: String?
        let payload: Payload?
    }

    private struct Payload: Decodable {
        let kind: String?
        let event: Event?
    }

    private struct Event: Decodable {
        let kind: String?
    }
}
