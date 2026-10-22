import XCTest
@testable import MeterUsage

final class IssueReportSubmissionTests: XCTestCase {
    @MainActor
    func testSubmissionSurvivesSettingsRecreationAndRetriesSameReport() async throws {
        let suite = "IssueReportSubmissionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let coordinator = AppCoordinator(preferences: preferences, isDemoMode: true,
                                         quotaArchiveURL: FileManager.default.temporaryDirectory
                                            .appendingPathComponent("unused-\(UUID().uuidString).json"))
        let endpoint = URL(string: "https://reports.example.com/report")!
        let transport = SubmissionTransport()
        SubmissionProtocol.transport = transport
        defer { SubmissionProtocol.transport = nil }
        func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SubmissionProtocol.self]
            configuration.timeoutIntervalForResource = 2
            return URLSession(configuration: configuration)
        }

        var settings: SettingsView? = SettingsView(coordinator: coordinator, preferences: preferences)
        XCTAssertNotNil(settings)
        let started = expectation(description: "First submission awaits response")
        transport.started = started
        let first = Task { await coordinator.sendIssueReport(endpoint: endpoint, session: session()) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(coordinator.isSendingIssueReport)
        settings = nil
        settings = SettingsView(coordinator: coordinator, preferences: preferences)
        await coordinator.sendIssueReport(endpoint: endpoint, session: session())
        XCTAssertEqual(transport.count, 1, "Recreated Settings must not submit while the owner is busy")
        let originalBody = try transport.body(at: 0)
        try transport.respond(at: 0, status: 500)
        await first.value
        XCTAssertFalse(coordinator.isSendingIssueReport)
        XCTAssertNil(coordinator.issueReportReceipt)
        XCTAssertEqual(coordinator.issueReportError, IssueReportClient.Failure.unconfirmed.errorDescription)

        let retryStarted = expectation(description: "Explicit retry awaits response")
        transport.started = retryStarted
        let retry = Task { await coordinator.sendIssueReport(endpoint: endpoint, session: session()) }
        await fulfillment(of: [retryStarted], timeout: 2)
        XCTAssertNil(coordinator.issueReportError)
        XCTAssertEqual(try transport.body(at: 1), originalBody, "Uncertain retry must reuse the UUID and diagnostics bytes")
        try transport.respond(at: 1, status: 201)
        await retry.value
        settings = nil
        settings = SettingsView(coordinator: coordinator, preferences: preferences)
        XCTAssertNotNil(settings)
        XCTAssertFalse(coordinator.isSendingIssueReport)
        XCTAssertEqual(coordinator.issueReportReceipt, "PB-123")
        XCTAssertNil(coordinator.issueReportError)
        await coordinator.sendIssueReport(endpoint: endpoint, session: session())
        XCTAssertEqual(transport.count, 2, "A retained receipt must suppress another report")
    }
}

private final class SubmissionTransport {
    private let lock = NSLock()
    private var requests: [(SubmissionProtocol, Data)] = []
    var started: XCTestExpectation?
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    func start(_ source: SubmissionProtocol) throws {
        let body: Data
        if let data = source.request.httpBody {
            body = data
        } else {
            let stream = try XCTUnwrap(source.request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(contentsOf: buffer.prefix(read))
            }
            body = data
        }
        lock.lock()
        requests.append((source, body))
        lock.unlock()
        started?.fulfill()
    }

    func body(at index: Int) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        return try XCTUnwrap(requests.indices.contains(index) ? requests[index].1 : nil)
    }

    func respond(at index: Int, status: Int) throws {
        lock.lock()
        let entry = requests.indices.contains(index) ? requests[index] : nil
        lock.unlock()
        let (source, body) = try XCTUnwrap(entry)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let id = try XCTUnwrap(report["id"] as? String)
        let receipt = try JSONSerialization.data(withJSONObject: ["id": id, "identifier": "PB-123"])
        let response = try XCTUnwrap(HTTPURLResponse(url: source.request.url!, statusCode: status,
                                                    httpVersion: nil, headerFields: nil))
        source.client?.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
        source.client?.urlProtocol(source, didLoad: receipt)
        source.client?.urlProtocolDidFinishLoading(source)
    }
}

private final class SubmissionProtocol: URLProtocol {
    static var transport: SubmissionTransport?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do { try Self.transport?.start(self) }
        catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
