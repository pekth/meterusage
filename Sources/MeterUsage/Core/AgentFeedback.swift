import AppKit

/// Agent input is a short bug draft, never a diagnostic payload or a consent token.
enum AgentFeedback {
    static let maximumInputBytes = 8192

    struct Draft: Codable {
        let id: UUID
        let description: String
        let steps: String
        let expected: String
        let actual: String
    }

    struct Result: Encodable {
        let id: UUID
        let status: String
        let identifier: String?
        let error: String?
    }

    enum Failure: Error, LocalizedError {
        case invalidInput, invalidCommand
        var errorDescription: String? {
            switch self {
            case .invalidInput:
                return "Use only id, description, steps, expected and actual. Keep each field concise and remove paths, links, account data and credentials."
            case .invalidCommand:
                return "Use meterusage report draft or meterusage report submit with bounded JSON on stdin. Submission requires native user review; there is no confirmation flag."
            }
        }
    }

    static func decode(_ data: Data, requiresID: Bool) throws -> Draft {
        guard data.count <= maximumInputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["description", "steps", "expected", "actual"] + (requiresID ? ["id"] : []))
        else { throw Failure.invalidInput }
        var fields = [String]()
        for key in ["description", "steps", "expected", "actual"] {
            guard let value = object[key] as? String,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.utf8.count <= (key == "description" ? 512 : 2048),
                  !value.unicodeScalars.contains(where: {
                      ($0.properties.generalCategory == .control && $0 != "\n") ||
                      $0.properties.generalCategory == .format
                  }),
                  value.range(of: #"(?i)([/\\~]|@|https?:|bearer\s|api[_ -]?key|password|token\s*[:=]|\b(?:sk|ghp|ghs)_[a-z0-9]|[a-z0-9_-]{40,})"#,
                              options: .regularExpression) == nil
            else { throw Failure.invalidInput }
            fields.append(value)
        }
        let id: UUID
        if requiresID {
            guard let raw = object["id"] as? String, let parsed = UUID(uuidString: raw),
                  raw.lowercased().range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil
            else { throw Failure.invalidInput }
            id = parsed
        } else { id = UUID() }
        return Draft(id: id, description: fields[0], steps: fields[1], expected: fields[2], actual: fields[3])
    }

    static func report(_ draft: Draft) -> IssueReportClient.Report {
        let diagnostics = DiagnosticsReport.build(
            appName: AppInfo.name, appVersion: AppInfo.version, isDemoMode: false,
            refreshInterval: 0, lastRefreshedAt: nil, now: Date(), enabledSlots: [],
            quotas: [:], activities: [:], usages: [:], statuses: [:], plans: [:])
        return .init(id: draft.id, diagnostics: "Description:\n\(draft.description)\n\nSteps:\n\(draft.steps)\n\nExpected:\n\(draft.expected)\n\nActual:\n\(draft.actual)\n\nCLI snapshot: provider and history state not observed; no sources polled.\n\(diagnostics)")
    }

    @MainActor
    static func submit(_ report: IssueReportClient.Report, endpoint: URL?,
                       review: (String, String?) -> Bool,
                       send: (IssueReportClient.Report) async throws -> String) async -> Result {
        do { _ = try IssueReportClient.request(for: report, endpoint: endpoint) }
        catch {
            return Result(id: report.id, status: "unavailable", identifier: nil,
                          error: (error as? IssueReportClient.Failure)?.errorDescription)
        }
        let preview = "Destination: MeterUsage support, private Linear project\nRelay: \(endpoint!.absoluteString)\nReport ID: \(report.id.uuidString)\n\n\(report.diagnostics)"
        var failure: String?
        while review(preview, failure) {
            do {
                let identifier = try await send(report)
                return Result(id: report.id, status: "sent", identifier: identifier, error: nil)
            } catch {
                failure = (error as? IssueReportClient.Failure)?.errorDescription
                    ?? IssueReportClient.Failure.unconfirmed.errorDescription
            }
        }
        return Result(id: report.id, status: failure == nil ? "declined" : "unconfirmed",
                      identifier: nil, error: failure)
    }

    @MainActor
    static func review(_ preview: String, failure: String?) -> Bool {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Review agent bug report"
        alert.informativeText = (failure.map { "\($0)\nRetry uses the same ID and report.\n\n" } ?? "") +
            "Read the full report below. Remove private or account data before sending. Send approves this exact report once."
        alert.addButton(withTitle: "Cancel")
        let send = alert.addButton(withTitle: failure == nil ? "Send this report" : "Retry this report")
        send.keyEquivalent = ""
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 580, height: 340))
        scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isRichText = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.string = preview
        text.setAccessibilityLabel("Exact report and destination")
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        alert.accessoryView = scroll
        return alert.runModal() == .alertSecondButtonReturn
    }

    @MainActor
    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard arguments.count == 3, ["draft", "submit"].contains(arguments[2]) else { throw Failure.invalidCommand }
            var data = Data()
            while data.count <= maximumInputBytes {
                let chunk = try FileHandle.standardInput.read(upToCount: maximumInputBytes + 1 - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            let draft = try decode(data, requiresID: arguments[2] == "submit")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if arguments[2] == "draft" {
                FileHandle.standardOutput.write(try encoder.encode(draft))
            } else {
                let session = IssueReportClient.session()
                defer { session.invalidateAndCancel() }
                let result = await submit(report(draft), endpoint: IssueReportClient.endpoint,
                                          review: review, send: {
                    try await IssueReportClient.send($0, endpoint: IssueReportClient.endpoint, session: session)
                })
                FileHandle.standardOutput.write(try encoder.encode(result))
                FileHandle.standardOutput.write(Data("\n".utf8))
                return ["sent", "declined"].contains(result.status) ? 0 : 1
            }
            FileHandle.standardOutput.write(Data("\n".utf8))
            return 0
        } catch {
            let message = (error as? Failure)?.errorDescription ?? "Could not read or encode the bug draft."
            FileHandle.standardError.write(Data("meterusage: \(message)\n".utf8))
            return 1
        }
    }
}
