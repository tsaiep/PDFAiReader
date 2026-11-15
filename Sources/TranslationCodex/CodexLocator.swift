import Foundation

/// 找出 codex 執行檔。從 Finder 啟動的 GUI App 不會繼承 shell 的 PATH，
/// 因此依序檢查常見安裝位置，最後才用登入 shell 查詢。
public enum CodexLocator {
    public static func candidatePaths(home: String = NSHomeDirectory()) -> [String] {
        var paths = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.volta/bin/codex",
            "\(home)/.bun/bin/codex",
        ]
        // nvm：~/.nvm/versions/node/<version>/bin/codex（新版本優先）
        let nvmRoot = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmRoot) {
            for v in versions.sorted(by: >) {
                paths.append("\(nvmRoot)/\(v)/bin/codex")
            }
        }
        return paths
    }

    /// - Parameter override: 使用者在設定中手動指定的路徑（優先）。
    public static func locate(override: String? = nil) async -> URL? {
        let fm = FileManager.default
        if let override, !override.isEmpty {
            let expanded = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for path in candidatePaths() where fm.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return await locateViaLoginShell()
    }

    private static func locateViaLoginShell() async -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let result = try? await ProcessRunner.run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-l", "-c", "command -v codex"],
            timeout: 10
        ), result.exitCode == 0 else { return nil }
        let path = result.stdoutString
            .split(separator: "\n").last
            .map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// npm 版 codex 是 `#!/usr/bin/env node` 腳本，需要 PATH 裡有 node。
    /// 把 codex 所在資料夾與常見路徑補進 PATH。
    public static func environment(for executable: URL,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let extra = [
            executable.deletingLastPathComponent().path,
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        var merged: [String] = []
        for p in extra + existing where !p.isEmpty && !merged.contains(p) {
            merged.append(p)
        }
        env["PATH"] = merged.joined(separator: ":")
        env["NO_COLOR"] = "1"
        return env
    }
}
