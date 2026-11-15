import SwiftUI
import ReaderCore

struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label(L("一般", "General"), systemImage: "gearshape") }
            ReadingSettingsView()
                .tabItem { Label(L("閱讀", "Reading"), systemImage: "book") }
            TranslationSettingsView()
                .tabItem { Label(L("翻譯", "Translation"), systemImage: "character.book.closed") }
        }
        .frame(width: 580, height: 520)
        .sheet(isPresented: Bindable(app).showAddModel) { AddModelSheet() }
    }
}

private struct GeneralSettingsView: View {
    @Bindable private var language = UILanguageStore.shared

    var body: some View {
        Form {
            Section {
                Picker(L("介面語言", "Interface Language"), selection: $language.language) {
                    ForEach(UILanguage.allCases) { Text($0.nativeName).tag($0) }
                }
            } footer: {
                Text(L("介面語言與翻譯的目標語言是分開的設定。", "The interface language is separate from the translation target language."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct ReadingSettingsView: View {
    @AppStorage("pageTurnStyle") private var pageTurnStyle = PageTurnStyle.curl.rawValue
    @AppStorage("prerenderPages") private var prerenderPages = true

    var body: some View {
        Form {
            Section(L("翻頁", "Page Turning")) {
                Picker(L("翻頁動畫", "Animation"), selection: $pageTurnStyle) {
                    ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle(L("預先渲染前後頁（翻頁更即時）", "Pre-render neighboring pages (more responsive turns)"),
                       isOn: $prerenderPages)
                Text(L("單頁／雙頁模式：← → ↑ ↓、空白鍵、Page Up/Down、觸控板雙指上下左右滑動都會左右翻書；翻書效果會跟著手指移動，放開後完成或回彈。連續模式：上下捲動，← → 平滑捲到上一頁／下一頁。",
                       "Single/two-page modes: ← → ↑ ↓, Space, Page Up/Down and two-finger swipes in any direction all turn pages like a book; the page curl follows your fingers and completes or springs back on release. Continuous mode scrolls vertically; ← → glide to the previous/next page."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranslationSettingsView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("codexPath") private var codexPath = ""
    @AppStorage("codexModel") private var codexModel = ""
    @AppStorage("autoTranslate") private var autoTranslate = true
    @AppStorage("prefetchPageCount") private var prefetchPageCount = 5

    var body: some View {
        Form {
            Section(L("譯文", "Translation")) {
                Picker(L("目標語言", "Translate to"), selection: Binding(get: { app.targetLanguage },
                                                                       set: { app.setTargetLanguage($0) })) {
                    ForEach(TargetLanguage.allCases) { Text($0.menuName).tag($0) }
                }
                Picker(L("譯文字體", "Font"), selection: Binding(get: { app.fontFamily }, set: { app.setFontFamily($0) })) {
                    ForEach(Prefs.installedFontChoices(for: app.targetLanguage)) { choice in
                        Text(choice.localizedName).font(.custom(choice.family, size: 13)).tag(choice.family)
                    }
                }
                Text(previewText)
                    .font(.custom(app.fontFamily, size: 15))
                    .padding(.vertical, 2)
                Text(L("中文書翻成另一種中文（簡↔繁）時只在本機轉換字形，兩岸用語明顯不同才替換，不改句子結構，也不消耗額度。",
                       "Converting between Simplified and Traditional Chinese is done locally: only characters change (plus clearly regional words), sentences are never rewritten, and no quota is used."))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section(L("自動翻譯", "Automatic Translation")) {
                Toggle(L("閱讀時自動翻譯目前頁與後續頁面", "Translate the current and following pages while reading"),
                       isOn: $autoTranslate)
                Stepper(L("預翻譯頁數：目前頁＋\(prefetchPageCount) 頁", "Prefetch: current page + \(prefetchPageCount)"),
                        value: $prefetchPageCount, in: 0...30)
            }

            Section(L("翻譯模型", "Model")) {
                HStack {
                    Text(L("目前模型", "Current model"))
                    Spacer()
                    ModelMenu(reader: nil).fixedSize()
                }
                Button(L("新增其他模型…", "Add Another Model…")) { app.showAddModel = true }
            }

            Section {
                TextField(L("Codex 路徑", "Codex path"), text: $codexPath, prompt: Text(L("留空 = 自動偵測", "Leave empty to detect automatically")))
                TextField(L("模型 ID", "Model ID"), text: $codexModel,
                          prompt: Text(L("留空 = 使用 Codex 設定檔的預設模型", "Leave empty to use Codex’s default model")))
                HStack {
                    Button(L("檢查 Codex", "Check Codex")) {
                        Task {
                            await app.applyCodexSettings(path: codexPath, model: codexModel)
                            await app.checkCodex()
                        }
                    }
                    Button(L("測試模型", "Test Model")) {
                        Task {
                            await app.applyCodexSettings(path: codexPath, model: codexModel)
                            await app.testModel()
                        }
                    }
                    if app.isCheckingCodex || app.isTestingModel { ProgressView().controlSize(.small) }
                }
                if let status = app.codexStatus {
                    Text(status.description)
                        .foregroundStyle(status.isAvailable ? .green : .orange)
                        .font(.callout)
                }
                if let result = app.modelTestResult {
                    Text(result).font(.callout).textSelection(.enabled).lineLimit(3)
                }
            } header: {
                Text("Codex CLI")
            } footer: {
                Text(L("Codex CLI 無法列出可用模型，請手動輸入模型 ID 後按「測試模型」確認。更換模型後已翻譯的頁面保留原譯文，「重新翻譯」才會使用新模型。\n翻譯時，辨識出的文字會經由 Codex CLI 傳送到 OpenAI 處理；書頁影像不會上傳。",
                       "Codex CLI can’t list available models; enter a model ID and press Test Model. Pages already translated keep their translation after switching models; use Retranslate to apply the new model.\nRecognized text is sent to OpenAI through Codex CLI for translation; page images are never uploaded."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: codexModel) { _, _ in
            Task { await app.applyStoredCodexSettings() }
        }
    }

    private var previewText: String {
        switch app.targetLanguage {
        case .zhHantTW: return "攝影作為藝術表現手段的運用，從未像今日這般廣泛。"
        case .zhHans: return "摄影作为艺术表现手段的运用，从未像今日这般广泛。"
        case .ja: return "写真が芸術表現の手段としてこれほど広く用いられたことはない。"
        case .ko: return "사진이 예술적 표현 수단으로 이토록 널리 쓰인 적은 없었다."
        default: return "Photography has never been more widely used as a means of artistic expression."
        }
    }
}
