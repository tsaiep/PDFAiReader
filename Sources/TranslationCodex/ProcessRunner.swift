import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool
    public var cancelled: Bool
    public var duration: TimeInterval

    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

/// 執行外部程序：stdin 輸入、逾時、Task 取消時終止程序。
public enum ProcessRunner {
    public static func run(executable: URL,
                           arguments: [String],
                           environment: [String: String]? = nil,
                           currentDirectory: URL? = nil,
                           stdin: Data? = nil,
                           timeout: TimeInterval = 120) async throws -> ProcessResult {
        let box = ProcessBox()
        let process = box.process
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = box.outPipe
        process.standardError = box.errPipe
        process.standardInput = box.inPipe

        let start = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                let group = DispatchGroup()

                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = box.outPipe.fileHandleForReading.readDataToEndOfFile()
                    box.withLock { box.stdoutData = data }
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let data = box.errPipe.fileHandleForReading.readDataToEndOfFile()
                    box.withLock { box.stderrData = data }
                    group.leave()
                }
                group.enter()
                process.terminationHandler = { _ in group.leave() }

                do {
                    try process.run()
                } catch {
                    // 程序沒啟動：結束讀取執行緒後回報錯誤。
                    try? box.outPipe.fileHandleForWriting.close()
                    try? box.errPipe.fileHandleForWriting.close()
                    continuation.resume(throwing: error)
                    return
                }

                let input = stdin
                DispatchQueue.global(qos: .userInitiated).async {
                    if let input, !input.isEmpty {
                        try? box.inPipe.fileHandleForWriting.write(contentsOf: input)
                    }
                    try? box.inPipe.fileHandleForWriting.close()
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if box.process.isRunning {
                        box.withLock { box.timedOut = true }
                        box.process.terminate()
                    }
                }

                group.notify(queue: .global()) {
                    let result = box.withLock {
                        ProcessResult(exitCode: box.process.terminationStatus,
                                      stdout: box.stdoutData,
                                      stderr: box.stderrData,
                                      timedOut: box.timedOut,
                                      cancelled: box.cancelled,
                                      duration: Date().timeIntervalSince(start))
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            box.withLock { box.cancelled = true }
            if box.process.isRunning { box.process.terminate() }
        }
    }
}

/// Process 與 Pipe 不是 Sendable；以鎖保護可變狀態後跨執行緒共用。
private final class ProcessBox: @unchecked Sendable {
    let process = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()
    let inPipe = Pipe()
    private let lock = NSLock()
    var stdoutData = Data()
    var stderrData = Data()
    var timedOut = false
    var cancelled = false

    func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
