import XCTest
import Foundation
import SwiftData
import PersonalKakeiboDomain
import PersonalKakeiboApplication

@MainActor final class FakeReminders: ReminderScheduling {
    var status = "テスト用"
    var onOpen: (() -> Void)?
    var updates: [(Bool, [ReminderSlot], [ReminderMessage])] = []
    var permissionRequests = 0
    func requestPermission() async { permissionRequests += 1 }
    func update(messages: [ReminderMessage], slots: [ReminderSlot]) { updates.append((!messages.isEmpty, slots, messages)) }
}

final class PlanningPersistenceTests: XCTestCase {
    @MainActor func testDeletePlanPreservesTransactionsAndOtherPlans() throws {
        let store = try store()
        let category = try XCTUnwrap(store.allCategories().first { $0.type == .expense })
        let plan = RecurringPlan(type: .expense, categoryId: category.id, amount: 100, startDate: date(10, 1))
        let other = RecurringPlan(type: .expense, categoryId: category.id, amount: 200, startDate: date(10, 1))
        let useCases = PlanningUseCases(planning: store, categories: store)
        try useCases.savePlan(plan); try useCases.savePlan(other)
        try useCases.record(DuePlan(plan: plan, date: date(10, 1)), amount: "100", categoryId: category.id, date: date(10, 1), memo: "")
        try useCases.skip(DuePlan(plan: other, date: date(10, 1)))
        let transactions = try store.allTransactions()
        let before = try store.snapshot()
        let failing = Store(container: store.container, beforeSave: { throw StoreError.conflict })
        XCTAssertThrowsError(try failing.deletePlan(id: plan.id))
        XCTAssertEqual(try store.snapshot(), before)
        try useCases.deletePlan(id: plan.id)
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.recurringPlans.map(\.id), [other.id])
        XCTAssertEqual(snapshot.occurrences.map(\.planId), [other.id])
        XCTAssertEqual(snapshot.transactions, transactions)
        try BackupFormat.validate(snapshot)
        XCTAssertFalse(Planning.pending(plans: snapshot.recurringPlans, occurrences: snapshot.occurrences, through: date(10, 12)).contains { $0.plan.id == plan.id })
    }
    func testBackgroundStoreNotificationHopsToMainActor() async throws {
        let changed = XCTestExpectation(description: "A background notification refreshes on MainActor")
        let owner = try await MainActor.run {
            let schema = Schema(versionedSchema: KakeiboSchema.self)
            let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
            let store = Store(container: try ModelContainer(for: schema, configurations: config))
            store.didChange = {
                MainActor.assertIsolated()
                changed.fulfill()
            }
            return store
        }
        await Task.detached {
            NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: nil)
        }.value
        await fulfillment(of: [changed], timeout: 2)
        await MainActor.run { owner.didChange = nil }
    }
    private func date(_ month: Int, _ day: Int) -> Date {
        Month.calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }
    @MainActor private func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        let store = Store(container: try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        try store.seed(); return store
    }
    @MainActor private func preferences() -> DevicePreferences {
        DevicePreferences(defaults: UserDefaults(suiteName: "kakeibo.tests." + UUID().uuidString)!)
    }
    @MainActor func testRepeatedViewModelSavingAndFailedSavePreservesInput() async throws {
        let store = try store()
        let model = KakeiboViewModel(store: store, preferences: preferences(), reminderService: FakeReminders())
        model.date = date(10, 1)
        let category = try XCTUnwrap(model.categoryId)
        try model.setCategoryBudget(categoryId: category, daily: "1000", monthly: "5000", reminds: false)
        for _ in 0..<30 {
            model.amount = "10"; model.memo = "架空メモ"; model.save()
            XCTAssertNil(model.error); XCTAssertEqual(model.amount, ""); XCTAssertEqual(model.memo, "")
        }
        XCTAssertEqual(model.transactions.count, 30)
        XCTAssertTrue(model.message?.contains("日額残り 700円") == true)
        let failing = Store(container: store.container, beforeSave: { throw StoreError.conflict })
        let failed = KakeiboViewModel(store: failing, preferences: preferences(), reminderService: FakeReminders())
        failed.amount = "40"; failed.memo = "消えないメモ"; failed.save()
        XCTAssertNotNil(failed.error); XCTAssertEqual(failed.amount, "40"); XCTAssertEqual(failed.memo, "消えないメモ")
        XCTAssertFalse(failed.isSaving); XCTAssertEqual(try store.allTransactions().count, 30)
        XCTAssertNil(failed.message)
        let first = try XCTUnwrap(model.transactions.first)
        try model.update(first, amount: "50", category: category, date: date(10, 1), memo: "編集")
        XCTAssertTrue(model.message?.contains("日額残り 660円") == true)
        model.delete(first.id)
        XCTAssertTrue(model.message?.contains("日額残り 710円") == true)
    }
    @MainActor func testDefaultsSurviveRecreationAndArchivedDefaultFallsBack() throws {
        let store = try store()
        let suite = "kakeibo.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = DevicePreferences(defaults: defaults)
        let model = KakeiboViewModel(store: store, preferences: prefs, reminderService: FakeReminders())
        let categories = try store.categories(type: .expense)
        let chosen = try XCTUnwrap(categories.last)
        model.setDefaultCategory(chosen.id)
        let reopened = KakeiboViewModel(store: store, preferences: DevicePreferences(defaults: defaults), reminderService: FakeReminders())
        XCTAssertEqual(reopened.categoryId, chosen.id)
        try store.setArchived(id: chosen.id, archived: true); reopened.refresh()
        XCTAssertEqual(reopened.categoryId, categories.first?.id)
        XCTAssertNil(reopened.preferences.defaultExpense)
        reopened.type = .income; reopened.selectDefaultCategory()
        let income = try XCTUnwrap(reopened.choices.last)
        reopened.setDefaultCategory(income.id)
        reopened.type = .expense; reopened.selectDefaultCategory()
        XCTAssertEqual(reopened.categoryId, categories.first?.id)
        reopened.type = .income; reopened.selectDefaultCategory()
        XCTAssertEqual(reopened.categoryId, income.id)
    }
    @MainActor func testResolveIsAtomicAndRepeatedRecordOrSkipIsRejected() throws {
        let store = try store()
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        let plan = RecurringPlan(type: .expense, categoryId: category.id, amount: 100, startDate: date(9, 1), recurrence: .monthly)
        try store.save(plan)
        let due = DuePlan(plan: plan, date: date(10, 1))
        let failed = Store(container: store.container, beforeSave: { throw StoreError.conflict })
        let failing = PlanningUseCases(planning: failed, categories: failed)
        XCTAssertThrowsError(try failing.record(due, amount: "250", categoryId: category.id, date: date(10, 2), memo: "変更した記録"))
        XCTAssertTrue(try store.allTransactions().isEmpty); XCTAssertTrue(try store.snapshot().occurrences.isEmpty)
        let useCases = PlanningUseCases(planning: store, categories: store)
        try useCases.record(due, amount: "250", categoryId: category.id, date: date(10, 2), memo: "変更した記録")
        XCTAssertThrowsError(try useCases.record(due, amount: "250", categoryId: category.id, date: date(10, 2), memo: ""))
        XCTAssertThrowsError(try useCases.skip(due))
        var snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.transactions.count, 1); XCTAssertEqual(snapshot.occurrences.count, 1)
        XCTAssertEqual(snapshot.transactions.first?.amount, 250)
        XCTAssertEqual(snapshot.transactions.first?.source, .recurring)
        XCTAssertEqual(snapshot.occurrences.first?.dueDate, date(10, 1))
        try useCases.skip(DuePlan(plan: plan, date: date(9, 1)))
        let entry = try XCTUnwrap(snapshot.transactions.first)
        try store.delete(id: entry.id)
        snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.occurrences.count, 2)
        XCTAssertTrue(Planning.pending(plans: [plan], occurrences: snapshot.occurrences, through: date(10, 12)).isEmpty)
    }
    @MainActor func testBudgetValidationClearingAndPlanArchiveRules() throws {
        let store = try store()
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        let cases = PlanningUseCases(planning: store, categories: store)
        try cases.setBudget(previous: nil, categoryId: category.id, daily: "500", monthly: "10000", reminds: true)
        let first = try XCTUnwrap(store.snapshot().categoryBudgets.first)
        XCTAssertThrowsError(try cases.setBudget(previous: first, categoryId: category.id, daily: "0", monthly: "100", reminds: true))
        XCTAssertEqual(try store.snapshot().categoryBudgets.first, first)
        try cases.setBudget(previous: first, categoryId: category.id, daily: "", monthly: "", reminds: true)
        let cleared = try XCTUnwrap(store.snapshot().categoryBudgets.first)
        XCTAssertNil(cleared.dailyAmount); XCTAssertNil(cleared.monthlyAmount); XCTAssertFalse(cleared.reminds)
        var plan = RecurringPlan(type: .expense, categoryId: category.id, amount: 100, startDate: date(10, 1))
        try cases.savePlan(plan)
        try store.setArchived(id: category.id, archived: true)
        XCTAssertThrowsError(try cases.savePlan(plan))
        plan.isEnabled = false; try cases.savePlan(plan)
        XCTAssertThrowsError(try cases.record(DuePlan(plan: plan, date: date(10, 1)), amount: "100", categoryId: category.id, date: date(10, 1), memo: ""))
    }
    @MainActor func testMigrationFromV1PreservesDataAndNewRecordsSurviveReopen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let category = PersonalKakeiboDomain.Category(name: "架空の食費", type: .expense)
        let entry = Transaction(type: .expense, amount: 200, categoryId: category.id, occurredAt: date(10, 1), memo: "移行前のメモ")
        let budget = Budget(monthKey: "2026-10", amount: 10000)
        do {
            let schema = Schema(versionedSchema: KakeiboSchemaV1.self)
            let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: config)
            let context = ModelContext(container); context.autosaveEnabled = false
            context.insert(StoredCategory(category)); context.insert(StoredTransaction(entry)); context.insert(StoredBudget(budget))
            try context.save()
        }
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let config = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var saved: BackupSnapshot!
        do {
            let store = Store(container: try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self, configurations: config))
            let original = try store.snapshot()
            XCTAssertEqual(original.transactions, [entry]); XCTAssertEqual(original.categories, [category]); XCTAssertEqual(original.budgets, [budget])
            try store.save(CategoryBudget(categoryId: category.id, dailyAmount: 1000, monthlyAmount: 5000))
            let plan = RecurringPlan(type: .expense, categoryId: category.id, amount: 100, startDate: date(10, 1))
            try store.save(plan)
            try PlanningUseCases(planning: store, categories: store).skip(DuePlan(plan: plan, date: date(10, 1)))
            saved = try store.snapshot()
        }
        let reopened = Store(container: try ModelContainer(for: schema, migrationPlan: KakeiboMigrationPlan.self, configurations: config))
        XCTAssertTrue(BackupFormat.equivalent(try reopened.snapshot(), saved))
    }
    @MainActor func testExtendedBackupRoundTripRestoreAndOldFormat() throws {
        let source = try store(); let category = try XCTUnwrap(source.categories(type: .expense).first)
        try source.save(CategoryBudget(categoryId: category.id, dailyAmount: 500, monthlyAmount: 3000, reminds: true))
        let plan = RecurringPlan(type: .expense, categoryId: category.id, amount: 100, startDate: date(10, 1), reminds: true)
        try source.save(plan)
        try PlanningUseCases(planning: source, categories: source).record(DuePlan(plan: plan, date: date(10, 1)), amount: "100", categoryId: category.id, date: date(10, 1), memo: "架空")
        let original = try source.snapshot()
        let data = try BackupFormat.encode(original)
        XCTAssertTrue(BackupFormat.equivalent(try BackupFormat.decode(data), original))
        let destination = try store()
        let preview = try BackupFormat.preview(BackupFormat.decode(data), current: destination.snapshot(), overwrite: false)
        try destination.apply(preview.merged, expecting: preview.original)
        XCTAssertTrue(BackupFormat.equivalent(try destination.snapshot(), original))
        XCTAssertEqual(try BackupFormat.preview(BackupFormat.decode(data), current: destination.snapshot(), overwrite: false).additions, 0)
        // v1 has only the original three arrays.
        let legacySnapshot = BackupSnapshot(transactions: [], categories: original.categories, budgets: original.budgets)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: BackupFormat.encode(legacySnapshot)) as? [String: Any])
        object["schemaVersion"] = 1
        for key in ["categoryBudgets", "recurringPlans", "occurrences"] { object.removeValue(forKey: key) }
        let legacy = try BackupFormat.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(BackupFormat.equivalent(legacy, legacySnapshot))
        let legacyPreview = try BackupFormat.preview(legacy, current: destination.snapshot(), overwrite: false)
        XCTAssertEqual(legacyPreview.merged.categoryBudgets, original.categoryBudgets)
        XCTAssertEqual(legacyPreview.merged.occurrences, original.occurrences)
    }
    @MainActor func testRestoreFailureRollsBackPlanningRecordsAndTransactions() throws {
        let store = try store(); let original = try store.snapshot()
        let category = try XCTUnwrap(original.categories.first { $0.type == .expense })
        var next = original
        next.categoryBudgets = [CategoryBudget(categoryId: category.id, dailyAmount: 500)]
        next.recurringPlans = [RecurringPlan(type: .expense, categoryId: category.id, amount: 100, startDate: date(10, 1))]
        next.transactions = [Transaction(type: .expense, amount: 100, categoryId: category.id, occurredAt: date(10, 1))]
        let failing = Store(container: store.container, beforeSave: { throw StoreError.conflict })
        XCTAssertThrowsError(try failing.apply(next, expecting: original))
        XCTAssertTrue(BackupFormat.equivalent(try store.snapshot(), original))
    }
    @MainActor func testDoubleZeroAndClearPreserveOtherEntryFields() throws {
        let model = KakeiboViewModel(store: try store(), preferences: preferences(), reminderService: FakeReminders())
        model.memo = "保持するメモ"; model.date = date(10, 2)
        let category = model.categoryId
        model.appendAmount("1"); model.appendAmount("00")
        XCTAssertEqual(model.amount, "100")
        model.amount = String(repeating: "1", count: 18)
        model.appendAmount("00")
        XCTAssertEqual(model.amount.count, 18)
        model.appendAmount("0")
        XCTAssertEqual(model.amount.count, 19)
        model.appendAmount("0")
        XCTAssertEqual(model.amount.count, 19)
        model.message = "保存しました"; model.clearAmount()
        XCTAssertEqual(model.amount, ""); XCTAssertNil(model.message)
        XCTAssertEqual(model.memo, "保持するメモ"); XCTAssertEqual(model.date, date(10, 2))
        XCTAssertEqual(model.categoryId, category)
        model.appendAmount("00"); XCTAssertEqual(model.amount, "00")
    }
    @MainActor func testIndividualBudgetMessagesRecalculateAndRetainSeparatePlanReminder() throws {
        let store = try store(); let fake = FakeReminders()
        let model = KakeiboViewModel(store: store, preferences: preferences(), reminderService: fake)
        let categories = try store.categories(type: .expense)
        let first = try XCTUnwrap(categories.first), second = try XCTUnwrap(categories.dropFirst().first)
        try model.setCategoryBudget(categoryId: first.id, daily: "", monthly: "31000", reminds: true)
        try model.setCategoryBudget(categoryId: second.id, daily: "500", monthly: "30000", reminds: true)
        let october = model.notificationMessages(date: date(10, 1))
        XCTAssertEqual(october.count, 2)
        let firstId = "budget." + first.id.uuidString
        XCTAssertEqual(october.first { $0.id == firstId }?.title, first.name + "の予算")
        XCTAssertEqual(october.first { $0.id == firstId }?.body, "1日あたりの予算目安は約1,000円です。")
        XCTAssertEqual(october.first { $0.id == "budget." + second.id.uuidString }?.body, "1日の予算は500円です。")
        XCTAssertEqual(model.notificationMessages(date: date(11, 1)).first { $0.id == firstId }?.body, "1日あたりの予算目安は約1,033円です。")
        XCTAssertEqual(Set(try XCTUnwrap(fake.updates.last).2.map(\.id)).count, 2)
        try model.savePlan(RecurringPlan(type: .expense, categoryId: second.id, amount: 100, startDate: date(10, 1), reminds: true))
        XCTAssertEqual(model.notificationMessages(date: date(10, 1)).filter { $0.id == "plans" }.count, 1)
        try model.setCategoryBudget(categoryId: first.id, daily: "", monthly: "31000", reminds: false)
        XCTAssertFalse(model.notificationMessages(date: date(10, 1)).contains { $0.id == firstId })
        try model.setCategoryBudget(categoryId: second.id, daily: "", monthly: "", reminds: true)
        XCTAssertEqual(model.notificationMessages(date: date(10, 1)).map(\.id), ["plans"])
        try store.setArchived(id: second.id, archived: true); model.refresh()
        XCTAssertTrue(try XCTUnwrap(fake.updates.last).2.isEmpty)
    }
    @MainActor func testNotificationTargetsSlotsAndOpeningReminderTab() async throws {
        let store = try store(); let fake = FakeReminders(); let prefs = preferences()
        let model = KakeiboViewModel(store: store, preferences: prefs, reminderService: fake)
        XCTAssertFalse(try XCTUnwrap(fake.updates.last).0)
        let category = try XCTUnwrap(model.categoryId)
        try model.setCategoryBudget(categoryId: category, daily: "500", monthly: "", reminds: true)
        await Task.yield()
        XCTAssertTrue(model.notificationTargetsExist)
        XCTAssertTrue(try XCTUnwrap(fake.updates.last).0)
        XCTAssertEqual(try XCTUnwrap(fake.updates.last).1, ReminderSlot.defaults)
        fake.onOpen?(); XCTAssertEqual(model.selectedTab, 3)
        var slots = prefs.slots; slots[1].hour = 7
        XCTAssertThrowsError(try model.setNotificationSlots(slots))
        XCTAssertEqual(prefs.slots, ReminderSlot.defaults)
        slots = prefs.slots.map { var slot = $0; slot.isEnabled = false; return slot }
        try model.setNotificationSlots(slots)
        XCTAssertTrue(try XCTUnwrap(fake.updates.last).1.allSatisfy { !$0.isEnabled })
        try store.setArchived(id: category, archived: true); model.refresh()
        XCTAssertFalse(model.notificationTargetsExist)
        XCTAssertFalse(try XCTUnwrap(fake.updates.last).0)
    }
}
