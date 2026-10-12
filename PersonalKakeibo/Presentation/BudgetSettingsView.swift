import SwiftUI
import PersonalKakeiboDomain

struct BudgetSettingsView: View {
    @Bindable var model: KakeiboViewModel
    @State private var editing: PersonalKakeiboDomain.Category?
    var body: some View {
        List {
            Section {
                Text("ジャンルごとに日額・月額の上限を設定します。空欄にして保存すると解除します。予算は毎日・毎月リセットされ、繰り越しません。")
            }
            ForEach(model.categories.filter { $0.type == .expense && !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }) { category in
                Button { editing = category } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category.name).font(.headline)
                        if let budget = model.categoryBudgets.first(where: { $0.categoryId == category.id }), budget.dailyAmount != nil || budget.monthlyAmount != nil {
                            if let daily = budget.dailyAmount { Text("日額予算 " + yen(daily)) }
                            if let monthly = budget.monthlyAmount { Text("月額予算 " + yen(monthly)) }
                            Text(model.remainingText(categoryId: category.id, date: Date()).trimmingCharacters(in: .whitespacesAndNewlines)).foregroundStyle(.secondary)
                        } else { Text("予算未設定").foregroundStyle(.secondary) }
                    }
                }.foregroundStyle(.primary)
            }
        }.navigationTitle("ジャンル別予算")
            .sheet(item: $editing) { CategoryBudgetEditor(model: model, category: $0) }
    }
}

struct CategoryBudgetEditor: View {
    let model: KakeiboViewModel
    let category: PersonalKakeiboDomain.Category
    @Environment(\.dismiss) private var dismiss
    @State private var daily: String
    @State private var monthly: String
    @State private var reminds: Bool
    @State private var error: String?
    init(model: KakeiboViewModel, category: PersonalKakeiboDomain.Category) {
        self.model = model; self.category = category
        let budget = model.categoryBudgets.first { $0.categoryId == category.id }
        _daily = State(initialValue: budget?.dailyAmount.map(String.init) ?? "")
        _monthly = State(initialValue: budget?.monthlyAmount.map(String.init) ?? "")
        _reminds = State(initialValue: budget?.reminds ?? false)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField("日額予算（円・空欄で解除）", text: $daily).keyboardType(.numberPad)
                TextField("月額予算（円・空欄で解除）", text: $monthly).keyboardType(.numberPad)
                Toggle("リマインドする", isOn: $reminds)
                Text("日額予算を優先し、月額のみの場合は当月の日数で割った1日分の概算を通知します（1円未満切り捨て）。毎日、通知設定の時刻に項目ごとに送ります。残額は収支の保存直後に表示します。").font(.caption)
                if let error { Text(error).foregroundStyle(.red) }
            }.dismissKeyboardOnSwipe().navigationTitle(category.name + "の予算")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("保存") {
                        do { try model.setCategoryBudget(categoryId: category.id, daily: daily, monthly: monthly, reminds: reminds); dismiss() }
                        catch { self.error = error.localizedDescription }
                    } }
                }
        }
    }
}
