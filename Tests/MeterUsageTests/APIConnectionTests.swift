import XCTest
@testable import MeterUsage

@MainActor
final class APIConnectionTests: XCTestCase {
    func testSessionRecreationRetainsEnteredKey() throws {
        let store = MemoryAPIKeyStore()
        for provider in [Provider.openAI, .anthropic] {
            let firstLaunch = APIKeySession(environment: [:], store: store)
            try firstLaunch.set("  fixture-persistent-key\n", for: provider)
            let nextLaunch = APIKeySession(environment: ["OPENAI_ADMIN_KEY": "fixture-env",
                                                        "ANTHROPIC_ADMIN_KEY": "fixture-env"], store: store)
            XCTAssertTrue(nextLaunch.key(for: provider) == "fixture-persistent-key",
                          "A saved key must survive restart and take precedence over the launcher")
            try nextLaunch.set("fixture-replacement", for: provider)
            let updatedLaunch = APIKeySession(environment: [:], store: store)
            XCTAssertTrue(updatedLaunch.key(for: provider) == "fixture-replacement")
            try updatedLaunch.set(nil, for: provider)
            XCTAssertNil(APIKeySession(environment: [:], store: store).key(for: provider))
        }
    }

    func testConnectReadsBothReportsAndDisconnectForgetsEachKey() async throws {
        let store = MemoryAPIKeyStore()
        let keys = APIKeySession(environment: [:], store: store)
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
            XCTAssertTrue(APIKeySession(environment: [:], store: store).key(for: provider) == "fixture-api-key")
            XCTAssertFalse(coordinator.testingAPIProviders.contains(provider))
            XCTAssertFalse(coordinator.diagnosticsText().contains("fixture-api-key"))

            coordinator.disconnectAPI(provider)
            XCTAssertNil(keys.key(for: provider))
            XCTAssertNil(coordinator.usages[.primary(provider)]?.value)
            XCTAssertFalse(coordinator.hasAPIKey(for: provider))
            XCTAssertNil(APIKeySession(environment: [:], store: store).key(for: provider))
        }
        XCTAssertEqual(defaults.persistentDomain(forName: name) as NSDictionary?, before as NSDictionary?)
        XCTAssertNil(APIKeySession(environment: [:]).key(for: .openAI))
    }

    func testRejectedCredentialNeverShowsConnectedOrRawError() async throws {
        let store = MemoryAPIKeyStore()
        let keys = APIKeySession(environment: [:], store: store)
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
        XCTAssertTrue(APIKeySession(environment: [:], store: store).key(for: .openAI) == "fixture-rejected-key",
                      "A provider error must not delete the saved credential")
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

    func testFailedSaveAndDeletePreserveExistingConnection() async throws {
        let store = MemoryAPIKeyStore()
        let keys = APIKeySession(environment: [:], store: store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionProtocol.self]
        var calls = 0
        ConnectionProtocol.handler = { _ in calls += 1; return 200 }
        defer { ConnectionProtocol.handler = nil }
        let coordinator = AppCoordinator(preferences: Preferences(), usageSources: [
            OpenAIUsageSource(adminKey: { keys.key(for: .openAI) }, session: URLSession(configuration: config))
        ], apiKeys: keys)
        await coordinator.connectAPI(.openAI, key: "fixture-original")
        let revision = keys.revision(for: .openAI)
        store.writeError = NSError(domain: "private-storage-error", code: 1)
        await coordinator.connectAPI(.openAI, key: "fixture-replacement")
        XCTAssertEqual(calls, 2, "A failed save must not test a different or unsaved credential")
        XCTAssertNotNil(coordinator.apiConnectionErrors[.openAI])
        XCTAssertFalse(coordinator.apiConnectionErrors[.openAI]!.contains("private-storage-error"))
        coordinator.disconnectAPI(.openAI)
        XCTAssertNotNil(coordinator.apiConnectionErrors[.openAI])
        XCTAssertTrue(keys.key(for: .openAI) == "fixture-original")
        XCTAssertTrue(store.values[.openAI] == "fixture-original")
        XCTAssertEqual(keys.revision(for: .openAI), revision)
        XCTAssertNotNil(coordinator.usages[.primary(.openAI)]?.value)
        store.writeError = nil
        coordinator.disconnectAPI(.openAI)
        XCTAssertNil(coordinator.apiConnectionErrors[.openAI])
        XCTAssertNil(APIKeySession(environment: [:], store: store).key(for: .openAI))
    }

    func testDeniedReadCanRetrySavedKeyWithoutNewEntry() async throws {
        let store = MemoryAPIKeyStore()
        store.values[.openAI] = "fixture-saved"
        store.readError = NSError(domain: "private-read-error", code: 1)
        let keys = APIKeySession(environment: ["OPENAI_ADMIN_KEY": "fixture-different-account"], store: store)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ConnectionProtocol.self]
        ConnectionProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-saved")
            return 200
        }
        defer { ConnectionProtocol.handler = nil }
        let coordinator = AppCoordinator(preferences: Preferences(), usageSources: [
            OpenAIUsageSource(adminKey: { keys.key(for: .openAI) }, session: URLSession(configuration: config))
        ], apiKeys: keys)
        XCTAssertFalse(coordinator.hasAPIKey(for: .openAI), "Denied access must not switch to another account")
        XCTAssertNotNil(coordinator.apiConnectionErrors[.openAI])
        store.readError = nil
        await coordinator.retrySavedAPIKey(.openAI)
        XCTAssertNil(coordinator.apiConnectionErrors[.openAI])
        XCTAssertNotNil(coordinator.usages[.primary(.openAI)]?.value)
        XCTAssertTrue(coordinator.hasAPIKey(for: .openAI))
    }

    func testEnvironmentFallbackIsNotPersistedAndDemoCannotMutateStore() async throws {
        let store = MemoryAPIKeyStore()
        let keys = APIKeySession(environment: ["OPENAI_ADMIN_KEY": "fixture-env"], store: store)
        XCTAssertTrue(keys.key(for: .openAI) == "fixture-env")
        XCTAssertTrue(store.values.isEmpty)
        let demo = AppCoordinator(preferences: Preferences(), isDemoMode: true, apiKeys: keys)
        await demo.connectAPI(.openAI, key: "fixture-demo")
        demo.disconnectAPI(.openAI)
        await demo.retrySavedAPIKey(.openAI)
        XCTAssertTrue(keys.key(for: .openAI) == "fixture-env")
        XCTAssertTrue(store.values.isEmpty)
    }

    func testOldResponseCannotOverwriteReplacementConnection() async throws {
        let store = MemoryAPIKeyStore()
        let keys = APIKeySession(environment: [:], store: store)
        let started = expectation(description: "old request started")
        let source = SuspendedConnectionSource(started: started)
        let coordinator = AppCoordinator(preferences: Preferences(), usageSources: [source], apiKeys: keys)
        let connecting = Task { await coordinator.connectAPI(.openAI, key: "fixture-old") }
        await fulfillment(of: [started], timeout: 2)
        coordinator.disconnectAPI(.openAI)
        try keys.set("fixture-new", for: .openAI)
        await source.finish()
        await connecting.value
        XCTAssertTrue(APIKeySession(environment: [:], store: store).key(for: .openAI) == "fixture-new")
        XCTAssertNil(coordinator.usages[.primary(.openAI)]?.value)
    }
}

private final class MemoryAPIKeyStore: APIKeyStore {
    var values: [Provider: String] = [:]
    var readError: Error?
    var writeError: Error?
    func read(_ provider: Provider) throws -> String? {
        if let readError { throw readError }
        return values[provider]
    }
    func write(_ key: String?, for provider: Provider) throws {
        if let writeError { throw writeError }
        values[provider] = key
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
