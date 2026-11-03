import XCTest
@testable import MeterUsage

final class AntigravityRuntimeTests: XCTestCase {
    func testHealthyCandidateWinsOverFirstExecutable() {
        let resolver = AntigravityRuntimeResolver()
        var calls: [[String]] = []
        let result = resolver.resolve(
            candidates: ["/fake/docker", "/fake/podman"],
            isExecutable: { _ in true },
            run: { executable, arguments in
                calls.append([executable] + arguments)
                return executable == "/fake/podman" && arguments == ["info"] ? Data() : nil
            }
        )
        XCTAssertEqual(result, "/fake/podman")
        XCTAssertEqual(calls, [["/fake/docker", "info"], ["/fake/podman", "info"]])
    }

    func testStoppedExistingDefaultMachineStartsOnceAndRecovers() {
        let resolver = AntigravityRuntimeResolver()
        var calls: [[String]] = []
        var started = false
        let result = resolver.resolve(
            candidates: ["/fake/podman"],
            isExecutable: { _ in true },
            run: { executable, arguments in
                calls.append([executable] + arguments)
                if arguments == ["machine", "start", "podman-machine-default"] {
                    started = true
                    return Data()
                }
                if arguments == ["machine", "inspect", "podman-machine-default"] { return Data() }
                return started && arguments == ["info"] ? Data() : nil
            }
        )
        XCTAssertEqual(result, "/fake/podman")
        XCTAssertEqual(calls, [
            ["/fake/podman", "info"],
            ["/fake/podman", "machine", "inspect", "podman-machine-default"],
            ["/fake/podman", "machine", "start", "podman-machine-default"],
            ["/fake/podman", "info"]
        ])
    }

    func testAbsentMachineDoesNotStartOrCreate() {
        let resolver = AntigravityRuntimeResolver()
        var calls: [[String]] = []
        XCTAssertNil(resolver.resolve(
            candidates: ["/fake/podman"],
            isExecutable: { _ in true },
            run: { executable, arguments in
                calls.append([executable] + arguments)
                return nil
            }
        ))
        XCTAssertFalse(calls.contains { $0.contains("start") || $0.contains("create") })
    }

    func testFailedStartUsesCooldown() {
        let resolver = AntigravityRuntimeResolver()
        var now = Date(timeIntervalSince1970: 100)
        var starts = 0
        let run: AntigravityRuntimeResolver.Command = { _, arguments in
            if arguments == ["machine", "inspect", "podman-machine-default"] { return Data() }
            if arguments == ["machine", "start", "podman-machine-default"] { starts += 1 }
            return nil
        }
        XCTAssertNil(resolver.resolve(candidates: ["/fake/podman"], isExecutable: { _ in true }, run: run, now: { now }))
        XCTAssertNil(resolver.resolve(candidates: ["/fake/podman"], isExecutable: { _ in true }, run: run, now: { now }))
        XCTAssertEqual(starts, 1)
        now.addTimeInterval(61)
        XCTAssertNil(resolver.resolve(candidates: ["/fake/podman"], isExecutable: { _ in true }, run: run, now: { now }))
        XCTAssertEqual(starts, 2)
    }

    func testHealthyRuntimeNeverStartsMachine() {
        let resolver = AntigravityRuntimeResolver()
        var calls: [[String]] = []
        _ = resolver.resolve(
            candidates: ["/fake/docker", "/fake/podman"],
            isExecutable: { _ in true },
            run: { executable, arguments in
                calls.append([executable] + arguments)
                return arguments == ["info"] && executable == "/fake/docker" ? Data() : nil
            }
        )
        XCTAssertFalse(calls.contains { $0.contains("machine") })
    }

    func testConcurrentRecoveryStartsOnlyOnce() {
        let resolver = AntigravityRuntimeResolver()
        var starts = 0
        DispatchQueue.concurrentPerform(iterations: 2) { _ in
            let result = resolver.resolve(
                candidates: ["/fake/podman"],
                isExecutable: { _ in true },
                run: { _, arguments in
                    if arguments == ["machine", "inspect", "podman-machine-default"] { return Data() }
                    if arguments == ["machine", "start", "podman-machine-default"] {
                        starts += 1
                        return Data()
                    }
                    return starts > 0 && arguments == ["info"] ? Data() : nil
                }
            )
            XCTAssertEqual(result, "/fake/podman")
        }
        XCTAssertEqual(starts, 1)
    }
}
