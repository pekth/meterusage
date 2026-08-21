import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Cross-platform stand-ins
//
// The core uses `ObservableObject` and `@Published` so the macOS SwiftUI views
// can observe it. Combine does not exist on Linux or Windows, so the platform
// shells get minimal stand-ins here: the shells drive refreshes explicitly
// (`coordinator.refresh()`, `coordinator.preferencesDidChange()`) and re-read
// published state on their own redraw tick, so no publisher plumbing is needed.

#if !canImport(Combine)

/// Marker protocol mirroring `Combine.ObservableObject` on platforms that
/// ship without Combine.
public protocol ObservableObject: AnyObject {}

/// Value-storage property wrapper mirroring `Combine.Published`. It holds the
/// value only; change notification is the shell's responsibility.
@propertyWrapper
public struct Published<Value> {
    public var wrappedValue: Value

    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }

    public init(initialValue: Value) {
        self.wrappedValue = initialValue
    }
}

#endif

#if canImport(FoundationNetworking) && compiler(<6.0)

extension URLSession {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            dataTask(with: request) { data, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, let response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }.resume()
        }
    }
}

#endif

// MARK: - Process paths

struct ProcessPath {
    static func environmentValue(
        for key: String,
        in environment: [String: String],
        windows: Bool
    ) -> String? {
        if let value = environment[key] { return value }
        guard windows else { return nil }
        return environment.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    static func entries(in value: String, windows: Bool) -> [String] {
        value.split(separator: windows ? ";" : ":", omittingEmptySubsequences: true).map(String.init)
    }

    static func executableNames(
        for name: String,
        windows: Bool,
        pathExtensions: String? = nil
    ) -> [String] {
        guard windows else { return [name] }

        let configuredExtensions = pathExtensions.map { entries(in: $0, windows: true) } ?? []
        let rawExtensions = configuredExtensions.isEmpty
            ? [".COM", ".EXE", ".BAT", ".CMD"]
            : configuredExtensions
        var names: [String] = []
        for suffix in rawExtensions {
            let normalized = suffix.hasPrefix(".") ? suffix : "." + suffix
            let candidate = name + normalized.lowercased()
            if !names.contains(where: { $0.caseInsensitiveCompare(candidate) == .orderedSame }) {
                names.append(candidate)
            }
        }
        return names
    }

    static func appending(_ component: String, to directory: String, windows: Bool) -> String {
        let separator = windows ? "\\" : "/"
        guard !directory.hasSuffix(separator) else { return directory + component }
        return directory + separator + component
    }

    static func directory(of path: String, windows: Bool) -> String {
        let separators: Set<Character> = windows ? ["\\", "/"] : ["/"]
        guard let index = path.lastIndex(where: { separators.contains($0) }) else { return "" }
        return String(path[..<index])
    }

    static func prepending(_ directories: [String], to existing: String?, windows: Bool) -> String {
        let separator = windows ? ";" : ":"
        let values = directories + (existing.map { [$0] } ?? [])
        return values.filter { !$0.isEmpty }.joined(separator: separator)
    }
}
