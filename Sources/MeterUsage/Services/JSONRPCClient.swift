import Foundation

// MARK: - Transport contract
//
// `CodexQuotaSource` never spawns a process itself — it talks to a
// `JSONRPCClient`. That indirection is the whole reason the parsing and
// error-classification logic in `CodexQuotaSource` can be unit tested on a
// machine with no `codex` binary installed and with the network disabled:
// tests inject a fake client that hands back canned bytes instead of running
// `codex app-server --stdio`.

/// Failures that happen *before* we have a well-formed JSON-RPC exchange —
/// i.e. the process itself never produced a usable response. A JSON-RPC
/// *protocol* error (the server answered with `{"error": ...}`) is not one of
/// these; that is a normal, well-formed response and is returned as data for
/// `CodexQuotaSource` to interpret.
public enum JSONRPCTransportError: Error, Equatable, Sendable {
    /// The `codex` binary could not be located anywhere we looked.
    case processNotFound(path: String)
    /// No id-2 response arrived within the timeout ceiling.
    case timeout
    /// The child process exited (or closed stdout) before answering.
    case processExited(status: Int32, stderrTail: String)
}

/// Speaks just enough JSON-RPC to drive the Codex quota handshake.
///
/// Deliberately narrow: this is not a general-purpose JSON-RPC client, it is
/// exactly the one exchange `CodexQuotaSource` needs. Keeping it narrow is
/// what makes the fake test implementation a few lines instead of a mock
/// framework.
public protocol JSONRPCClient: Sendable {
    /// Runs the initialize -> initialized -> account/rateLimits/read
    /// handshake and returns the raw response line whose `"id"` is `2`.
    ///
    /// The returned `Data` is a single JSON object — either
    /// `{"id":2,"result":{...}}` or `{"id":2,"error":{...}}`. Both are valid,
    /// well-formed responses; only process-level failures throw
    /// `JSONRPCTransportError`.
    func requestCodexRateLimits() async throws -> Data
}

// MARK: - Real transport

/// Spawns `codex app-server --stdio`, performs the handshake, and returns the
/// id-2 response line. Never kept resident: the child process is torn down
/// as soon as we have (or fail to get) an answer.
public final class SubprocessJSONRPCClient: JSONRPCClient {
    private let clientVersion: String
    /// Ceiling observed round-trip is 0.6-0.9s on this machine; 20s gives
    /// generous headroom for a cold-started CLI without hanging the UI
    /// indefinitely if the process wedges.
    private let timeout: TimeInterval

    public init(clientVersion: String = "1.0", timeout: TimeInterval = 20) {
        self.clientVersion = clientVersion
        self.timeout = timeout
    }

