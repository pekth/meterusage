import XCTest
@testable import MeterUsage

final class IssueReportClientTests: XCTestCase {
    func testOversizedResponseStopsLoadingBeforeStreamFinishes() async throws {
        let endpoint = URL(string: "https://reports.example.com/report")!
        let session = URLSession(configuration: {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ReportProtocol.self]
            return configuration
        }())
        let stopped = expectation(description: "Oversized response transfer cancelled")
        ReportProtocol.didStopLoading = { stopped.fulfill() }
        defer {
            session.invalidateAndCancel()
            ReportProtocol.streamOversizedResponse = false
            ReportProtocol.didStopLoading = nil
        }
        ReportProtocol.streamOversizedResponse = true
        ReportProtocol.loadingStopped = false
        ReportProtocol.streamFinished = false

        do {
            _ = try await IssueReportClient.send(.init(id: UUID(), diagnostics: "diagnostics"), endpoint: endpoint, session: session)
            XCTFail("An oversized response must be rejected")
        } catch let failure as IssueReportClient.Failure {
            XCTAssertEqual(failure.errorDescription, IssueReportClient.Failure.unconfirmed.errorDescription)
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertTrue(ReportProtocol.loadingStopped, "Receiving more than 1024 bytes must cancel the response task")
        XCTAssertFalse(ReportProtocol.streamFinished, "The response must stop before the stream completes")
    }

    func testReportDeliveryRequiresMatchingReceiptAndKeepsRetryIdentity() async throws {
        let endpoint = URL(string: "https://reports.example.com/report")!
        let report = IssueReportClient.Report(id: UUID(), diagnostics: "MeterUsage 0.2.41\nquota: unavailable (cliNotFound)")
        let request = try IssueReportClient.request(for: report, endpoint: endpoint)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["id", "schema", "diagnostics"])
        XCTAssertEqual(body["diagnostics"] as? String, report.diagnostics)
        XCTAssertEqual(body["id"] as? String, report.id.uuidString)
        XCTAssertThrowsError(try IssueReportClient.request(for: report, endpoint: nil))
        XCTAssertThrowsError(try IssueReportClient.request(for: report, endpoint: URL(string: "http://reports.example.com/report")))
        XCTAssertThrowsError(try IssueReportClient.request(for: report, endpoint: URL(string: "https://reports.example.com/report?key=example")))
        XCTAssertThrowsError(try IssueReportClient.request(for: .init(id: UUID(), diagnostics: String(repeating: "a", count: 49_153)), endpoint: endpoint))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ReportProtocol.calls = 0
        let receipt: [String: String] = ["id": report.id.uuidString, "identifier": "PB-123"]
        ReportProtocol.body = try JSONSerialization.data(withJSONObject: receipt)
        ReportProtocol.status = 201
        let identifier = try await IssueReportClient.send(report, endpoint: endpoint, session: session)
        XCTAssertEqual(identifier, "PB-123")

        for status in [200, 302, 429, 500] {
            ReportProtocol.status = status
            do {
                _ = try await IssueReportClient.send(report, endpoint: endpoint, session: session)
                XCTFail("HTTP \(status) must not confirm delivery")
            } catch let failure as IssueReportClient.Failure {
                if status == 429 { XCTAssertEqual(failure.errorDescription, IssueReportClient.Failure.rateLimited.errorDescription) }
            }
        }
        ReportProtocol.status = 201
        ReportProtocol.body = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "identifier": "PB-123"])
        do {
            _ = try await IssueReportClient.send(report, endpoint: endpoint, session: session)
            XCTFail("A receipt for another report must be rejected")
        } catch {}
        XCTAssertEqual(ReportProtocol.calls, 6, "Failures must not trigger automatic resubmission")
        XCTAssertEqual(try IssueReportClient.request(for: report, endpoint: endpoint).httpBody, request.httpBody)

        let delegate = IssueReportClient.NoRedirects()
        let task = session.dataTask(with: request)
        let response = HTTPURLResponse(url: endpoint, statusCode: 307, httpVersion: nil, headerFields: nil)!
        var redirectWasChecked = false
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: URLRequest(url: URL(string: "https://elsewhere.example.com")!)) { forwarded in
            redirectWasChecked = true
            XCTAssertNil(forwarded, "Diagnostics must never follow a redirect")
        }
        XCTAssertTrue(redirectWasChecked)
    }
}

private final class ReportProtocol: URLProtocol {
    static var status = 201
    static var body = Data()
    static var calls = 0
    static var streamOversizedResponse = false
    static var loadingStopped = false
    static var streamFinished = false
    static var didStopLoading: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if Self.streamOversizedResponse {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: 1025))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                if !Self.loadingStopped {
                    self.client?.urlProtocol(self, didLoad: Data(repeating: 66, count: 1025))
                    self.client?.urlProtocolDidFinishLoading(self)
                    Self.streamFinished = true
                }
            }
            return
        }
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.loadingStopped = true
        Self.didStopLoading?()
    }
}
