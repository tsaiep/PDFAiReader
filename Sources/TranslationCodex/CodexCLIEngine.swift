import Foundation
import ReaderCore

public struct CodexConfiguration: Sendable, Equatable {
    /// 使用者手動指定的 codex 路徑；nil = 自動偵測。
    public var executablePath: String?
    /// 預設模型；nil = 使用 codex 自身設定的預設模型。
    public var defaultModel: String?
    public var timeout: TimeInterval
    /// 額外參數（例如 `-c model_reasoning_effort="low"`），由 Phase 0 測試結果決定。
    public var extraArguments: [String]

    /// Phase 0 實測（2026-11-15，codex-cli 0.169.0）：reasoning effort low 每頁約 11.7 秒，
    /// 預設約 16.6 秒，譯文品質檢查皆通過。
    public static let defaultExtraArguments = ["-c", "model_reasoning_effort=\"low\""]

    public init(executablePath: String? = nil, defaultModel: String? = nil,
                timeout: TimeInterval = 180, extraArguments: [String] = CodexConfiguration.defaultExtraArguments) {
        self.executablePath = executablePath
        self.defaultModel = defaultModel
        self.timeout = timeout
        self.extraArguments = extraArguments
    }
}

public enum CodexError: Error, LocalizedError, Equatable {
    case notInstalled
    case nonZeroExit(code: Int32, stderrTail: String)
    case timedOut
    case cancelled
    case missingOutput
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return CoreStrings.L("找不到 Codex CLI，請安裝或在設定中指定路徑。", "Codex CLI not found. Install it or set its path in Settings.")
        case .nonZeroExit(let code, let tail): return CoreStrings.L("Codex 結束碼 \(code)：\(tail)", "Codex exited with code \(code): \(tail)")
        case .timedOut: return CoreStrings.L("Codex 執行逾時。", "Codex timed out.")
        case .cancelled: return CoreStrings.L("已取消。", "Cancelled.")
        case .missingOutput: return CoreStrings.L("Codex 沒有產生輸出。", "Codex produced no output.")
        case .invalidOutput(let s): return CoreStrings.L("Codex 輸出格式錯誤：\(s)", "Unexpected Codex output: \(s)")
        }
    }
}

/// 以 `codex exec` 非互動模式執行翻譯。
///
/// 安全措施：
/// - Prompt（含 OCR 文字）只經 stdin 傳入，不放命令列參數
/// - 工作目錄為空的暫存資料夾，`--sandbox read-only`
/// - 只執行固定的子命令與旗標
public actor CodexCLIEngine: TranslationEngine {
    public nonisolated let engineID = "codex-cli"
    public private(set) var configuration: CodexConfiguration

    public init(configuration: CodexConfiguration = CodexConfiguration()) {
        self.configuration = configuration
    }

    public func update(configuration: CodexConfiguration) {
        self.configuration = configuration
    }

    public func executableURL() async -> URL? {
        await CodexLocator.locate(override: configuration.executablePath)
    }

    public func availability() async -> EngineAvailability {
        guard let exe = await executableURL() else { return .notInstalled }
        let env = CodexLocator.environment(for: exe)
        do {
            let version = try await ProcessRunner.run(executable: exe, arguments: ["--version"],
                                                      environment: env, timeout: 15)
            guard version.exitCode == 0 else {
                return .error(Self.tail(version.stderrString.isEmpty ? version.stdoutString : version.stderrString))
            }
            let versionText = version.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)

            let login = try await ProcessRunner.run(executable: exe, arguments: ["login", "status"],
                                                    environment: env, timeout: 15)
            if login.exitCode != 0 {
                let detail = (login.stderrString + login.stdoutString).trimmingCharacters(in: .whitespacesAndNewlines)
                return .notLoggedIn(detail: Self.tail(detail))
            }
            return .available(version: versionText)
        } catch {
            return .error(error.localizedDescription)
        }
    }

    public func translate(_ request: TranslationRequest) async throws -> TranslationResponse {
        guard let exe = await executableURL() else { throw CodexError.notInstalled }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory
            .appendingPathComponent("PDFAiReader-codex", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: workDir) }

        // schema 與輸出檔放在工作目錄外層的同一個暫存資料夾，工作目錄本身保持空白。
        let ioDir = workDir.appendingPathComponent("io", isDirectory: true)
        let sandboxDir = workDir.appendingPathComponent("cwd", isDirectory: true)
        try fm.createDirectory(at: ioDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sandboxDir, withIntermediateDirectories: true)

        let schemaURL = ioDir.appendingPathComponent("schema.json")
        let outputURL = ioDir.appendingPathComponent("last-message.txt")
        try TranslationPrompt.outputSchemaJSON.write(to: schemaURL, atomically: true, encoding: .utf8)

        let args = Self.arguments(model: request.model ?? configuration.defaultModel,
                                  schemaPath: schemaURL.path,
                                  outputPath: outputURL.path,
                                  workingDirectory: sandboxDir.path,
                                  extra: configuration.extraArguments)
        let prompt = TranslationPrompt.build(request)

        let result = try await ProcessRunner.run(executable: exe,
                                                 arguments: args,
                                                 environment: CodexLocator.environment(for: exe),
                                                 currentDirectory: sandboxDir,
                                                 stdin: Data(prompt.utf8),
                                                 timeout: configuration.timeout)
        if result.cancelled || Task.isCancelled { throw CodexError.cancelled }
        if result.timedOut { throw CodexError.timedOut }
        guard result.exitCode == 0 else {
            throw CodexError.nonZeroExit(code: result.exitCode, stderrTail: Self.tail(result.stderrString))
        }

        let raw: String
        if let text = try? String(contentsOf: outputURL, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = text
        } else if !result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            raw = result.stdoutString
        } else {
            throw CodexError.missingOutput
        }

        do {
            return try TranslationResultValidator.decode(raw)
        } catch {
            throw CodexError.invalidOutput(String(raw.prefix(300)))
        }
    }

    /// 固定的參數組合。抽出成靜態函式以便單元測試。
    public static func arguments(model: String?, schemaPath: String, outputPath: String,
                                 workingDirectory: String, extra: [String]) -> [String] {
        var args = [
            "exec",
            "--skip-git-repo-check",
            "--ephemeral",            // 不保存 session 紀錄
            "--sandbox", "read-only",
            "--color", "never",
            "--output-schema", schemaPath,
            "--output-last-message", outputPath,
            "-C", workingDirectory,
        ]
        if let model, !model.isEmpty {
            args += ["-m", model]
        }
        args += extra
        args.append("-")   // 從 stdin 讀取 prompt
        return args
    }

    static func tail(_ s: String, max: Int = 600) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > max ? "…" + String(trimmed.suffix(max)) : trimmed
    }
}
