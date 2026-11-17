import SwiftUI
import PDFKit
import ReaderCore

struct SidebarView: View {
    @Bindable var reader: ReaderModel
    let coordinator: TranslationCoordinator

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $reader.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage).help(tab.localizedLabel).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch reader.sidebarTab {
            case .thumbnails:
                ThumbnailListView(reader: reader, coordinator: coordinator)
            case .outline:
                OutlineListView(reader: reader)
            case .notes:
                NotesListView(reader: reader, notes: reader.notes)
            case .bookmarks:
                BookmarkListView(reader: reader)
            case .search:
                SearchListView(reader: reader, search: reader.search)
            }
        }
    }
}

extension SidebarTab {
    var localizedLabel: String {
        switch self {
        case .thumbnails: return L("縮圖", "Thumbnails")
        case .outline: return L("目錄", "Contents")
        case .notes: return L("筆記", "Notes")
        case .bookmarks: return L("書籤", "Bookmarks")
        case .search: return L("搜尋", "Search")
        }
    }
}

// MARK: - 縮圖（含翻譯狀態標記）

/// 背景產生縮圖。使用獨立的文件實例（PDFDocument 非執行緒安全）。
actor ThumbnailRenderer {
    private let document: PDFDocument?
    private var cache: [Int: CGImage] = [:]
    private var order: [Int] = []

    init(url: URL) {
        document = PDFDocument(url: url)
    }

    func image(index: Int, width: CGFloat) -> CGImage? {
        if let hit = cache[index] { return hit }
        guard let page = document?.page(at: index), let ref = page.pageRef else { return nil }
        let geometry = PageGeometry(cropBox: page.bounds(for: .cropBox), rotation: page.rotation)
        let size = geometry.displaySize
        guard size.width > 0 else { return nil }
        let scale = width / size.width
        let w = Int(width), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .medium
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(geometry.pageToDisplay)
        ctx.drawPDFPage(ref)
        let image = ctx.makeImage()
        if let image {
            cache[index] = image
            order.append(index)
            if order.count > 400 { cache.removeValue(forKey: order.removeFirst()) }
        }
        return image
    }
}

private struct ThumbnailListView: View {
    let reader: ReaderModel
    let coordinator: TranslationCoordinator
    @State private var renderer: ThumbnailRenderer?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(0..<reader.pageCount, id: \.self) { index in
                        ThumbnailCell(index: index, reader: reader, coordinator: coordinator, renderer: renderer)
                            .id(index)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .onAppear {
                if renderer == nil { renderer = ThumbnailRenderer(url: reader.url) }
                proxy.scrollTo(reader.currentPageIndex, anchor: .center)
            }
            .onChange(of: reader.currentPageIndex) { _, new in
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
    }
}

private struct ThumbnailCell: View {
    let index: Int
    let reader: ReaderModel
    let coordinator: TranslationCoordinator
    let renderer: ThumbnailRenderer?
    @State private var image: CGImage?

    private var isCurrent: Bool { reader.visiblePageIndicesForSidebar.contains(index) }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color(nsColor: .quaternaryLabelColor))
                            .aspectRatio(0.72, contentMode: .fit)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2.5)
                        .padding(-3)
                )

                TranslationBadge(status: coordinator.status[index],
                                 done: coordinator.completedPages.contains(index))
                    .padding(3)
            }
            Text(reader.pageLabel(index))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
        .frame(maxWidth: 130)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { reader.goTo(pageIndex: index) }
        .contextMenu {
            Button(L("翻譯此頁", "Translate Page")) { coordinator.translatePages([index]) }
            Button(L("重新辨識並翻譯此頁", "Re-recognize & Retranslate Page")) { coordinator.reExtract(index) }
        }
        .help(badgeHelp)
        .task(id: renderer == nil ? -1 : index) {
            guard let renderer, image == nil else { return }
            image = await renderer.image(index: index, width: 220)
        }
    }

    private var badgeHelp: String {
        if coordinator.completedPages.contains(index) { return L("第 \(index + 1) 頁：已翻譯", "Page \(index + 1): translated") }
        switch coordinator.status[index] {
        case .translating: return L("第 \(index + 1) 頁：翻譯中", "Page \(index + 1): translating")
        case .queued: return L("第 \(index + 1) 頁：等待翻譯", "Page \(index + 1): queued")
        case .failed(let m): return L("第 \(index + 1) 頁：翻譯失敗－", "Page \(index + 1): failed — ") + m
        default: return L("第 \(index + 1) 頁", "Page \(index + 1)")
        }
    }
}

