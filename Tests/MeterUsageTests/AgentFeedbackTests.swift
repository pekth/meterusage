import AppKit
import XCTest
@testable import MeterUsage

final class AgentFeedbackTests: XCTestCase {
    let example = Data(#"{"description":"Synthetic external link does not open","steps":"Select the example external link","expected":"The browser opens","actual":"Nothing happens"}"#.utf8)

    func testDraftRejectsUnsafeAndUnboundedInput() throws {
        let draft = try AgentFeedback.decode(example, requiresID: false)
        XCTAssertEqual(draft.description, "Synthetic external link does not open")
        XCTAssertEqual(draft.id.uuidString.split(separator: "-")[2].first, "4")
        for bad in ["/Users/example/private", "person@example.com", "Bearer example-secret", "https://example.com/private", "\u{202e}hidden", String(repeating: "a", count: 513)] {
            let input = try JSONSerialization.data(withJSONObject: ["description": bad, "steps": "Select link", "expected": "Open", "actual": "Nothing"])
            XCTAssertThrowsError(try AgentFeedback.decode(input, requiresID: false))
        }
        XCTAssertThrowsError(try AgentFeedback.decode(Data(repeating: 65, count: 8193), requiresID: false))
        XCTAssertThrowsError(try AgentFeedback.decode(Data(#"{"confirmed":true}"#.utf8), requiresID: false))
        XCTAssertThrowsError(try AgentFeedback.decode(example, requiresID: true))
    }

    @MainActor
    func testNativeReviewAndClientReceipt() async throws {
        let report = AgentFeedback.report(try AgentFeedback.decode(example, requiresID: false))
        let endpoint = URL(string: "https://reports.example.com/report")!
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FeedbackProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        FeedbackProtocol.bodies = []
        FeedbackProtocol.mismatch = false
        func review(click title: String) -> (String, String?) -> Bool {
            { preview, failure in
                let timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { _ in
                    guard let window = NSApplication.shared.modalWindow else {
                        XCTFail("Native review window did not open")
                        NSApplication.shared.abortModal()
                        return
                    }
                    func descendants(_ view: NSView) -> [NSView] {
                        [view] + view.subviews.flatMap(descendants)
                    }
                    let views = descendants(window.contentView!)
                    XCTAssertTrue(views.compactMap { $0 as? NSTextView }.contains { $0.string == preview && !$0.isEditable })
                    XCTAssertTrue(preview.contains(report.diagnostics))
                    XCTAssertTrue(preview.contains(endpoint.absoluteString))
                    let button = views.compactMap { $0 as? NSButton }.first { $0.title == title }
                    XCTAssertNotNil(button)
                    if title != "Cancel" { XCTAssertEqual(button?.keyEquivalent, "") }
                    button?.performClick(nil)
                }
                RunLoop.main.add(timer, forMode: .modalPanel)
                return AgentFeedback.review(preview, failure: failure)
            }
        }
        let declined = await AgentFeedback.submit(report, endpoint: endpoint, review: review(click: "Cancel"), send: {
            try await IssueReportClient.send($0, endpoint: endpoint, session: session)
        })
        XCTAssertEqual(declined.status, "declined")
        XCTAssertTrue(FeedbackProtocol.bodies.isEmpty)
        let sent = await AgentFeedback.submit(report, endpoint: endpoint, review: review(click: "Send this report"), send: {
            try await IssueReportClient.send($0, endpoint: endpoint, session: session)
        })
        XCTAssertEqual(sent.status, "sent")
        XCTAssertEqual(sent.identifier, "PB-123")
        XCTAssertEqual(FeedbackProtocol.bodies.count, 1)
        FeedbackProtocol.mismatch = true
        var approvals = 0
        let uncertain = await AgentFeedback.submit(report, endpoint: endpoint, review: { _, _ in
            approvals += 1
            return approvals == 1
        }, send: { try await IssueReportClient.send($0, endpoint: endpoint, session: session) })
        XCTAssertEqual(uncertain.status, "unconfirmed")
        XCTAssertNil(uncertain.identifier)
        XCTAssertEqual(FeedbackProtocol.bodies[0], FeedbackProtocol.bodies[1])
    }

    @MainActor
    func testPreviewDeclineAndExactConsentRetry() async throws {
        let draft = try AgentFeedback.decode(example, requiresID: false)
        let report = AgentFeedback.report(draft)
        let endpoint = URL(string: "https://reports.example.com/report")!
        var sends = 0
        var previews = [String]()
        let declined = await AgentFeedback.submit(report, endpoint: endpoint, review: { preview, _ in
            previews.append(preview)
            return false
        }, send: { _ in sends += 1; return "PB-123" })
        XCTAssertEqual(declined.status, "declined")
        XCTAssertEqual(sends, 0)
        XCTAssertTrue(previews[0].contains(report.diagnostics))
        XCTAssertTrue(previews[0].contains(endpoint.absoluteString))
        var bodies = [Data]()
        let sent = await AgentFeedback.submit(report, endpoint: endpoint, review: { preview, failure in
            XCTAssertEqual(preview, previews[0])
            if sends == 1 { XCTAssertEqual(failure, IssueReportClient.Failure.unconfirmed.errorDescription) }
            return true
        }, send: { value in
            bodies.append(try XCTUnwrap(IssueReportClient.request(for: value, endpoint: endpoint).httpBody))
            sends += 1
            if sends == 1 { throw NSError(domain: "private credential", code: 1) }
            return "PB-123"
        })
        XCTAssertEqual(sent.status, "sent")
        XCTAssertEqual(sent.identifier, "PB-123")
        XCTAssertEqual(bodies.count, 2)
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(sent.id, draft.id)
    }
}

private final class FeedbackProtocol: URLProtocol {
    static var bodies = [Data]()
    static var mismatch = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                body.append(contentsOf: buffer.prefix(n))
            }
        }
        Self.bodies.append(body)
        let object = try! JSONSerialization.jsonObject(with: body) as! [String: Any]
        let receipt = try! JSONSerialization.data(withJSONObject: ["id": Self.mismatch ? UUID().uuidString : object["id"]!, "identifier": "PB-123"])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: receipt)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
