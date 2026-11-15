import SwiftUI
import ReaderCore

struct SidebarView: View {
    @Bindable var reader: ReaderModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $reader.sidebarTab) {
                ForEach(SidebarTab.allCases) { tab in
                    Image(systemName: tab.systemImage).help(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)

            Divider()

            switch reader.sidebarTab {
            case .thumbnails:
                ThumbnailsView(model: reader)
            case .outline:
                OutlineListView(reader: reader)
            case .bookmarks:
                BookmarkListView(reader: reader)
            case .search:
                SearchListView(reader: reader, search: reader.search)
            }
        }
    }
}

private struct OutlineListView: View {
    let reader: ReaderModel

    var body: some View {
        if reader.outline.isEmpty {
            EmptyHint(text: "這份 PDF 沒有內嵌目錄")
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
            EmptyHint(text: "尚無書籤\n按 ⌘D 將目前頁面加入書籤")
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
                        Button("刪除書籤", role: .destructive) { reader.deleteBookmark(bm) }
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
            TextField("搜尋文件內容", text: $search.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { search.run() }
                .padding(8)

            if search.isSearching {
                ProgressView().padding()
                Spacer()
            } else if !search.lastQuery.isEmpty && search.results.isEmpty {
                EmptyHint(text: "找不到「\(search.lastQuery)」\n掃描頁面的文字搜尋將在 OCR 完成後提供")
            } else {
                List(search.results) { r in
                    Button { reader.reveal(r) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("第 \(r.pageLabel) 頁").font(.caption).foregroundStyle(.secondary)
                            Text(r.snippet).lineLimit(3).font(.callout)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
                if search.truncated {
                    Text("只顯示前 \(SearchModel.maxResults) 筆").font(.caption).foregroundStyle(.secondary).padding(4)
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