/// 縮圖右下角的小標記。未翻譯的頁面不顯示，避免干擾。
private struct TranslationBadge: View {
    let status: PageStatus?
    let done: Bool

    var body: some View {
        Group {
            if done {
                Image(systemName: "translate")
                    .font(.system(size: 7.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 14, height: 14)
                    .background(RoundedRectangle(cornerRadius: 3.5).fill(Color.accentColor.opacity(0.85)))
            } else {
                switch status {
                case .translating, .extracting:
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(.background.opacity(0.9)))
                case .queued:
                    Circle().fill(Color.secondary.opacity(0.7)).frame(width: 6, height: 6)
                        .padding(4)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .frame(width: 14, height: 14)
                        .background(RoundedRectangle(cornerRadius: 3.5).fill(.background.opacity(0.9)))
                default:
                    EmptyView()
                }
            }
        }
        .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
    }
}

// MARK: - 目錄、書籤、搜尋

private struct OutlineListView: View {
    let reader: ReaderModel

    var body: some View {
        if reader.outline.isEmpty {
            EmptyHint(text: L("這份 PDF 沒有內嵌目錄", "This PDF has no table of contents"))
        } else {
            List(reader.outline, children: \.children) { item in
                Button {
                    if let p = item.pageIndex { reader.goTo(pageIndex: p) }
                } label: {
                    HStack {
                        Text(item.title).lineLimit(2)
                        Spacer()
                        if let p = item.pageIndex {
                            Text("\(p + 1)").foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        }
    }
}

private struct BookmarkListView: View {
    let reader: ReaderModel

    var body: some View {
        if reader.bookmarks.isEmpty {
            EmptyHint(text: L("尚無書籤\n按 ⌘D 將目前頁面加入書籤", "No bookmarks yet\nPress ⌘D to bookmark the current page"))
        } else {
            List {
                ForEach(reader.bookmarks, id: \.self) { bm in
                    Button {
                        reader.goTo(pageIndex: bm.pageIndex)
                    } label: {
                        HStack {
                            Image(systemName: bm.pageIndex == reader.currentPageIndex ? "bookmark.fill" : "bookmark")
                                .foregroundStyle(Color.accentColor)
                            Text(bm.title)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L("刪除書籤", "Delete Bookmark"), role: .destructive) { reader.deleteBookmark(bm) }
                    }
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct SearchListView: View {
    let reader: ReaderModel
    @Bindable var search: SearchModel

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("搜尋文件內容", "Search document"), text: $search.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search.run() }
                .padding(8)

            if search.isSearching {
                ProgressView().padding()
                Spacer()
            } else if !search.lastQuery.isEmpty && search.results.isEmpty {
                EmptyHint(text: L("找不到「\(search.lastQuery)」\n掃描頁面需先辨識文字（翻到該頁或翻譯後即可搜尋）",
                                  "No results for “\(search.lastQuery)”\nScanned pages become searchable after text recognition"))
            } else {
                List(search.results) { r in
                    Button { reader.reveal(r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L("第 \(r.pageLabel) 頁", "Page \(r.pageLabel)")).font(.caption).foregroundStyle(.secondary)
                            Text(r.snippet).lineLimit(3).font(.callout)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
                if search.truncated {
                    Text(L("只顯示前 \(SearchModel.maxResults) 筆", "Showing first \(SearchModel.maxResults) results"))
                        .font(.caption).foregroundStyle(.secondary).padding(4)
                }
            }
        }
    }
}

private struct EmptyHint: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .font(.callout)
                .padding()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
