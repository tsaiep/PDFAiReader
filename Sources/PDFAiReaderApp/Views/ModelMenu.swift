import SwiftUI
import ReaderCore

/// 翻譯模型與速度／品質的選單。出現在工具列「翻譯」選單、翻譯面板與設定中。
struct ModelMenu: View {
    @Environment(AppModel.self) private var app
    let reader: ReaderModel?
    @AppStorage("codexModel") private var model = ""
    @AppStorage("customModels") private var customModelsRaw = ""
    @AppStorage("reasoningEffort") private var effort = "low"

    var body: some View {
        Menu {
            ModelMenuItems(reader: reader)
        } label: {
            Label(model.isEmpty ? L("預設模型", "Default Model") : model, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .help(L("選擇翻譯模型與速度／品質", "Choose the translation model and speed/quality"))
    }
}

/// 可嵌入其他選單的模型選項。
struct ModelMenuItems: View {
    @Environment(AppModel.self) private var app
    let reader: ReaderModel?
    @AppStorage("codexModel") private var model = ""
    @AppStorage("customModels") private var customModelsRaw = ""
    @AppStorage("reasoningEffort") private var effort = "low"

    private var customModels: [String] {
        customModelsRaw.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    var body: some View {
        Section(L("翻譯模型", "Model")) {
            Toggle(isOn: Binding(get: { model.isEmpty }, set: { if $0 { select("") } })) {
                Text(L("預設", "Default") + "（\(app.configDefaultModel ?? L("Codex 設定檔", "Codex config"))）")
            }
            ForEach(customModels, id: \.self) { m in
                Toggle(m, isOn: Binding(get: { model == m }, set: { if $0 { select(m) } }))
            }
            Button(L("新增其他模型…", "Add Another Model…")) { app.showAddModel = true }
        }
        Section(L("速度／品質", "Speed / Quality")) {
            Picker(L("推理強度", "Reasoning effort"), selection: Binding(get: { effort }, set: { setEffort($0) })) {
                Text(L("快速（low）", "Fast (low)")).tag("low")
                Text(L("標準（medium）", "Standard (medium)")).tag("medium")
                Text(L("精細（high，較慢）", "Thorough (high, slower)")).tag("high")
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }

    private func select(_ m: String) {
        model = m
        Task { await app.applyStoredCodexSettings() }
    }

    private func setEffort(_ e: String) {
        effort = e
        Task { await app.applyStoredCodexSettings() }
    }
}

/// 新增模型：輸入模型 ID、實際測試一次，成功後加入清單並使用。
struct AddModelSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @AppStorage("codexModel") private var model = ""
    @AppStorage("customModels") private var customModelsRaw = ""
    @State private var candidate = ""
    @State private var result: String?
    @State private var passed = false
    @State private var testing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("新增翻譯模型", "Add Translation Model")).font(.title2.weight(.semibold))
            Text(L("Codex CLI 無法列出可用模型，請輸入模型 ID（與 `codex -m` 使用的名稱相同），按「測試」實際翻譯一句確認可用。", "Codex CLI can’t list models. Enter a model ID (the same name you’d pass to `codex -m`) and press Test to translate one sentence."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField(L("模型 ID", "Model ID"), text: $candidate)
                .textFieldStyle(.roundedBorder)
                .onChange(of: candidate) { _, _ in passed = false; result = nil }
            HStack {
                Button(L("測試", "Test")) {
                    testing = true
                    Task {
                        let r = await app.testModel(candidate.trimmingCharacters(in: .whitespaces))
                        result = r.message
                        passed = r.ok
                        testing = false
                    }
                }
                .disabled(candidate.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                if testing { ProgressView().controlSize(.small) }
                if let result {
                    Text(result).font(.callout).foregroundStyle(passed ? .green : .orange)
                        .lineLimit(3).textSelection(.enabled)
                }
            }
            HStack {
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("加入並使用", "Add and Use")) {
                    let m = candidate.trimmingCharacters(in: .whitespaces)
                    var list = customModelsRaw.split(separator: "\n").map(String.init)
                    if !list.contains(m) { list.append(m) }
                    customModelsRaw = list.joined(separator: "\n")
                    model = m
                    Task { await app.applyStoredCodexSettings() }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!passed)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
