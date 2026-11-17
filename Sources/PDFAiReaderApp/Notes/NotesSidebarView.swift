import SwiftUI
import ReaderCore

/// 側邊欄「筆記」：目前頁（或全部）的便利貼、無位置筆記與螢光標記。
struct NotesListView: View {
    let reader: ReaderModel
    @Bindable var notes: NotesController
    @AppStorage("notesSidebar.showAll") private var showAll = false

    private var pages: [Int] {
        if showAll {
            return Set(notes.notes.map(\.pageIndex)).union(notes.highlights.map(\.pageIndex)).sorted()
        }
        let visible = reader.visiblePageIndicesForSidebar
        return (visible.isEmpty ? [reader.currentPageIndex] : visible).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $showAll) {
                Text(L("本頁", "This Page")).tag(false)
                Text(L("全部", "All")).tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        let pageList = pages
                        let hasContent = pageList.contains { !notes.notes(page: $0).isEmpty || !notes.highlights(page: $0).isEmpty }
                        if !hasContent {
                            EmptyNotesView(showAll: showAll)
                        }
                        ForEach(pageList, id: \.self) { page in
                            let pageNotes = notes.notes(page: page)
                            let pageHighlights = notes.highlights(page: page)
                            if !pageNotes.isEmpty || !pageHighlights.isEmpty {
                                Button {
                                    reader.goTo(pageIndex: page)
                                } label: {
                                    Text(pageTitle(page))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.top, 4)
                                ForEach(pageNotes) { note in
                                    NoteCard(note: note, notes: notes, reader: reader).id(note.id)
                                }
                                if !pageNotes.isEmpty { NoteDropTail(page: page, notes: notes).padding(.top, -8) }
                                ForEach(pageHighlights) { h in
                                    HighlightRow(highlight: h, notes: notes)
                                }
                            }
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                // 空白處：按一下取消選取與輸入；右鍵新增筆記、顯示／隱藏
                .background(
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { deselectAll() }
                        .contextMenu { blankMenu }
                )
                .onChange(of: notes.focusedNoteID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                }
            }

            Divider()
            HStack(spacing: 14) {
                // 下方空白處也可以取消選取
                Button { reader.addUnplacedNote() } label: { Image(systemName: "square.and.pencil") }
                    .accessibilityLabel(L("新增筆記", "Add Note"))
                    .help(L("新增筆記（不放在頁面上）", "Add a note (not placed on the page)"))
                Spacer()
                Button { notes.toggleVisible() } label: {
                    Image(systemName: notes.isVisible ? "eye" : "eye.slash")
                }
                .accessibilityLabel(notes.isVisible ? L("隱藏便利貼", "Hide Sticky Notes") : L("顯示便利貼", "Show Sticky Notes"))
                .help(notes.isVisible ? L("隱藏頁面上的便利貼（N）", "Hide sticky notes on pages (N)")
                                      : L("顯示頁面上的便利貼（N）", "Show sticky notes on pages (N)"))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 14))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }
}

extension NotesListView {
    /// 頁碼與狀態列一致（第幾頁＝PDF 的實際頁序）；PDF 自帶的書頁編號不同時附在後面。
    func pageTitle(_ page: Int) -> String {
        let n = page + 1
        let label = reader.pageLabel(page)
        if label != "\(n)", !label.isEmpty {
            return L("第 \(n) 頁（書頁 \(label)）", "Page \(n) (printed \(label))")
        }
        return L("第 \(n) 頁", "Page \(n)")
    }

    @ViewBuilder var blankMenu: some View {
        Button(L("新增筆記（只在側邊欄）", "Add Note (Sidebar Only)")) { reader.addUnplacedNote() }
        Button(notes.isVisible ? L("隱藏頁面上的便利貼（N）", "Hide Sticky Notes on Pages (N)")
                               : L("顯示頁面上的便利貼（N）", "Show Sticky Notes on Pages (N)")) { notes.toggleVisible() }
    }

