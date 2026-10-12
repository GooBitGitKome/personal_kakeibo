import SwiftUI
import PersonalKakeiboDomain

struct RemindersView: View {
    @Bindable var model: KakeiboViewModel
    @State private var creating = false
    @State private var editing: RecurringPlan?
    @State private var recording: DuePlan?
    @State private var skipping: DuePlan?
    @State private var deleting: RecurringPlan?
    var body: some View {
        List {
            if let message = model.message { Text(message).foregroundStyle(.secondary) }
            Section("今日の予算残額") {
                let budgets = model.categoryBudgets.filter { $0.dailyAmount != nil || $0.monthlyAmount != nil }
                if budgets.isEmpty { Text("設定からジャンル別予算を登録できます。") }
                ForEach(budgets) { budget in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.remainingText(categoryId: budget.categoryId, date: Date()).trimmingCharacters(in: .whitespacesAndNewlines))
                        if let estimate = Planning.dailyEstimate(budget: budget, date: Date()) {
                            Text((budget.dailyAmount != nil ? "1日の予算 " : "1日あたりの予算目安 約") + yen(estimate)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("期日を迎えた収支") {
                if model.pending.isEmpty { Text("未記録の予定はありません。") }
                ForEach(model.pending) { due in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(planTitle(due.plan)).font(.headline)
                        Text(due.date, style: .date).foregroundStyle(.secondary)
                        if !due.plan.memo.isEmpty { Text(due.plan.memo).font(.callout) }
                        HStack {
                            Button("確認して記録") { recording = due }.buttonStyle(.borderedProminent)
                            Button("今回はスキップ") { skipping = due }.buttonStyle(.bordered)
                        }
                    }.padding(.vertical, 4)
                }
                if model.pending.count == 200 { Text("古い予定から200件を表示しています。処理すると続きが表示されます。") }
            }
            Section("繰り返しの設定") {
                Button { creating = true } label: { Label("繰り返し収支を追加", systemImage: "plus") }
                ForEach(model.recurringPlans.sorted { $0.startDate < $1.startDate }) { plan in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { editing = plan } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(planTitle(plan))
                                Text(plan.recurrence.label + (plan.reminds ? "・通知対象" : "・通知なし")).font(.caption)
                                Text("開始日：" + plan.startDate.formatted(date: .numeric, time: .omitted)).font(.caption)
                            }
                        }
                        Button(role: .destructive) { deleting = plan } label: {
                            Label("削除", systemImage: "xmark.circle")
                        }.buttonStyle(.borderless)
                        Toggle("有効", isOn: Binding(get: { plan.isEnabled }, set: { enabled in
                            var changed = plan; changed.isEnabled = enabled; changed.updatedAt = Date()
                            model.perform { try model.savePlan(changed) }
                        }))
                    }
                }
            }
            Section("処理済み（最新20件）") {
                ForEach(Array(model.occurrences.sorted { $0.updatedAt > $1.updatedAt }.prefix(20))) { occurrence in
                    VStack(alignment: .leading) {
                        Text(model.recurringPlans.first { $0.id == occurrence.planId }.map(planTitle) ?? "繰り返し収支")
                        Text(occurrence.dueDate, style: .date)
                        Text(occurrence.status == .recorded ? "記録済み" : "スキップ済み").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("毎日、設定した時刻に予算項目ごとの1日分の予算を通知します。繰り返し収支は別の確認通知を送ります。残額と期日の予定はこの画面で確認できます。")
                NavigationLink("通知時刻を設定") { NotificationSettingsView(model: model) }
            }
        }
        .navigationTitle("リマインダー")
        .refreshable { model.refresh() }
        .sheet(isPresented: $creating) { PlanEditor(model: model) }
        .sheet(item: $editing) { PlanEditor(model: model, previous: $0) }
        .sheet(item: $recording) { RecordPlanView(model: model, due: $0) }
        .confirmationDialog("繰り返し収支を削除しますか？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("削除", role: .destructive) { if let deleting { model.deletePlan(deleting.id) }; deleting = nil }
            Button("キャンセル", role: .cancel) { deleting = nil }
        } message: {
            if let deleting { Text(planTitle(deleting) + "\n今後の予定と処理済み状態を削除します。記録済みの収支は残ります。") }
        }
        .confirmationDialog("この回の予定をスキップしますか？", isPresented: Binding(get: { skipping != nil }, set: { if !$0 { skipping = nil } }), titleVisibility: .visible) {
            Button("スキップ") { if let skipping { model.skip(skipping) }; skipping = nil }
            Button("キャンセル", role: .cancel) { skipping = nil }
        }
    }
    private func planTitle(_ plan: RecurringPlan) -> String {
        let name = model.categories.first { $0.id == plan.categoryId }?.name ?? "不明なジャンル"
        return (plan.type == .expense ? "支出・" : "収入・") + name + " " + yen(plan.amount)
    }
}

struct PlanEditor: View {
    let model: KakeiboViewModel
    let previous: RecurringPlan?
    @Environment(\.dismiss) private var dismiss
    @State private var type: TransactionType
    @State private var categoryId: UUID?
    @State private var amount: String
    @State private var memo: String
    @State private var startDate: Date
    @State private var recurrence: Recurrence
    @State private var enabled: Bool
    @State private var reminds: Bool
    @State private var error: String?
    init(model: KakeiboViewModel, previous: RecurringPlan? = nil) {
        self.model = model; self.previous = previous
        _type = State(initialValue: previous?.type ?? .expense)
        _categoryId = State(initialValue: previous?.categoryId ?? model.categories.first { $0.type == .expense && !$0.isArchived }?.id)
        _amount = State(initialValue: previous.map { String($0.amount) } ?? "")
        _memo = State(initialValue: previous?.memo ?? "")
        _startDate = State(initialValue: previous?.startDate ?? Date())
        _recurrence = State(initialValue: previous?.recurrence ?? .monthly)
        _enabled = State(initialValue: previous?.isEnabled ?? true)
        _reminds = State(initialValue: previous?.reminds ?? false)
    }
    private var choices: [PersonalKakeiboDomain.Category] {
        model.categories.filter { $0.type == type && (!$0.isArchived || $0.id == previous?.categoryId) }.sorted { $0.sortOrder < $1.sortOrder }
    }
    var body: some View {
        NavigationStack {
            Form {
                Picker("収支区分", selection: $type) {
                    Text("支出").tag(TransactionType.expense); Text("収入").tag(TransactionType.income)
                }.pickerStyle(.segmented)
                    .onChange(of: type) { _, _ in categoryId = choices.first { !$0.isArchived }?.id }
                TextField("金額（円）", text: $amount).keyboardType(.numberPad)
                Section("ジャンル") {
                    CategoryButtons(categories: choices, selection: $categoryId)
                    if choices.contains(where: { $0.id == categoryId && $0.isArchived }) { Text("アーカイブ済みです。有効にする場合は別のジャンルを選んでください。").font(.caption) }
                }
                TextField("メモ（1,000文字まで）", text: $memo, axis: .vertical)
                DatePicker("開始日", selection: $startDate, displayedComponents: .date)
                Picker("繰り返し", selection: $recurrence) { ForEach(Recurrence.allCases, id: \.self) { Text($0.label).tag($0) } }
                Text("毎週は開始日の曜日、毎月は開始日の日付で繰り返します。該当日がない月は月末になります。").font(.caption).foregroundStyle(.secondary)
                Toggle("有効", isOn: $enabled)
                Toggle("リマインドする", isOn: $reminds)
                Text("通知は設定した時刻に毎日まとめて送ります。収支は確認してから記録します。").font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
            }.dismissKeyboardOnSwipe()
                .navigationTitle(previous == nil ? "繰り返し収支を追加" : "繰り返し収支を編集")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(categoryId == nil || amount.isEmpty) }
                }
        }
    }
    private func save() {
        do {
            guard let categoryId else { throw KakeiboError.missingCategory }
            let amount = try AmountValidator.parse(amount)
            let plan = RecurringPlan(id: previous?.id ?? UUID(), type: type, categoryId: categoryId, amount: amount, memo: memo,
                startDate: Month.calendar.startOfDay(for: startDate), recurrence: recurrence, isEnabled: enabled, reminds: reminds)
            try model.savePlan(plan); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct RecordPlanView: View {
    let model: KakeiboViewModel
    let due: DuePlan
    @Environment(\.dismiss) private var dismiss
    @State private var amount: String
    @State private var categoryId: UUID?
    @State private var date: Date
    @State private var memo: String
    @State private var error: String?
    @State private var saving = false
    init(model: KakeiboViewModel, due: DuePlan) {
        self.model = model; self.due = due
        _amount = State(initialValue: String(due.plan.amount)); _categoryId = State(initialValue: due.plan.categoryId)
        _date = State(initialValue: due.date); _memo = State(initialValue: due.plan.memo)
    }
    var body: some View {
        NavigationStack {
            Form {
                Text(due.plan.type == .expense ? "支出" : "収入")
                TextField("金額（円）", text: $amount).keyboardType(.numberPad)
                CategoryButtons(categories: model.categories.filter { $0.type == due.plan.type && !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }, selection: $categoryId)
                RecordedDatePicker(date: $date, transactions: model.transactions)
                TextField("メモ（1,000文字まで）", text: $memo, axis: .vertical)
                if let error { Text(error).foregroundStyle(.red) }
            }.dismissKeyboardOnSwipe().navigationTitle("確認して記録")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            guard !saving else { return }; saving = true; defer { saving = false }
                            do {
                                guard let categoryId else { throw KakeiboError.missingCategory }
                                try model.record(due, amount: amount, categoryId: categoryId, date: date, memo: memo); dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.disabled(saving || amount.isEmpty || categoryId == nil)
                    }
                }
        }
    }
}
