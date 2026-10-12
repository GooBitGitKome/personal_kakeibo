import SwiftUI
import UniformTypeIdentifiers
import PersonalKakeiboDomain

struct ExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, .commaSeparatedText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SettingsView: View {
    @Bindable var model: KakeiboViewModel
    @State private var budgetAmount = ""
    @State private var document: ExportDocument?
    @State private var contentType: UTType = .json
    @State private var exporting = false
    @State private var importing = false
    @State private var overwrite = false
    @State private var preview: ImportPreview?
    @State private var isWorking = false
    @State private var cloudStatus = "iCloudの状態を確認中…"
    var body: some View {
        Form {
            Section("ジャンル") { NavigationLink("ジャンル管理") { CategoryView(model: model) } }
            Section("予算・リマインダー") {
                NavigationLink("ジャンル別の日額・月額予算") { BudgetSettingsView(model: model) }
                NavigationLink("繰り返し収支") { RemindersView(model: model) }
                NavigationLink("通知設定") { NotificationSettingsView(model: model) }
            }
            Section("月間予算") {
                MonthControl(model: model)
                if let budget = model.budget, let summary = model.summary {
                    Text("予算 " + yen(budget.amount))
                    Text("使用額 " + yen(summary.expense))
                    Text("残額 " + yen(budget.amount - summary.expense))
                    Text("使用率 " + (Double(summary.expense) / Double(budget.amount) * 100).formatted(.number.precision(.fractionLength(1))) + "%")
                    ProgressView(value: min(1, Double(summary.expense) / Double(budget.amount)))
                } else { Text("予算未設定") }
                TextField("予算額", text: $budgetAmount).keyboardType(.numberPad)
                Button("予算を保存") {
                    model.perform {
                        try model.setBudget(budgetAmount)
                        budgetAmount = ""
                    }
                }
            }
            Section("iCloud") {
                if model.duplicateWarning { Text("同期による重複を検出しました。最新の値を表示しています。重複データの変更・復元は開発者による確認が必要です。") }
                Text(cloudStatus)
                Text("未ログイン、容量不足、通信障害により同期が遅れることがあります。保存成功は端末保存を意味します。同期完了は表示していません。")
            }
            Section("ファイル") {
                if isWorking { ProgressView("ファイル処理中…") }
                Button("CSVを出力") { export(csv: true) }
                Button("JSONバックアップ") { export(csv: false) }
                Toggle("同じIDの内容を上書きする", isOn: $overwrite)
                Text("追加では異なる内容の同じIDを拒否します。上書きでも、バックアップにない既存データは保持します。更新前にJSONバックアップを保存してください。")
                Button("JSONを選んで復元プレビュー") { importing = true }
                if let preview {
                    Text("追加 \(preview.additions)件・更新 \(preview.updates)件")
                    Button("確認して復元", role: .destructive) {
                        model.perform {
                            try model.restore(preview)
                            self.preview = nil; model.message = "復元しました（端末保存）"
                        }
                    }
                    Button("復元をキャンセル", role: .cancel) { self.preview = nil }
                }
                if let message = model.message { Text(message) }
            }.disabled(isWorking)
            Section("アプリ情報") { Text("Personal Kakeibo 1.0"); Text("個人用・円建て家計簿。集計基準は日本時間です。") }
        }.dismissKeyboardOnSwipe().navigationTitle("設定")
            .task { cloudStatus = await CloudAccount.description() }
            .onChange(of: overwrite) { _, _ in preview = nil }
            .fileExporter(isPresented: $exporting, document: document, contentType: contentType, defaultFilename: contentType == .json ? "kakeibo-backup" : "kakeibo-transactions") { result in
                switch result { case .success: model.message = "出力しました"; case .failure(let error): model.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                Task {
                    isWorking = true; defer { isWorking = false }
                    do { preview = try await model.previewImport(result.get(), overwrite: overwrite) }
                    catch { preview = nil; model.error = error.localizedDescription }
                }
            }
    }
    private func export(csv: Bool) {
        Task {
            isWorking = true; defer { isWorking = false }
            do {
                document = ExportDocument(data: try await model.exportData(csv: csv))
                contentType = csv ? .commaSeparatedText : .json; exporting = true
            } catch { model.error = error.localizedDescription }
        }
    }
}
struct CategoryView: View {
    let model: KakeiboViewModel
    @State private var name = ""
    @State private var type: TransactionType = .expense
    @State private var editing: PersonalKakeiboDomain.Category?
    @State private var editedName = ""
    var body: some View {
        List {
            Section("ジャンルを追加") {
                Picker("区分", selection: $type) { Text("支出").tag(TransactionType.expense); Text("収入").tag(TransactionType.income) }
                TextField("名前（40文字まで）", text: $name)
                Button("追加") { model.perform {
                    try model.addCategory(name, type: type); name = ""
                } }
            }
            ForEach([TransactionType.expense, .income], id: \.self) { kind in
                Section(kind == .expense ? "支出" : "収入") {
                    let categories = model.categories.filter { $0.type == kind }.sorted { $0.sortOrder < $1.sortOrder }
                    ForEach(categories) { category in
                        VStack(alignment: .leading) {
                            Button(category.name + (category.isArchived ? "（アーカイブ）" : "")) { editing = category; editedName = category.name }
                            Button(category.isArchived ? "アーカイブ解除" : "アーカイブ") { model.perform { try model.archiveCategory(category) } }
                                .font(.caption).frame(minHeight: 44)
                        }
                    }.onMove { indices, destination in
                        var ids = categories.map(\.id); ids.move(fromOffsets: indices, toOffset: destination)
                        model.perform { try model.reorderCategories(ids) }
                    }
                }
            }
        }.dismissKeyboardOnSwipe().navigationTitle("ジャンル管理").toolbar { EditButton() }
            .alert("ジャンル名を変更", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("名前", text: $editedName)
                Button("保存") { if let value = editing {
                    model.perform { try model.renameCategory(value, name: editedName) }
                }; editing = nil }
                Button("キャンセル", role: .cancel) { editing = nil }
            }
    }
}
