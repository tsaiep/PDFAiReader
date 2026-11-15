import XCTest
@testable import TranslationCodex

final class CodexTests: XCTestCase {
    func testArgumentsAreFixedAndPromptViaStdin() {
        let args = CodexCLIEngine.arguments(model: "some-model", schemaPath: "/s.json",
                                            outputPath: "/o.txt", workingDirectory: "/cwd", extra: [])
        XCTAssertEqual(args.first, "exec")
        XCTAssertEqual(args.last, "-")
        XCTAssertTrue(args.contains("read-only"))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertEqual(args[args.firstIndex(of: "-m")! + 1], "some-model")
    }

    func testNoModelFlagWhenNil() {
        let args = CodexCLIEngine.arguments(model: nil, schemaPath: "/s", outputPath: "/o",
                                            workingDirectory: "/c", extra: [])
        XCTAssertFalse(args.contains("-m"))
    }

    func testEnvironmentAddsExecutableDirToPath() {
        let env = CodexLocator.environment(for: URL(fileURLWithPath: "/Users/x/.nvm/versions/node/v22/bin/codex"),
                                           base: ["PATH": "/usr/bin"])
        XCTAssertTrue(env["PATH"]!.hasPrefix("/Users/x/.nvm/versions/node/v22/bin:"))
        XCTAssertEqual(env["PATH"]!.components(separatedBy: ":").filter { $0 == "/usr/bin" }.count, 1)
    }

    func testProcessRunnerStdinAndExitCode() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"),
                                                 arguments: [], stdin: Data("你好".utf8), timeout: 10)
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "你好")
    }

    func testProcessRunnerTimeout() async throws {
        let result = try await ProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sleep"),
                                                 arguments: ["5"], timeout: 0.5)
        XCTAssertTrue(result.timedOut)
    }
}
