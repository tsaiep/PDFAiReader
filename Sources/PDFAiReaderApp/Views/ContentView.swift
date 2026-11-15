import SwiftUI
import PDFKit
import ImageIO
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
        .alert(L("提示", "Notice"), isPresented: Binding(
            get: { app.alertMessage != nil },
            set: { if !$0 { app.alertMessage = nil } }
        )) {
            Button(L("好", "OK")) { app.alertMessage = nil }
        } message: {
            Text(app.alertMessage ?? "")
        }
    }
}

/// 最近開啟：以第一頁作為封面，排成書架。
struct LibraryView: View {
    @Environment(AppModel.self) private var app
    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 168), spacing: 28, alignment: .bottom)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("最近開啟", "Recent")).font(.largeTitle.weight(.semibold))
                Spacer()
                Button {
                    app.presentOpenPanel()
                } label: {
                    Label(L("開啟 PDF…", "Open PDF…"), systemImage: "plus")
                }
                .keyboardShortcut("o")
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 16)

            if app.recentDocuments.isEmpty {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "books.vertical")
                        .font(.system(size: 52, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(L("尚無最近開啟的文件", "No recent documents")).font(.title3)
                    Text(L("開啟一份 PDF，就會出現在這裡。", "Open a PDF and it will appear here."))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 34) {
                        ForEach(app.recentDocuments) { record in
                            BookCell(record: record, missing: app.resolveURL(for: record) == nil,
                                     coverURL: app.resolveURL(for: record))
                                .onTapGesture(count: 2) { app.reopen(record) }
                                .contextMenu {
                                    Button(L("開啟", "Open")) { app.reopen(record) }
                                    Button(L("在 Finder 中顯示", "Show in Finder")) {
                                        if let url = app.resolveURL(for: record) {
                                            NSWorkspace.shared.activateFileViewerSelecting([url])
                                        }
                                    }
                                    Divider()
                                    Button(L("從列表移除（同時刪除進度、書籤與譯文）",
                                             "Remove from List (also deletes progress, bookmarks and translations)"),
                                           role: .destructive) {
                                        app.removeFromRecent(record)
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.bottom, 32)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 書架上的一本書：封面（第一頁）、書名、頁數。
private struct BookCell: View {
    let record: DocumentRecord
    let missing: Bool
    let coverURL: URL?
    @State private var cover: CGImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let cover {
                    Image(decorative: cover, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .aspectRatio(0.72, contentMode: .fit)
                        .overlay(Image(systemName: "doc.richtext").font(.title).foregroundStyle(.tertiary))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 200, alignment: .bottom)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            // 書本陰影＋書脊高光
            .overlay(alignment: .leading) {
                LinearGradient(colors: [.black.opacity(0.18), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 6)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(hovering ? 0.35 : 0.22), radius: hovering ? 9 : 5, x: 0, y: hovering ? 6 : 3)
            .scaleEffect(hovering ? 1.03 : 1, anchor: .bottom)
            .opacity(missing ? 0.45 : 1)
            .overlay(alignment: .topTrailing) {
                if missing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .padding(6)
                        .help(L("找不到檔案：", "File not found: ") + record.path)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(L("\(record.pageCount) 頁", "\(record.pageCount) pages"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 44, alignment: .top)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(record.path)
        .task(id: record.id) {
            cover = await CoverCache.shared.cover(for: record, url: coverURL)
        }
    }
}

/// 封面快取：第一頁縮成約 360 px 寬的 JPEG，存在 Application Support，下次直接讀取。
actor CoverCache {
    static let shared = CoverCache()
    private var memory: [String: CGImage] = [:]

    private var directory: URL? {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                         appropriateFor: nil, create: true) else { return nil }
        let dir = support.appendingPathComponent("PDFAiReader/covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func cover(for record: DocumentRecord, url: URL?) -> CGImage? {
        if let hit = memory[record.id] { return hit }
        let file = directory?.appendingPathComponent("\(record.id).jpg")
        if let file, let source = CGImageSourceCreateWithURL(file as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            memory[record.id] = image
            return image
        }
        guard let url, let doc = PDFDocument(url: url), let page = doc.page(at: 0), let ref = page.pageRef else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let size = geometry.displaySize
        guard size.width > 0 else { return nil }
        let width: CGFloat = 360
        let scale = width / size.width
        let w = Int(width), h = Int(size.height * scale)
        guard h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(geometry.pageToDisplay)
        ctx.drawPDFPage(ref)
        guard let image = ctx.makeImage() else { return nil }
        memory[record.id] = image
        if let file, let dest = CGImageDestinationCreateWithURL(file as CFURL, UTType.jpeg.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            CGImageDestinationFinalize(dest)
        }
        return image
    }
}
