import Foundation
import CryptoKit

/// 快速文件指紋：檔案大小 + 頭尾各 1MB 的 SHA-256。
/// 大型 PDF（數百 MB）也能在毫秒級完成，且重新命名／搬移不影響 ID。
public enum DocumentFingerprint {
    public static let chunkSize = 1 << 20

    public static func compute(url: URL) throws -> (id: String, fileSize: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(bufferPointer: $0) }

        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: chunkSize) {
            hasher.update(data: head)
        }
        if size > UInt64(chunkSize * 2) {
            try handle.seek(toOffset: size - UInt64(chunkSize))
            if let tail = try handle.read(upToCount: chunkSize) {
                hasher.update(data: tail)
            }
        } else if size > UInt64(chunkSize) {
            try handle.seek(toOffset: UInt64(chunkSize))
            if let rest = try handle.readToEnd() {
                hasher.update(data: rest)
            }
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (String(digest.prefix(32)), Int64(size))
    }

    /// 文字內容雜湊（翻譯快取失效判斷用）。
    public static func textHash(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(24).description
    }
}