    func deselectAll() {
        notes.focusedNoteID = nil
        notes.sidebarEditingID = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

private struct EmptyNotesView: View {
    let showAll: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "note.text")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.tertiary)
            Text(showAll ? L("這份文件還沒有筆記", "No notes in this document yet")
                         : L("這一頁還沒有筆記", "No notes on this page yet"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(L("在頁面上按右鍵可新增便利貼；選取文字可用螢光筆標記。",
                   "Right-click a page to add a sticky note; select text to highlight it."))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 8)
    }
}

/// 一張筆記卡片。
/// - 按一下：頁面上的便利貼跳過去；無位置筆記選取
/// - 按兩下：直接在卡片裡編輯（頁面上的便利貼也可以）
/// - 右鍵：顏色、字體、放到頁面上／移到側邊欄、刪除
/// - 拖曳：調整順序；無位置筆記拖到頁面上就放在那裡
private struct NoteCard: View {
    let note: StickyNote
    let notes: NotesController
    let reader: ReaderModel
    @State private var hovering = false
    @State private var dropTargeted = false
    @FocusState private var focus: Field?

    private enum Field { case title, body }
    private var editing: Bool { notes.sidebarEditingID == note.id }

    private var textColor: Color { Color(nsColor: note.color.text) }
    private var secondary: Color { Color(nsColor: note.color.secondaryText) }
    private var bodyFont: Font { Font(NoteFonts.font(family: note.fontFamily, size: 12.5)) }
    private var titleFont: Font { Font(NoteFonts.font(family: note.fontFamily, size: 12.5, bold: true)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if editing {
                TextField(L("標題（選填）", "Title (optional)"), text: Binding(
                    get: { notes.note(id: note.id)?.title ?? "" },
                    set: { v in notes.update(note.id) { $0.title = v } }))
                    .textFieldStyle(.plain)
                    .font(titleFont)
                    .focused($focus, equals: .title)
                    .onSubmit { focus = .body }
                TextField(L("寫點什麼…", "Write something…"), text: Binding(
                    get: { notes.note(id: note.id)?.body ?? "" },
                    set: { v in notes.update(note.id) { $0.body = v } }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(bodyFont)
                    .lineLimit(2...16)
                    .focused($focus, equals: .body)
                    .onKeyPress(.escape) { endEditing(); return .handled }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if note.hasTitle {
                        Text(note.trimmedTitle).font(titleFont).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: note.isPlaced ? "pin.fill" : "sidebar.left")
                        .font(.system(size: 9))
                        .foregroundStyle(secondary)
                        .help(note.isPlaced ? L("在頁面上", "On the page") : L("只在側邊欄", "Sidebar only"))
                }
                Text(note.body.isEmpty ? L("（空白，按兩下輸入）", "(Empty — double-click to write)") : note.body)
                    .font(bodyFont)
                    .foregroundStyle(note.body.isEmpty ? secondary : textColor)
                    .lineLimit(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .foregroundStyle(textColor)
        .environment(\.colorScheme, note.color.isDark ? .dark : .light)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(note.color.swatch)
                .shadow(color: .black.opacity(hovering ? 0.16 : 0.08), radius: hovering ? 4 : 2, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(editing || notes.focusedNoteID == note.id ? Color.accentColor.opacity(0.7) : note.color.swatchBorder,
                              lineWidth: editing || notes.focusedNoteID == note.id ? 1.5 : 0.5)
        )
        // 拖到這張卡片上：插在它前面（顯示一條插入線）
        .overlay(alignment: .top) {
            if dropTargeted {
                Capsule().fill(Color.accentColor).frame(height: 3).offset(y: -7)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // 單擊立即反應（不等雙擊判定），雙擊再進入編輯
        .onTapGesture(count: 2) { beginEditing() }
        .simultaneousGesture(TapGesture(count: 1).onEnded { singleClick() })
        .draggable(ReaderPDFView.noteDragPrefix + note.id) {
            // 拖曳時的預覽
            Text(note.summary.isEmpty ? L("便利貼", "Note") : note.summary)
                .font(.callout)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(note.color.swatch))
                .foregroundStyle(textColor)
        }
        .dropDestination(for: String.self) { items, _ in
            guard let s = items.first, s.hasPrefix(ReaderPDFView.noteDragPrefix) else { return false }
            let id = String(s.dropFirst(ReaderPDFView.noteDragPrefix.count))
            guard id != note.id else { return false }
            withAnimation(.easeInOut(duration: 0.15)) { notes.moveNote(id, before: note.id, page: note.pageIndex) }
            return true
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: focus) { _, f in if f == nil, editing { notes.sidebarEditingID = nil } }
        .onChange(of: notes.sidebarEditingID) { _, id in if id != note.id, focus != nil { focus = nil } }
        .onAppear {
            // 剛新增的無位置筆記：直接開始輸入
            if !note.isPlaced, notes.focusedNoteID == note.id, note.body.isEmpty, note.title.isEmpty { beginEditing() }
        }
        .contextMenu {
            Button(L("前往該筆記頁面", "Go to Note's Page")) { notes.revealNote(note.id) }
            Divider()
            Button(L("編輯", "Edit")) { beginEditing() }
            Menu(L("顏色", "Color")) {
                ForEach(NoteColor.allCases) { c in
                    Button((note.color == c ? "✓ " : "　") + c.localizedName) { notes.update(note.id) { $0.color = c } }
                }
            }
            Menu(L("字體", "Font")) {
                ForEach(NoteFonts.installed) { f in
                    Button((note.fontFamily == f.family ? "✓ " : "　") + f.localizedName) {
                        notes.update(note.id) { $0.fontFamily = f.family }
                    }
                }
            }
            Divider()
            Button(note.isPlaced ? L("移到側邊欄（不放在頁面上）", "Move to Sidebar (Unplaced)")
                                 : L("放到頁面上", "Place on Page")) {
                notes.togglePlacement(note.id)
            }
            Button(L("刪除", "Delete"), role: .destructive) { notes.delete(note.id) }
        }
        .help(note.isPlaced ? L("按兩下編輯，可拖曳排序；右鍵可前往該筆記頁面", "Double-click to edit, drag to reorder; right-click to go to its page")
                            : L("按兩下編輯，可拖曳排序或拖到頁面上", "Double-click to edit; drag to reorder or onto the page"))
    }

    private func singleClick() {
        if editing { return }
        if notes.sidebarEditingID != nil { notes.sidebarEditingID = nil }
        notes.focusedNoteID = note.id
        // 頁面上的便利貼：跳到那一頁（不搶走輸入焦點）

    }

    private func beginEditing() {
        notes.sidebarEditingID = note.id
        notes.focusedNoteID = note.id
        DispatchQueue.main.async { focus = .body }
    }

    private func endEditing() {
        focus = nil
        notes.sidebarEditingID = nil
    }
}

/// 頁面清單最後的放置區：拖到這裡＝排到該頁最後。
private struct NoteDropTail: View {
    let page: Int
    let notes: NotesController
    @State private var targeted = false

    var body: some View {
        Color.clear
            .frame(height: 14)
            .overlay(alignment: .top) {
                if targeted { Capsule().fill(Color.accentColor).frame(height: 3) }
            }
            .dropDestination(for: String.self) { items, _ in
                guard let s = items.first, s.hasPrefix(ReaderPDFView.noteDragPrefix) else { return false }
                withAnimation(.easeInOut(duration: 0.15)) {
                    notes.moveNote(String(s.dropFirst(ReaderPDFView.noteDragPrefix.count)), before: nil, page: page)
                }
                return true
            } isTargeted: { targeted = $0 }
    }
}

private struct HighlightRow: View {
    let highlight: Highlight
    let notes: NotesController

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(nsColor: highlight.color.ink))
                .frame(width: 3)
            Text(highlight.text.isEmpty ? L("（螢光標記）", "(Highlight)") : highlight.text)
                .font(.callout)
                .lineLimit(3)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())

        .contextMenu {
            Button(L("前往該筆記頁面", "Go to Note's Page")) { notes.reveal(highlight: highlight.id) }
            Divider()
            ForEach(HighlightColor.allCases) { c in
                Button((highlight.color == c ? "✓ " : "　") + c.localizedName) { notes.recolorHighlight(highlight.id, c) }
            }
            Divider()
            Button(L("移除螢光標記", "Remove Highlight"), role: .destructive) { notes.removeHighlight(highlight.id) }
        }
        .help(L("右鍵可前往該筆記頁面", "Right-click to go to its page"))
    }
}
