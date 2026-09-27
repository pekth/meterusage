import XCTest
@testable import MeterUsage

@MainActor
final class APIConnectionTests: XCTestCase {
    func testConnectReadsBothReportsAndDisconnectForgetsEachKey() async throws {
        let keys = APIKeySession(environment: [:])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionProtocol.self]
        let session = URLSession(configuration: config)
        let name = "MeterUsageTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer {
            defaults.removePersistentDomain(forName: name)
            ConnectionProtocol.handler = nil
        }
        let preferences = Preferences(defaults: defaults)
        let before = defaults.persistentDomain(forName: name)
        let coordinator = AppCoordinator(preferences: preferences, usageSources: [
            OpenAIUsageSource(adminKey: { keys.key(for: .openAI) }, session: session),
            AnthropicUsageSource(adminKey: { keys.key(for: .anthropic) }, session: session)
        ], apiKeys: keys)

        for provider in [Provider.openAI, .anthropic] {
            var calls = 0
            ConnectionProtocol.handler = { request in
                calls += 1
                let header = provider == .openAI ? "Authorization" : "x-api-key"
                XCTAssertEqual(request.value(forHTTPHeaderField: header),
                               provider == .openAI ? "Bearer fixture-api-key" : "fixture-api-key")
                return 200
            }
            await coordinator.connectAPI(provider, key: "fixture-api-key")
            XCTAssertEqual(calls, 2, "Connect must verify usage and cost access")
            XCTAssertEqual(coordinator.usages[.primary(provider)]?.value?.tokens?.total, 0)
            XCTAssertTrue(coordinator.hasAPIKey(for: provider))
            XCTAssertFalse(coordinator.testingAPIProviders.contains(provider))
            XCTAssertFalse(coordinator.diagnosticsText().contains("fixture-api-key"))

            coordinator.disconnectAPI(provider)
            XCTAssertNil(keys.key(for: provider))
            XCTAssertNil(coordinator.usages[.primary(provider)]?.value)
            XCTAssertFalse(coordinator.hasAPIKey(for: provider))
        }
        XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, before as NSDictionary?)
        XCTAssertNil(APIKeySession(environment: [:]).key(for: .openAI))
    }

    func testRejectedCredentialNeverShowsConnectedOrRawError() async throws {
        let keys = APIKeySession(environment: [:])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionProtocol.self]
        defer { ConnectionProtocol.handler = nil }
        ConnectionProtocol.handler = { _ in 403 }
        let coordinator = AppCoordinator(preferences: Preferences(), usageSources: [
            OpenAIUsageSource(adminKey: { keys.key(for: .openAI) }, session: URLSession(configuration: config))
        ], apiKeys: keys)
        await coordinator.connectAPI(.openAI, key: "fixture-rejected-key")
        XCTAssertNil(coordinator.usages[.primary(.openAI)]?.value)
        XCTAssertEqual(coordinator.usages[.primary(.openAI)]?.unavailable,
                       .dataNotFound("OpenAI Admin API key with usage access"))
        XCTAssertFalse(coordinator.testingAPIProviders.contains(.openAI))
        XCTAssertFalse(coordinator.diagnosticsText().contains("private-error"))
    }

    func testDisconnectSuppressesEnvironmentKeyAndLateResponse() async throws {
        let keys = APIKeySession(environment: ["OPENAI_ADMIN_KEY": "fixture-environment-key"])
        let started = expectation(description: "usage request started")
        let source = SuspendedConnectionSource(started: started)
        let coordinator = AppCoordinator(preferences: Preferences(), usageSources: [source], apiKeys: keys)
        let connecting = Task { await coordinator.connectAPI(.openAI, key: "fixture-session-key") }
        await fulfillment(of: [started], timeout: 2)
        coordinator.disconnectAPI(.openAI)
        await source.finish()
        await connecting.value
        XCTAssertNil(keys.key(for: .openAI), "Disconnect must not fall back to the environment key")
        XCTAssertNil(coordinator.usages[.primary(.openAI)]?.value, "Discard a disconnected account's late response")
        XCTAssertFalse(coordinator.testingAPIProviders.contains(.openAI))
    }
}

private final class ConnectionProtocol: URLProtocol {
    static var handler: ((URLRequest) -> Int)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.handler!(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        let body = status == 200 ? "{\"data\":[],\"has_more\":false}" : "private-error"
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private actor SuspendedConnectionSource: UsageSource {
    nonisolated let provider: Provider = .openAI
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<ProviderUsage, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func fetchUsage() async throws -> ProviderUsage {
        await withCheckedContinuation {
            continuation = $0
            started.fulfill()
        }
    }
    func finish() {
        continuation?.resume(returning: ProviderUsage(provider: .openAI, sessionCount: 0, messageCount: 5, capturedAt: Date()))
        continuation = nil
    }
}
