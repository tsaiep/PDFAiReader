import SwiftUI
import UniformTypeIdentifiers
import ReaderCore

struct ContentView: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTargeted = false

    var body: some View {
        Group {
            if let reader = app.reader {
                ReaderView(reader: reader)
                    .id(reader.record.id)
            } else {
                LibraryView()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "pdf" }) else { return false }
            app.open(url: url)
            return true
        } isTargeted: { isDropTargeted = $0 }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .alert("提示", isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } }
        )) {
            Button("好") { app.alertMessage = nil }
        } message: {
            Text(app.alertMessage ?? "")
        }
    }
}

struct LibraryView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                Text("AI PDF Reader")
                    .font(.title.weight(.semibold))
                Text("拖放 PDF 到這裡，或")
                    .foregroundStyle(.secondary)
                Button("開啟 PDF…") { app.presentOpenPanel() }
                    .keyboardShortcut("o")
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
            }
            .padding(.vertical, 40)

            if !app.recentDocuments.isEmpty {
                Divider()
                HStack {
                    Text("最近開啟").font(.headline)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)

                List(app.recentDocuments) { record in
                    RecentRow(record: record, missing: app.resolveURL(for: record) == nil)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { app.reopen(record) }
                        .contextMenu {
                            Button("開啟") { app.reopen(record) }
                            Button("在 Finder 中顯示") {
                                if let url = app.resolveURL(for: record) {
                                    NSWorkspace.shared.activateFileViewerSelecting([url])
                                }
                            }
                            Divider()
                            Button("從列表移除（同時刪除進度與書籤）", role: .destructive) {
                                app.removeFromRecent(record)
                            }
                        }
                }
                .listStyle(.inset)
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct RecentRow: View {
    let record: DocumentRecord
    let missing: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: missing ? "exclamationmark.triangle" : "doc.richtext")
                .foregroundStyle(missing ? Color.orange : Color.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).lineLimit(1)
                Text(missing ? "找不到檔案：\(record.path)" : record.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(record.pageCount) 頁").font(.caption)
                Text(record.lastOpenedAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}
