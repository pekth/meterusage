import Foundation

/// The app sends only its generated diagnostics. Linear credentials belong to the relay.
enum IssueReportClient {
    struct Report: Encodable {
        let schema = 1
        let id: UUID
        let diagnostics: String
    }

    struct Receipt: Decodable {
        let id: UUID
        let identifier: String
    }

    enum Failure: Error, LocalizedError {
        case unavailable, tooLarge, rateLimited, unconfirmed

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Reporting is unavailable in this build. You can still copy diagnostics."
            case .tooLarge: return "This report is too large to send. Copy diagnostics to keep the full report."
            case .rateLimited: return "Too many reports. Please wait a minute, then try again."
            case .unconfirmed: return "Delivery could not be confirmed. Try again or copy diagnostics."
            }
        }
    }

    static var endpoint: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "MeterUsageReportURL") as? String else { return nil }
        return URL(string: value)
    }

    static func request(for report: Report, endpoint: URL?) throws -> URLRequest {
        guard let endpoint, endpoint.scheme == "https", endpoint.host != nil,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil,
              endpoint.fragment == nil else { throw Failure.unavailable }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(report)
        guard !report.diagnostics.isEmpty, report.diagnostics.utf8.count <= 49_152,
              data.count <= 65_536 else { throw Failure.tooLarge }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = data
        return request
    }

    static func send(_ report: Report, endpoint: URL?, session: URLSession) async throws -> String {
        let request = try request(for: report, endpoint: endpoint)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse else { throw Failure.unconfirmed }
            if http.statusCode == 429 { throw Failure.rateLimited }
            guard http.statusCode == 201 else { throw Failure.unconfirmed }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1024 else { throw Failure.unconfirmed }
                data.append(byte)
            }
            guard let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
                  receipt.id == report.id,
                  receipt.identifier.range(of: "^[A-Z][A-Z0-9]{0,15}-[0-9]{1,12}$", options: .regularExpression) != nil
            else { throw Failure.unconfirmed }
            return receipt.identifier
        } catch let failure as Failure {
            throw failure
        } catch {
            // Provider/server error bodies and URLs must never reach the UI or the next report.
            throw Failure.unconfirmed
        }
    }

    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForResource = 25
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
}
