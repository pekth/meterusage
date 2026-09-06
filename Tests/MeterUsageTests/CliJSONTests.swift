import XCTest
@testable import MeterUsage

final class CliJSONTests: XCTestCase {
    actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var started = false
        private var startContinuation: CheckedContinuation<Void, Never>?

        func wait() async {
            started = true
            startContinuation?.resume()
            startContinuation = nil
            await withCheckedContinuation { continuation = $0 }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startContinuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testTimeoutReturnsBeforeNonCooperativeWorkReleases() async {
        let gate = Gate()
        let started = Date()
        let task = Task {
            try await withTimeout(0.02) {
                await gate.wait()
                return "released"
            }
        }
        await gate.waitUntilStarted()
        let releaser = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await gate.release()
        }

        do {
            _ = try await task.value
            XCTFail("expected timeout")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await releaser.value
    }

    func testCancellationAndLateCompletionResumeOnlyOnce() async {
        let gate = Gate()
        let task = Task {
            try await withTimeout(30) {
                await gate.wait()
                return "released"
            }
        }
        await gate.waitUntilStarted()
        let started = Date()
        let releaser = Task {
            try? await Task.sleep(nanoseconds: 200_000_000)
            await gate.release()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        await releaser.value
    }
}
