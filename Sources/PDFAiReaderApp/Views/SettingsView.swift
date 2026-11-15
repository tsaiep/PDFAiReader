import SwiftUI
import ReaderCore

struct SettingsView: View {
    var body: some View {
        TabView {
            ReadingSettingsView()
                .tabItem { Label("閱讀", systemImage: "book") }
            TranslationSettingsView()
                .tabItem { Label("翻譯", systemImage: "character.book.closed") }
        }
        .frame(width: 560, height: 400)
    }
}

private struct ReadingSettingsView: View {
    @AppStorage("pageTurnStyle") private var pageTurnStyle = PageTurnStyle.curl.rawValue
    @AppStorage("prerenderPages") private var prerenderPages = true

    var body: some View {
        Form {
            Section("翻頁") {
                Picker("翻頁動畫", selection: $pageTurnStyle) {
                    ForEach(PageTurnStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("預先渲染前後頁（掃描書翻頁更快、動畫更順）", isOn: $prerenderPages)
                Text("單頁／雙頁模式：← → 鍵、空白鍵、Page Up/Down、觸控板左右滑動翻頁。連續模式：← → 平滑捲動到上一頁／下一頁。")
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
            Section("自動翻譯") {
                Toggle("閱讀時自動翻譯目前頁與後續頁面", isOn: $autoTranslate)
                Stepper("預翻譯頁數：目前頁＋\(prefetchPageCount) 頁", value: $prefetchPageCount, in: 0...30)
            }

            Section("翻譯模型") {
                HStack {
                    Text("目前模型")
                    Spacer()
                    ModelMenu(reader: nil).fixedSize()
                }
                Button("新增其他模型…") { app.showAddModel = true }
            }

            Section {
                TextField("Codex 路徑", text: $codexPath, prompt: Text("留空 = 自動偵測"))
                TextField("模型 ID", text: $codexModel, prompt: Text("留空 = 使用 Codex 設定檔的預設模型"))
                HStack {
                    Button("檢查 Codex") {
                        Task {
                            await app.applyCodexSettings(path: codexPath, model: codexModel)
                            await app.checkCodex()
                        }
                    }
                    Button("測試模型") {
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
                Text("Codex CLI 無法列出可用模型，請手動輸入模型 ID 後按「測試模型」確認。更換模型後，已翻譯頁面會以新模型的快取為準。\n翻譯時，辨識出的文字會經由 Codex CLI 傳送到 OpenAI 處理；書頁影像不會上傳。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: Bindable(app).showAddModel) { AddModelSheet() }
        .onChange(of: codexModel) { _, new in
            Task { await app.applyCodexSettings(path: codexPath, model: new) }
        }
    }
}
