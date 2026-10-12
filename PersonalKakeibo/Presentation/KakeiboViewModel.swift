import Foundation
import Observation
import OSLog
import PersonalKakeiboDomain
import PersonalKakeiboApplication

func yen(_ amount: Int64) -> String { amount.formatted(.number) + "円" }

@MainActor @Observable final class KakeiboViewModel {
    private let logger = Logger(subsystem: "PersonalKakeibo", category: "Entry")
    private let store: Store
    var transactions: [Transaction] = []
    var categories: [PersonalKakeiboDomain.Category] = []
    var budgets: [Budget] = []
    var categoryBudgets: [CategoryBudget] = []
    var recurringPlans: [RecurringPlan] = []
    var occurrences: [PlanOccurrence] = []
    let preferences: DevicePreferences
    let reminderService: any ReminderScheduling
    var selectedTab = 0
    var error: String?
    var message: String?
    var month = Month()
    var summary: MonthlySummary?
    var type: TransactionType = .expense
    var amount = ""
    var categoryId: UUID?
    var date = Date()
    var memo = ""
    var isSaving = false
    private var settings: SettingsUseCases { .init(categories: store, budgets: store) }
    func delete(_ id: UUID) {
        guard let entry = transactions.first(where: { $0.id == id }) else { return }
        var saved = false
        perform { try TransactionUseCases(transactions: store, categories: store).delete(id: id); saved = true }
        if saved { message = "削除しました" + remainingText(categoryId: entry.categoryId, date: entry.occurredAt) }
    }
    func setBudget(_ text: String) throws { try settings.setBudget(month: month, amountText: text) }
    func addCategory(_ name: String, type: TransactionType) throws { try settings.addCategory(name: name, type: type) }
    func renameCategory(_ category: PersonalKakeiboDomain.Category, name: String) throws { try settings.renameCategory(category, name: name) }
    func archiveCategory(_ category: PersonalKakeiboDomain.Category) throws { try settings.archive(id: category.id, archived: !category.isArchived) }
    func reorderCategories(_ ids: [UUID]) throws { try settings.reorder(ids: ids) }
    func exportData(csv: Bool) async throws -> Data {
        let snapshot = try store.snapshot()
        return try await Task.detached {
            try csv ? BackupFormat.csv(snapshot) : BackupFormat.encode(snapshot)
        }.value
    }
    func previewImport(_ url: URL, overwrite: Bool) async throws -> ImportPreview {
        let incoming = try await Task.detached {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 50 * 1024 * 1024 else { throw StoreError.invalidData }
            return try BackupFormat.decode(Data(contentsOf: url))
        }.value
        return try BackupFormat.preview(incoming, current: store.snapshot(), overwrite: overwrite)
    }
    func restore(_ preview: ImportPreview) throws { try store.apply(preview.merged, expecting: preview.original) }
    var duplicateWarning = false
    init(store: Store, preferences: DevicePreferences = DevicePreferences(), reminderService: any ReminderScheduling) {
        self.store = store; self.preferences = preferences; self.reminderService = reminderService
        reminderService.onOpen = { [weak self] in self?.selectedTab = 3; self?.refresh() }
        store.didChange = { [weak self] in self?.refresh() }
        refresh()
    }
    var choices: [PersonalKakeiboDomain.Category] {
        categories.filter { $0.type == type && !$0.isArchived }.sorted { $0.sortOrder < $1.sortOrder }
    }
    var monthly: [Transaction] { transactions.filter { month.range.contains($0.occurredAt) } }
    var budget: Budget? { budgets.first { $0.monthKey == month.key } }
    func perform(_ operation: () throws -> Void) {
        do { try operation(); refresh() } catch { self.error = error.localizedDescription }
    }
    func refresh() {
        do {
            let snapshot = try store.displaySnapshot()
            duplicateWarning = store.hasLogicalDuplicates
            try BackupFormat.validate(snapshot)
            transactions = snapshot.transactions.sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt > $1.occurredAt }
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            categories = snapshot.categories; budgets = snapshot.budgets
            categoryBudgets = snapshot.categoryBudgets; recurringPlans = snapshot.recurringPlans; occurrences = snapshot.occurrences
            for kind in [TransactionType.expense, .income] {
                if let id = preferences.defaultCategory(for: kind), !categories.contains(where: { $0.id == id && $0.type == kind && !$0.isArchived }) {
                    preferences.setDefault(nil, for: kind)
                }
            }
            if !choices.contains(where: { $0.id == categoryId }) { selectDefaultCategory() }
            updateNotifications()
            summary = try MonthlySummary.calculate(transactions, in: month.range)
        } catch { summary = nil; self.error = error.localizedDescription }
    }
    func save() {
        guard !isSaving else { return }; isSaving = true; defer { isSaving = false }
        logger.debug("Entry save requested")
        var saved = false
        perform {
            guard let categoryId else { throw KakeiboError.missingCategory }
            guard memo.count <= 1000 else { throw StoreError.invalidData }
            let useCases = TransactionUseCases(transactions: store, categories: store)
            try useCases.create(type: type, amountText: amount, categoryId: categoryId, occurredAt: date, memo: memo)
            amount = ""; memo = ""; saved = true
        }
        if saved, let categoryId {
            message = "保存しました（端末保存）" + remainingText(categoryId: categoryId, date: date)
            logger.debug("Entry save and refresh completed")
        }
    }
    func update(_ entry: Transaction, amount: String, category: UUID, date: Date, memo: String) throws {
        guard memo.count <= 1000 else { throw StoreError.invalidData }
        try TransactionUseCases(transactions: store, categories: store).update(id: entry.id, type: entry.type, amountText: amount, categoryId: category, occurredAt: date, memo: memo)
        refresh()
        message = "更新しました" + remainingText(categoryId: category, date: date)
    }
    private var planning: PlanningUseCases { .init(planning: store, categories: store) }
    var pending: [DuePlan] { Planning.pending(plans: recurringPlans, occurrences: occurrences, through: Date()) }
    var notificationTargetsExist: Bool { !notificationMessages(date: Date()).isEmpty }
    func notificationMessages(date: Date) -> [ReminderMessage] {
        let active = categories.filter { !$0.isArchived }.sorted {
            $0.sortOrder == $1.sortOrder ? $0.id.uuidString < $1.id.uuidString : $0.sortOrder < $1.sortOrder
        }
        var messages: [ReminderMessage] = []
        for category in active where category.type == .expense {
            guard let budget = categoryBudgets.first(where: { $0.categoryId == category.id }), budget.reminds,
                  let estimate = Planning.dailyEstimate(budget: budget, date: date) else { continue }
            let body = budget.dailyAmount != nil
                ? "1日の予算は" + yen(estimate) + "です。"
                : "1日あたりの予算目安は約" + yen(estimate) + "です。"
            messages.append(ReminderMessage(id: "budget." + category.id.uuidString, title: category.name + "の予算", body: body))
        }
        if recurringPlans.contains(where: { plan in
            plan.reminds && plan.isEnabled && active.contains { $0.id == plan.categoryId }
        }) {
            messages.append(ReminderMessage(id: "plans", title: "繰り返し収支の確認", body: "未記録の繰り返し収支を確認しましょう。"))
        }
        return messages
    }
    func appendAmount(_ digits: String) {
        message = nil
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }), amount.count + digits.count <= 19 else { return }
        amount += digits
    }
    func clearAmount() { amount = ""; message = nil }
    func selectDefaultCategory() {
        categoryId = choices.first(where: { $0.id == preferences.defaultCategory(for: type) })?.id ?? choices.first?.id
    }
    func setDefaultCategory(_ id: UUID) {
        guard choices.contains(where: { $0.id == id }) else { return }
        preferences.setDefault(id, for: type); categoryId = id
        message = "起動時の初期ジャンルを設定しました"
    }
    func remainingText(categoryId: UUID, date: Date) -> String {
        guard let budget = categoryBudgets.first(where: { $0.categoryId == categoryId }), budget.dailyAmount != nil || budget.monthlyAmount != nil else { return "" }
        do {
            let amounts = try Planning.remaining(budget: budget, transactions: transactions, date: date)
            let name = categories.first { $0.id == categoryId }?.name ?? ""
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "ja_JP")
            formatter.calendar = Month.calendar; formatter.timeZone = Month.calendar.timeZone; formatter.dateStyle = .medium
            let day = formatter.string(from: date)
            var lines = ["\n" + day + "・" + name]
            if let value = amounts.daily { lines.append("日額残り " + yen(value)) }
            if let value = amounts.monthly { lines.append("月額残り " + yen(value)) }
            return lines.joined(separator: "\n")
        } catch { return "\n残額を計算できません：" + error.localizedDescription }
    }
    func setCategoryBudget(categoryId: UUID, daily: String, monthly: String, reminds: Bool) throws {
        try planning.setBudget(previous: categoryBudgets.first { $0.categoryId == categoryId }, categoryId: categoryId, daily: daily, monthly: monthly, reminds: reminds)
        refresh()
        if reminds { requestNotifications() }
    }
    func savePlan(_ plan: RecurringPlan) throws {
        try planning.savePlan(plan); refresh()
        if plan.reminds && plan.isEnabled { requestNotifications() }
    }
    func deletePlan(_ id: UUID) {
        perform { try planning.deletePlan(id: id); message = "繰り返し収支を削除しました" }
    }
    func record(_ due: DuePlan, amount: String, categoryId: UUID, date: Date, memo: String) throws {
        guard recurringPlans.first(where: { $0.id == due.plan.id }) == due.plan else { throw StoreError.changed }
        try planning.record(due, amount: amount, categoryId: categoryId, date: date, memo: memo)
        refresh(); message = "保存しました（端末保存）" + remainingText(categoryId: categoryId, date: date)
    }
    func skip(_ due: DuePlan) {
        perform { try planning.skip(due) }
    }
    func updateNotifications() { reminderService.update(messages: notificationMessages(date: Date()), slots: preferences.slots) }
    func requestNotifications() {
        guard notificationTargetsExist, preferences.slots.contains(where: \.isEnabled) else { updateNotifications(); return }
        Task { await reminderService.requestPermission(); updateNotifications() }
    }
    func setNotificationSlots(_ slots: [ReminderSlot]) throws {
        guard ReminderSlot.validate(slots) else { throw NotificationSettingsError.duplicateTime }
        try preferences.setSlots(slots)
        requestNotifications()
    }
    func selectMonth(_ date: Date) { month = Month(date: date); refresh() }
    func moveMonth(_ count: Int) { month = month.shifted(count); refresh() }
}

enum NotificationSettingsError: Error, LocalizedError {
    case duplicateTime
    var errorDescription: String? { "通知は異なる時刻で、1日最大3回に設定してください。" }
}
