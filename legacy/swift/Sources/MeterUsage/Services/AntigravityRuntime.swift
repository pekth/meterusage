import Foundation

final class AntigravityRuntimeResolver {
    typealias Command = (String, [String]) -> Data?

    private let lock = NSLock()
    private var lastRecoveryFailure: Date?
    private let cooldown: TimeInterval = 60

    func resolve(
        candidates: [String] = AntigravityRuntimeResolver.candidates(),
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:),
        run: @escaping Command = AntigravityRuntime.run,
        now: @escaping () -> Date = Date.init
    ) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let available = candidates.filter(isExecutable)
        if let healthy = available.first(where: { run($0, ["info"]) != nil }) {
            return healthy
        }

        if let failure = lastRecoveryFailure, now().timeIntervalSince(failure) < cooldown {
            return nil
        }
        guard let podman = available.first(where: { URL(fileURLWithPath: $0).lastPathComponent == "podman" }),
              run(podman, ["machine", "inspect", "podman-machine-default"]) != nil else {
            return nil
        }
        guard run(podman, ["machine", "start", "podman-machine-default"]) != nil,
              run(podman, ["info"]) != nil else {
            lastRecoveryFailure = now()
            return nil
        }
        lastRecoveryFailure = nil
        return podman
    }

    static func candidates() -> [String] {
        let fixed = [
            "/opt/homebrew/bin/docker", "/opt/homebrew/bin/podman",
            "/usr/local/bin/docker", "/usr/local/bin/podman", "/usr/bin/docker"
        ]
        let path = ProcessInfo.processInfo.environment["PATH", default: ""]
            .split(separator: ":")
            .flatMap { directory in ["docker", "podman"].map { String(directory) + "/" + $0 } }
        var seen = Set<String>()
        return (fixed + path).filter { seen.insert($0).inserted }
    }

}

enum AntigravityRuntime {
    static let resolver = AntigravityRuntimeResolver()

    static func resolve() -> String? {
        resolver.resolve()
    }

    static func run(executable: String, arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let outputData = LockedData()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outputData.append(output.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        let timeout: TimeInterval = arguments.first == "info" || arguments.contains("inspect") ? 5 : 30
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { usleep(10_000) }
        guard !process.isRunning else {
            process.terminate()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            return nil
        }
        guard group.wait(timeout: .now() + 1) == .success else { return nil }
        return process.terminationStatus == 0 ? outputData.value : nil
    }
}

private final class LockedData {
    private let lock = NSLock()
    private var data = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func append(_ data: Data) {
        lock.lock()
        self.data.append(data)
        lock.unlock()
    }
}
