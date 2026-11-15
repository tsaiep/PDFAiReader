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
            Label(model.isEmpty ? "預設模型" : model, systemImage: "cpu")
                .labelStyle(.titleAndIcon)
        }
        .help("選擇翻譯模型與速度／品質")
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
        Section("翻譯模型") {
            Toggle(isOn: Binding(get: { model.isEmpty }, set: { if $0 { select("") } })) {
                Text("預設（\(app.configDefaultModel ?? "Codex 設定檔")）")
            }
            ForEach(customModels, id: \.self) { m in
                Toggle(m, isOn: Binding(get: { model == m }, set: { if $0 { select(m) } }))
            }
            Button("新增其他模型…") { app.showAddModel = true }
        }
        Section("速度／品質") {
            Picker("推理強度", selection: Binding(get: { effort }, set: { setEffort($0) })) {
                Text("快速（low）").tag("low")
                Text("標準（medium）").tag("medium")
                Text("精細（high，較慢）").tag("high")
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
            Text("新增翻譯模型").font(.title2.weight(.semibold))
            Text("Codex CLI 無法列出可用模型，請輸入模型 ID（與 `codex -m` 使用的名稱相同），按「測試」實際翻譯一句確認可用。")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("模型 ID", text: $candidate)
                .textFieldStyle(.roundedBorder)
                .onChange(of: candidate) { _, _ in passed = false; result = nil }
            HStack {
                Button("測試") {
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
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("加入並使用") {
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