    public func requestCodexRateLimits() async throws -> Data {
        let binary = try Self.resolveCodexBinary()
        let clientVersion = self.clientVersion
        let timeout = self.timeout

        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                try Self.runExchange(binary: binary, clientVersion: clientVersion)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw JSONRPCTransportError.timeout
            }
            defer { group.cancelAll() }
            // First finisher wins: either the exchange completed or the
            // timeout fired first.
            guard let result = try await group.next() else { throw JSONRPCTransportError.timeout }
            return result
        }
    }

    /// A GUI-launched app inherits a bare PATH (often just
    /// `/usr/bin:/bin:/usr/sbin:/sbin`), which is not where Homebrew, a
    /// manual install, or cargo puts `codex`. Probe the common install
    /// locations directly instead of assuming PATH already has them.
    private static func resolveCodexBinary() throws -> String {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            HomeDirectory.real.appendingPathComponent(".cargo/bin/codex").path,
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let candidate = String(dir) + "/codex"
                if fm.isExecutableFile(atPath: candidate) { return candidate }
            }
        }
        throw JSONRPCTransportError.processNotFound(path: "codex")
    }

    /// Synchronous by design: this runs inside a `Task.addTask` closure that
    /// already has its own thread from the cooperative pool's blocking-work
    /// allowance, and the whole call is raced against a timeout task above.
    private static func runExchange(binary: String, clientVersion: String) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["app-server", "--stdio"]

        // Same PATH problem as binary resolution: the child's own
        // `#!/usr/bin/env node` shebang (codex-cli ships as a Node wrapper on
        // some install paths) needs `node` to be findable too. Prepend the
        // common install dirs onto whatever PATH we inherited rather than
        // replacing it, so we don't break anything the parent process set.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            HomeDirectory.real.appendingPathComponent(".cargo/bin").path,
        ]
        let existingPath = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (extraPaths + [existingPath]).joined(separator: ":")
        process.environment = env

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // stdin is intentionally never closed here (no
        // `stdinPipe.fileHandleForWriting.closeFile()`). Closing it before
        // the id-2 response arrives was confirmed empirically to make the
        // server exit without ever answering — `codex app-server` reads
        // stdin closing as "no more requests are coming, shut down." It
        // stays open for the lifetime of this function; the `defer` above
        // tears the whole process down (which also closes the pipes) only
        // after we have a response or have given up.

        do {
            try process.run()
        } catch {
            throw JSONRPCTransportError.processNotFound(path: binary)
        }
        defer {
            if process.isRunning { process.terminate() }
        }

        func writeLine(_ object: [String: Any]) throws {
            let payload = try JSONSerialization.data(withJSONObject: object)
            var line = payload
            line.append(0x0A)
            stdinPipe.fileHandleForWriting.write(line)
        }

        // Newline-delimited JSON-RPC handshake. `initialized` is a
        // notification (no "id") per spec, so the server never answers it.
        try writeLine([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["clientInfo": ["name": "meterusage", "version": clientVersion]],
        ])
        let outHandle = stdoutPipe.fileHandleForReading
        var buffer = Data()
        let newline = Data([0x0A])

        /// Reads whole lines until `predicate` accepts one, then returns it.
        ///
        /// Every line that isn't the one we want is discarded here and never
        /// decoded: the id-1 `initialize` response carries a `userAgent`
        /// naming our parent process, and `remoteControl/status/changed`
        /// carries `installationId` and `serverName` (this Mac's hostname).
        /// Dropping them at the transport means no model can ever see them.
        func readLine(until predicate: (Data) -> Bool) throws -> Data {
            while true {
                while let range = buffer.range(of: newline) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    if lineData.isEmpty { continue }
                    if predicate(lineData) { return lineData }
                }
                let chunk = outHandle.availableData
                if chunk.isEmpty {
                    let errData = stderrPipe.fileHandleForReading.availableData
                    let stderrTail = String(data: errData, encoding: .utf8) ?? ""
                    throw JSONRPCTransportError.processExited(
                        status: process.terminationStatus,
                        stderrTail: stderrTail
                    )
                }
                buffer.append(chunk)
            }
        }

        // Wait for the `initialize` reply before sending anything else.
        //
        // Sending `initialized` + the read request immediately after
        // `initialize` races the server's own startup: it can still be
        // settling and then never answers id 2 at all (confirmed against the
        // real binary). Waiting on the id-1 reply is the correct fix rather
        // than sleeping a fixed interval — it is both faster in the common
        // case (the real round-trip is well under a second) and reliable on a
        // slow machine, where any hardcoded pause would eventually be too
        // short. It also keeps us off `Thread.sleep`, which would block a
        // cooperative-pool thread for the duration.
        _ = try readLine(until: { messageID(from: $0) == 1 })

        try writeLine(["jsonrpc": "2.0", "method": "initialized", "params": [String: Any]()])
        try writeLine(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [String: Any]()])

        return try readLine(until: { messageID(from: $0) == 2 })
    }

    private static func messageID(from line: Data) -> Int? {
        struct Probe: Decodable { let id: Int? }
        return try? JSONDecoder().decode(Probe.self, from: line).id
    }
}
