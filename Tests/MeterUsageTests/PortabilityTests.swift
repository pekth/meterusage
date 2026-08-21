import XCTest
@testable import MeterUsageCore

final class PortabilityTests: XCTestCase {
    func testWindowsCodexCandidatesUsePathSeparatorAndExecutableSuffixes() {
        let candidates = SubprocessJSONRPCClient.codexBinaryCandidates(
            environment: [
                "AppData": "C:\\Users\\test\\AppData\\Roaming",
                "Path": "C:\\Tools;D:\\Apps",
                "PathExt": ".EXE;.CMD",
            ],
            homeDirectory: "C:\\Users\\test",
            windows: true
        )

        XCTAssertTrue(candidates.contains("C:\\Tools\\codex.exe"))
        XCTAssertTrue(candidates.contains("C:\\Tools\\codex.cmd"))
        XCTAssertTrue(candidates.contains("D:\\Apps\\codex.exe"))
        XCTAssertTrue(candidates.contains("C:\\Users\\test\\AppData\\Roaming\\npm\\codex.cmd"))
        XCTAssertFalse(candidates.contains(where: { $0.contains("C:\\Tools;D:\\Apps") }))
    }

    func testWindowsChildPathUsesSemicolonsAndStartsWithBinaryDirectory() {
        let path = SubprocessJSONRPCClient.childPath(
            binary: "C:\\Users\\test\\AppData\\Roaming\\npm\\codex.cmd",
            environment: [
                "AppData": "C:\\Users\\test\\AppData\\Roaming",
                "Path": "C:\\Windows\\System32;C:\\Tools",
            ],
            homeDirectory: "C:\\Users\\test",
            windows: true
        )

        XCTAssertTrue(path.hasPrefix("C:\\Users\\test\\AppData\\Roaming\\npm;"))
        XCTAssertTrue(path.hasSuffix(";C:\\Windows\\System32;C:\\Tools"))
        XCTAssertFalse(path.contains(":" + "/"))
    }

    func testWindowsCommandWrapperUsesCmdExeWithoutInterpolatingUnsafePaths() throws {
        let configuration = try SubprocessJSONRPCClient.launchConfiguration(
            binary: "C:\\Program Files\\nodejs\\codex.cmd",
            arguments: ["app-server", "--stdio"],
            environment: ["COMSPEC": "C:\\Windows\\System32\\cmd.exe"],
            windows: true
        )

        XCTAssertEqual(configuration.executable, "C:\\Windows\\System32\\cmd.exe")
        XCTAssertEqual(configuration.arguments.prefix(3), ["/d", "/s", "/c"])
        XCTAssertEqual(
            configuration.arguments.last,
            "\"\"C:\\Program Files\\nodejs\\codex.cmd\" \"app-server\" \"--stdio\"\""
        )

        XCTAssertThrowsError(
            try SubprocessJSONRPCClient.launchConfiguration(
                binary: "C:\\Unsafe%PATH%\\codex.cmd",
                arguments: ["app-server", "--stdio"],
                environment: [:],
                windows: true
            )
        )
    }

    func testPosixChildPathKeepsColonSeparator() {
        let path = SubprocessJSONRPCClient.childPath(
            binary: "/usr/local/bin/codex",
            environment: ["PATH": "/usr/bin:/bin"],
            homeDirectory: "/Users/testuser",
            windows: false
        )

        XCTAssertEqual(path, "/opt/homebrew/bin:/usr/local/bin:/Users/testuser/.cargo/bin:/usr/bin:/bin")
    }
}
