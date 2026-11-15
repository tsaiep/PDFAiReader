import SwiftUI
import AppKit

extension Notification.Name {
    static let openDocumentURLs = Notification.Name("PDFAiReader.openDocumentURLs")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 以 `swift run` 執行時沒有 .app bundle，需手動設為一般 App 才會出現在 Dock 並取得焦點。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Finder「打開方式」或拖到 Dock 圖示。
    func application(_ application: NSApplication, open urls: [URL]) {
        NotificationCenter.default.post(name: .openDocumentURLs, object: urls)
    }
}

@main
struct PDFAiReaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var app = AppModel()

    var body: some Scene {
        WindowGroup("AI PDF Reader") {
            ContentView()
                .environment(app)
                .frame(minWidth: 900, minHeight: 600)
        }
        .commands { ReaderCommands(app: app) }

        Settings {
            SettingsView()
                .environment(app)
        }
    }
}
