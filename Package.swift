// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PDFAiReader",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PDFAiReader", targets: ["PDFAiReaderApp"]),
        .library(name: "ReaderCore", targets: ["ReaderCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        // 純邏輯：模型、排程規則、翻譯介面、結果驗證。不依賴 UI。
        .target(name: "ReaderCore"),

        // SQLite 持久化（GRDB）。
        .target(
            name: "ReaderStore",
            dependencies: [
                "ReaderCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),

        // Codex CLI 翻譯引擎（TranslationEngine 的其中一個實作）。
        .target(name: "TranslationCodex", dependencies: ["ReaderCore"]),

        // PDFKit / Vision / CoreText 服務：文字擷取（內嵌文字層＋OCR）、翻譯 PDF 匯出。
        .target(name: "ReaderServices", dependencies: ["ReaderCore"]),

        // macOS App：SwiftUI + PDFKit。
        // UI 層先用 Swift 5 語言模式，減少 AppKit/PDFKit 互通的並行檢查摩擦；
        // 其餘模組使用 Swift 6 嚴格並行檢查。
        .executableTarget(
            name: "PDFAiReaderApp",
            dependencies: ["ReaderCore", "ReaderStore", "TranslationCodex", "ReaderServices"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(name: "ReaderCoreTests", dependencies: ["ReaderCore"]),
        .testTarget(name: "ReaderStoreTests", dependencies: ["ReaderStore"]),
        .testTarget(name: "TranslationCodexTests", dependencies: ["TranslationCodex"]),
        .testTarget(name: "ReaderServicesTests", dependencies: ["ReaderServices", "ReaderCore"]),
        .testTarget(name: "PipelineE2ETests",
                    dependencies: ["PDFAiReaderApp", "ReaderCore", "ReaderStore", "ReaderServices", "TranslationCodex"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
