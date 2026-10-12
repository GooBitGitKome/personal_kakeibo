import SwiftUI
import Charts
import UniformTypeIdentifiers
import PersonalKakeiboDomain

struct ContentView: View {
    @Bindable var model: KakeiboViewModel
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $model.selectedTab) {
            NavigationStack { EntryView(model: model) }.tag(0).tabItem { Label("入力", systemImage: "plus.circle") }
            NavigationStack { HistoryView(model: model) }.tag(1).tabItem { Label("履歴", systemImage: "list.bullet") }
            NavigationStack { AnalyticsView(model: model) }.tag(2).tabItem { Label("集計", systemImage: "chart.pie") }
            NavigationStack { RemindersView(model: model) }.tag(3).tabItem { Label("リマインダー", systemImage: "bell") }
            NavigationStack { SettingsView(model: model) }.tag(4).tabItem { Label("設定", systemImage: "gear") }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { model.refresh() } }
        .alert("操作できませんでした", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("閉じる") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
}
struct MonthControl: View {
    let model: KakeiboViewModel
    @State private var choosingMonth = false
    @State private var selectedDate = Date()
    var body: some View {
        HStack {
            Button { model.moveMonth(-1) } label: { Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("前の月")
            Spacer()
            Button {
                selectedDate = model.month.start
                choosingMonth = true
            } label: {
                Text(model.month.key).font(.headline).frame(minHeight: 44)
            }.accessibilityLabel("年月を選択、" + model.month.key)
            Spacer()
            Button { model.moveMonth(1) } label: { Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("次の月")
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $choosingMonth) {
            NavigationStack {
                VStack {
                    TransactionCalendar(date: $selectedDate, recordedDates: [], selectsVisibleMonth: true)
                    Text("カレンダーの年月を押すと、年と月を選択できます。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding()
                .navigationTitle("年月を選択")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { choosingMonth = false } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完了") { model.selectMonth(selectedDate); choosingMonth = false }
                    }
                }
            }.presentationDetents([.large])
        }
    }
}
struct EntryView: View {
    @Bindable var model: KakeiboViewModel
    @FocusState private var memoFocused: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Picker("収支区分", selection: $model.type) { Text("支出").tag(TransactionType.expense); Text("収入").tag(TransactionType.income) }.pickerStyle(.segmented)
                    .onChange(of: model.type) { _, _ in model.selectDefaultCategory() }
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Text(model.amount.isEmpty ? "0円" : model.amount + "円").font(.largeTitle).minimumScaleFactor(0.5).accessibilityLabel("入力金額 " + (model.amount.isEmpty ? "0" : model.amount) + "円")
                        Button { model.clearAmount() } label: {
                            Image(systemName: "xmark.circle").font(.title2).frame(width: 44, height: 44)
                        }.accessibilityLabel("金額を全消去").disabled(model.amount.isEmpty)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3)) {
                        ForEach(["1","2","3","4","5","6","7","8","9","00","0","⌫"], id: \.self) { digit in
                            Button {
                                model.message = nil
                                if digit == "⌫" { if !model.amount.isEmpty { model.amount.removeLast() } }
                                else { model.appendAmount(digit) }
                            } label: { Text(digit).font(.title2).frame(maxWidth: .infinity, minHeight: 52) }.buttonStyle(.bordered)
                                .accessibilityLabel(digit == "⌫" ? "1桁削除" : digit == "00" ? "ゼロを2桁入力" : digit)
                        }
                    }
                }
                if model.choices.isEmpty { Text("設定でジャンルを追加してください。") }
                else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ジャンル").font(.headline)
                        CategoryButtons(categories: model.choices, selection: $model.categoryId,
                            defaultId: model.preferences.defaultCategory(for: model.type), setDefault: model.setDefaultCategory)
                        Text("長押しで起動時の初期ジャンルに設定").font(.caption).foregroundStyle(.secondary)
                    }
                }
                RecordedDatePicker(date: $model.date, transactions: model.transactions)
                TextField("メモ（任意・1,000文字まで）", text: $model.memo, axis: .vertical).textFieldStyle(.roundedBorder).focused($memoFocused)
                Button(model.isSaving ? "保存中…" : "保存") { memoFocused = false; model.save() }.buttonStyle(.borderedProminent).frame(minHeight: 44)
                    .disabled(model.isSaving || model.amount.isEmpty || model.categoryId == nil)
                if let message = model.message { Text(message).foregroundStyle(.secondary) }
            }.padding().frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
        }.dismissKeyboardOnSwipe().navigationTitle("収支を入力")
    }
}
struct HistoryView: View {
    @Bindable var model: KakeiboViewModel
    @State private var filter: UUID?
    @State private var editing: PersonalKakeiboDomain.Transaction?
    @State private var deleting: PersonalKakeiboDomain.Transaction?
    var rows: [PersonalKakeiboDomain.Transaction] { model.monthly.filter { filter == nil || $0.categoryId == filter } }
    var body: some View {
        List {
            MonthControl(model: model)
            if let summary = model.summary { Text("当月の総支出 " + yen(summary.expense)) }
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            Picker("ジャンルで絞り込み", selection: $filter) {
                Text("すべて").tag(Optional<UUID>.none)
                ForEach(model.categories) { Text($0.name + ($0.type == .income ? "（収入）" : "（支出）")).tag(Optional($0.id)) }
            }
            if rows.isEmpty { Text("この月の取引はありません。") }
            ForEach(rows) { entry in
                Button { editing = entry } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text((entry.type == .income ? "収入 " : "支出 ") + yen(entry.amount)).foregroundStyle(.primary)
                        Text(model.categories.first { $0.id == entry.categoryId }?.name ?? "不明なジャンル").foregroundStyle(.secondary)
                        Text(entry.occurredAt, style: .date).foregroundStyle(.secondary)
                        if !entry.memo.isEmpty { Text(entry.memo).foregroundStyle(.secondary) }
                    }
                }.swipeActions { Button("削除", role: .destructive) { deleting = entry } }
            }
        }.navigationTitle("履歴").refreshable { model.refresh() }
            .sheet(item: $editing) { EditTransactionView(model: model, entry: $0) }
            .confirmationDialog("取引を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("削除", role: .destructive) { if let entry = deleting { model.delete(entry.id) }; deleting = nil }
                Button("キャンセル", role: .cancel) { deleting = nil }
            } message: { if let entry = deleting { Text(yen(entry.amount) + "・" + (model.categories.first { $0.id == entry.categoryId }?.name ?? "")) } }
    }
}
struct EditTransactionView: View {
    let model: KakeiboViewModel
    let entry: PersonalKakeiboDomain.Transaction
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var category: UUID
    @State private var date: Date
    @State private var memo: String
    @State private var error: String?
    init(model: KakeiboViewModel, entry: PersonalKakeiboDomain.Transaction) {
        self.model = model; self.entry = entry
        _amount = State(initialValue: String(entry.amount)); _category = State(initialValue: entry.categoryId)
        _date = State(initialValue: entry.occurredAt); _memo = State(initialValue: entry.memo)
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(entry.type == .expense ? "支出" : "収入")
                TextField("金額", text: $amount).keyboardType(.numberPad)
                CategoryButtons(categories: model.categories.filter { $0.type == entry.type && (!$0.isArchived || $0.id == entry.categoryId) }.sorted { $0.sortOrder < $1.sortOrder }, selection: Binding(get: { Optional(category) }, set: { if let id = $0 { category = id } }))
                RecordedDatePicker(date: $date, transactions: model.transactions)
                TextField("メモ", text: $memo, axis: .vertical)
                if let error { Text(error).foregroundStyle(.red) }
            }.dismissKeyboardOnSwipe().navigationTitle("取引を編集").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") {
                    do { try model.update(entry, amount: amount, category: category, date: date, memo: memo); dismiss() }
                    catch { self.error = error.localizedDescription }
                } }
            }
        }
    }
}
struct AnalyticsView: View {
    let model: KakeiboViewModel
    @State private var trend: [(month: String, income: Int64, expense: Int64)] = []
    var body: some View {
        List {
            MonthControl(model: model)
            if let summary = model.summary {
                Section("月間収支") { Text("収入 " + yen(summary.income)); Text("支出 " + yen(summary.expense)); Text("収支 " + yen(summary.balance)) }
                Section("ジャンル別支出") {
                    if summary.expensesByCategory.isEmpty { Text("支出はありません。") }
                    Chart(model.categories.filter { summary.expensesByCategory[$0.id] != nil }) { category in
                        SectorMark(angle: .value("支出", Double(summary.expensesByCategory[category.id] ?? 0)))
                            .foregroundStyle(by: .value("ジャンル", category.name))
                    }.frame(height: 240).accessibilityHidden(true)
                    ForEach(model.categories.filter { summary.expensesByCategory[$0.id] != nil }) { Text($0.name + " " + yen(summary.expensesByCategory[$0.id]!)) }
                }
                Section("12か月の推移") {
                    Chart(Array(trend.enumerated()), id: \.offset) { item in
                        BarMark(x: .value("月", item.element.month), y: .value("収入", Double(item.element.income))).foregroundStyle(by: .value("区分", "収入")).position(by: .value("区分", "収入"))
                        BarMark(x: .value("月", item.element.month), y: .value("支出", Double(item.element.expense))).foregroundStyle(by: .value("区分", "支出")).position(by: .value("区分", "支出"))
                    }.frame(height: 240).accessibilityHidden(true)
                    ForEach(Array(trend.enumerated()), id: \.offset) { item in Text(item.element.month + "：収入 " + yen(item.element.income) + "／支出 " + yen(item.element.expense)) }
                }
            } else { Text("集計できません。エラーを確認して再読み込みしてください。") }
        }.navigationTitle("集計").task(id: model.month.key + String(model.transactions.count) + String(describing: model.summary)) { loadTrend() }
    }
    private func loadTrend() {
        do {
            trend = try (-11...0).map { offset in
                let month = model.month.shifted(offset)
                let summary = try MonthlySummary.calculate(model.transactions, in: month.range)
                return (month.key, summary.income, summary.expense)
            }
        } catch { trend = []; model.error = error.localizedDescription }
    }
}
