import Foundation
import SwiftData
import CoreData
import Combine
import OSLog
import PersonalKakeiboDomain

 enum StoreError: Error, LocalizedError {
    case invalidData, conflict, changed, unsupported
    var errorDescription: String? {
        switch self {
        case .invalidData: "データの形式または参照が不正です。"
        case .conflict: "既存データと競合しています。内容を確認してください。"
        case .changed: "プレビュー後にデータが変わりました。再度プレビューしてください。"
        case .unsupported: "このバックアップのバージョンには対応していません。"
        }
    }
}

@MainActor final class Store: TransactionRepository, CategoryRepository, BudgetRepository, BackupRepository, PlanningRepository {
    private let logger = Logger(subsystem: "PersonalKakeibo", category: "Persistence")
    let container: ModelContainer
    private let beforeSave: () throws -> Void
    var didChange: (() -> Void)?
    private var changeSubscription: AnyCancellable?
    var hasLogicalDuplicates = false
    private var context: ModelContext { container.mainContext }
    init(container: ModelContainer, beforeSave: @escaping () throws -> Void = {}) {
        self.container = container; self.beforeSave = beforeSave; context.autosaveEnabled = false
        // Local writes refresh explicitly after committing. Only external changes need this observer.
        // Core Data may post from a private queue. @Sendable keeps the Combine callback
        // nonisolated under Swift 6; only the refresh itself runs on MainActor.
        changeSubscription = NotificationCenter.default.publisher(for: .NSPersistentStoreRemoteChange).sink { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in self?.didChange?() }
        }
    }

    func allTransactions() throws -> [Transaction] { try context.fetch(FetchDescriptor<StoredTransaction>()).map { try $0.value() } }
    func allCategories() throws -> [PersonalKakeiboDomain.Category] { try context.fetch(FetchDescriptor<StoredCategory>()).map { try $0.value() } }
    func allBudgets() throws -> [Budget] { try context.fetch(FetchDescriptor<StoredBudget>()).map { try $0.value() } }
    func find(id: UUID) throws -> Transaction? {
        let matches = try allTransactions().filter { $0.id == id }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }; return matches.first
    }
    func transactions(in range: Range<Date>, categoryId: UUID?) throws -> [Transaction] {
        try allTransactions().filter { range.contains($0.occurredAt) && (categoryId == nil || $0.categoryId == categoryId) }
            .sorted { a,b in
                if a.occurredAt != b.occurredAt { return a.occurredAt > b.occurredAt }
                if a.createdAt != b.createdAt { return a.createdAt > b.createdAt }
                return a.id.uuidString < b.id.uuidString
            }
    }
    func categories(type: TransactionType) throws -> [PersonalKakeiboDomain.Category] {
        try allCategories().filter { $0.type == type }.sorted { ($0.sortOrder, $0.id.uuidString) < ($1.sortOrder, $1.id.uuidString) }
    }
    func budget(monthKey: String) throws -> Budget? {
        let matches = try allBudgets().filter { $0.monthKey == monthKey }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }; return matches.first
    }
    private func commit(_ operation: () throws -> Void) throws {
        do {
            logger.debug("Preparing persistent changes")
            try operation(); try beforeSave()
            logger.debug("Saving persistent changes")
            try context.save()
            logger.debug("Persistent save completed")
        } catch {
            logger.error("Persistent save failed; rolling back")
            context.rollback(); throw error
        }
    }
    func save(_ value: Transaction) throws {
        guard value.memo.count <= 1000 else { throw StoreError.invalidData }
        let categoryMatches = try allCategories().filter { $0.id == value.categoryId }
        guard categoryMatches.count <= 1 else { throw KakeiboError.duplicateID }
        try AmountValidator.validate(value, category: categoryMatches.first, previous: try find(id: value.id))
        let matches = try context.fetch(FetchDescriptor<StoredTransaction>()).filter { $0.id == value.id }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }
        try commit { if let row = matches.first { row.update(value) } else { context.insert(StoredTransaction(value)) } }
    }
    func save(_ value: PersonalKakeiboDomain.Category) throws {
        guard !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.count <= 40 else { throw KakeiboError.invalidCategoryName }
        let matches = try context.fetch(FetchDescriptor<StoredCategory>()).filter { $0.id == value.id }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }
        if let row = matches.first, row.typeRaw != value.type.rawValue { throw KakeiboError.categoryTypeMismatch }
        try commit { if let row = matches.first { row.update(value) } else { context.insert(StoredCategory(value)) } }
    }
    func save(_ value: Budget) throws {
        _ = try Month(key: value.monthKey)
        guard value.amount > 0 else { throw KakeiboError.invalidAmount }
        let matches = try context.fetch(FetchDescriptor<StoredBudget>()).filter { $0.id == value.id || $0.monthKey == value.monthKey }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }
        try commit { if let row = matches.first { row.update(value) } else { context.insert(StoredBudget(value)) } }
    }
    func delete(id: UUID) throws {
        let rows = try context.fetch(FetchDescriptor<StoredTransaction>()).filter { $0.id == id }
        guard rows.count <= 1 else { throw KakeiboError.duplicateID }
        try commit { rows.forEach(context.delete) }
    }
    func reorder(ids: [UUID]) throws {
        let rows = try context.fetch(FetchDescriptor<StoredCategory>())
        guard Set(ids).count == ids.count else { throw KakeiboError.duplicateID }
        try commit {
            for (index,id) in ids.enumerated() {
                let matches = rows.filter { $0.id == id }
                guard matches.count == 1 else { throw KakeiboError.duplicateID }
                matches[0].sortOrder = index; matches[0].updatedAt = Date()
            }
        }
    }
    func setArchived(id: UUID, archived: Bool) throws {
        let matches = try allCategories().filter { $0.id == id }
        guard matches.count == 1, var category = matches.first else { throw KakeiboError.duplicateID }
        category.isArchived = archived; category.updatedAt = Date(); try save(category)
    }
    func snapshot() throws -> BackupSnapshot {
        let rows = try context.fetch(FetchDescriptor<StoredPlanningRecord>())
        return try BackupSnapshot(transactions: allTransactions(), categories: allCategories(), budgets: allBudgets(),
            categoryBudgets: decodePlanning(rows, kind: "categoryBudget"), recurringPlans: decodePlanning(rows, kind: "recurringPlan"), occurrences: decodePlanning(rows, kind: "occurrence"))
    }
    func displaySnapshot() throws -> BackupSnapshot {
        let raw = try snapshot()
        func latest<T: Codable>(_ values: [T], key: (T) -> String, date: (T) -> Date) throws -> [T] {
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            var selected: [String: T] = [:]
            for value in values {
                let id = key(value)
                if let previous = selected[id] {
                    let tieWins = try encoder.encode(value).lexicographicallyPrecedes(encoder.encode(previous))
                    if date(value) > date(previous) || (date(value) == date(previous) && tieWins) {
                        selected[id] = value
                    }
                } else { selected[id] = value }
            }
            return selected.keys.sorted().compactMap { selected[$0] }
        }
        let result = try BackupSnapshot(
            transactions: latest(raw.transactions, key: { $0.id.uuidString }, date: { $0.updatedAt }),
            categories: latest(raw.categories, key: { $0.id.uuidString }, date: { $0.updatedAt }),
            budgets: latest(raw.budgets, key: { $0.monthKey }, date: { $0.updatedAt }),
            categoryBudgets: latest(raw.categoryBudgets, key: { $0.categoryId.uuidString }, date: { $0.updatedAt }),
            recurringPlans: latest(raw.recurringPlans, key: { $0.id.uuidString }, date: { $0.updatedAt }),
            occurrences: latest(raw.occurrences, key: { $0.key }, date: { $0.updatedAt })
        )
        hasLogicalDuplicates = result.transactions.count != raw.transactions.count || result.categories.count != raw.categories.count || result.budgets.count != raw.budgets.count || result.categoryBudgets.count != raw.categoryBudgets.count || result.recurringPlans.count != raw.recurringPlans.count || result.occurrences.count != raw.occurrences.count
        return result
    }
    func apply(_ snapshot: BackupSnapshot, expecting current: BackupSnapshot) throws {
        guard BackupFormat.equivalent(try self.snapshot(), current) else { throw StoreError.changed }
        try BackupFormat.validate(current)
        try BackupFormat.validate(snapshot)
        guard Set(current.transactions.map(\.id)).isSubset(of: Set(snapshot.transactions.map(\.id))),
              Set(current.categories.map(\.id)).isSubset(of: Set(snapshot.categories.map(\.id))),
              Set(current.budgets.map(\.id)).isSubset(of: Set(snapshot.budgets.map(\.id))),
              Set(current.categoryBudgets.map(\.id)).isSubset(of: Set(snapshot.categoryBudgets.map(\.id))),
              Set(current.recurringPlans.map(\.id)).isSubset(of: Set(snapshot.recurringPlans.map(\.id))),
              Set(current.occurrences.map(\.id)).isSubset(of: Set(snapshot.occurrences.map(\.id))) else { throw StoreError.invalidData }
        let categoryTypes = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.type) })
        for category in current.categories where categoryTypes[category.id] != category.type {
            throw KakeiboError.categoryTypeMismatch
        }
        let isolated = ModelContext(container); isolated.autosaveEnabled = false
        do {
            let transactions = try isolated.fetch(FetchDescriptor<StoredTransaction>())
            let categories = try isolated.fetch(FetchDescriptor<StoredCategory>())
            let budgets = try isolated.fetch(FetchDescriptor<StoredBudget>())
            for value in snapshot.categories {
                if let row = categories.first(where: { $0.id == value.id }) { row.update(value) }
                else { isolated.insert(StoredCategory(value)) }
            }
            for value in snapshot.transactions {
                if let row = transactions.first(where: { $0.id == value.id }) { row.update(value) }
                else { isolated.insert(StoredTransaction(value)) }
            }
            for value in snapshot.budgets {
                if let row = budgets.first(where: { $0.id == value.id }) { row.update(value) }
                else { isolated.insert(StoredBudget(value)) }
            }
            let records = try isolated.fetch(FetchDescriptor<StoredPlanningRecord>())
            for value in snapshot.categoryBudgets { try upsertPlanning(value, id: value.id, kind: "categoryBudget", date: value.updatedAt, rows: records, in: isolated) }
            for value in snapshot.recurringPlans { try upsertPlanning(value, id: value.id, kind: "recurringPlan", date: value.updatedAt, rows: records, in: isolated) }
            for value in snapshot.occurrences { try upsertPlanning(value, id: value.id, kind: "occurrence", date: value.updatedAt, rows: records, in: isolated) }
            try beforeSave(); try isolated.save()
        } catch { isolated.rollback(); throw error }
    }
    private func decodePlanning<T: Decodable & Identifiable>(_ rows: [StoredPlanningRecord], kind: String) throws -> [T] where T.ID == UUID {
        guard rows.allSatisfy({ ["categoryBudget", "recurringPlan", "occurrence"].contains($0.kind) }) else { throw StoreError.invalidData }
        return try rows.filter { $0.kind == kind }.map {
            let value = try JSONDecoder().decode(T.self, from: $0.payload)
            guard value.id == $0.id else { throw StoreError.invalidData }
            return value
        }
    }
    private func upsertPlanning<T: Encodable>(_ value: T, id: UUID, kind: String, date: Date, rows: [StoredPlanningRecord], in target: ModelContext) throws {
        let data = try JSONEncoder().encode(value)
        let matches = rows.filter { $0.id == id }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }
        if let row = matches.first {
            guard row.kind == kind else { throw StoreError.conflict }
            row.payload = data; row.updatedAt = date
        } else { target.insert(StoredPlanningRecord(id: id, kind: kind, payload: data, updatedAt: date)) }
    }
    func save(_ budget: CategoryBudget) throws {
        var next = try snapshot()
        next.categoryBudgets.removeAll { $0.id == budget.id }; next.categoryBudgets.append(budget)
        try BackupFormat.validate(next)
        let rows = try context.fetch(FetchDescriptor<StoredPlanningRecord>())
        try commit { try upsertPlanning(budget, id: budget.id, kind: "categoryBudget", date: budget.updatedAt, rows: rows, in: context) }
    }
    func save(_ plan: RecurringPlan) throws {
        var next = try snapshot()
        next.recurringPlans.removeAll { $0.id == plan.id }; next.recurringPlans.append(plan)
        try BackupFormat.validate(next)
        let rows = try context.fetch(FetchDescriptor<StoredPlanningRecord>())
        try commit { try upsertPlanning(plan, id: plan.id, kind: "recurringPlan", date: plan.updatedAt, rows: rows, in: context) }
    }
    func deletePlan(id: UUID) throws {
        let current = try snapshot()
        let occurrenceIds = Set(current.occurrences.filter { $0.planId == id }.map(\.id))
        let rows = try context.fetch(FetchDescriptor<StoredPlanningRecord>()).filter {
            ($0.kind == "recurringPlan" && $0.id == id) || ($0.kind == "occurrence" && occurrenceIds.contains($0.id))
        }
        try commit { rows.forEach(context.delete) }
    }
    func resolve(_ occurrence: PlanOccurrence, transaction: Transaction?) throws {
        var next = try snapshot()
        try BackupFormat.validate(next)
        guard !next.occurrences.contains(where: { $0.key == occurrence.key }) else { throw StoreError.conflict }
        guard let plan = next.recurringPlans.first(where: { $0.id == occurrence.planId }), plan.isEnabled else { throw StoreError.changed }
        let calendar = Month.calendar
        let start = calendar.startOfDay(for: plan.startDate)
        let days = calendar.dateComponents([.day], from: start, to: occurrence.dueDate).day ?? -1
        let index: Int
        switch plan.recurrence {
        case .daily: index = days
        case .weekly: guard days % 7 == 0 else { throw StoreError.changed }; index = days / 7
        case .monthly: index = calendar.dateComponents([.month], from: Month(date: start).start, to: Month(date: occurrence.dueDate).start).month ?? -1
        }
        guard plan.date(at: index) == occurrence.dueDate,
              occurrence.dueDate <= calendar.startOfDay(for: Date()) else { throw StoreError.changed }
        if let transaction {
            guard occurrence.status == .recorded, transaction.id == occurrence.transactionId,
                  transaction.source == .recurring, transaction.type == plan.type,
                  !next.transactions.contains(where: { $0.id == transaction.id }) else { throw StoreError.invalidData }
            try AmountValidator.validate(transaction, category: next.categories.first { $0.id == transaction.categoryId })
            next.transactions.append(transaction)
        } else { guard occurrence.status == .skipped, occurrence.transactionId == nil else { throw StoreError.invalidData } }
        next.occurrences.append(occurrence); try BackupFormat.validate(next)
        let rows = try context.fetch(FetchDescriptor<StoredPlanningRecord>())
        try commit {
            if let transaction { context.insert(StoredTransaction(transaction)) }
            try upsertPlanning(occurrence, id: occurrence.id, kind: "occurrence", date: occurrence.updatedAt, rows: rows, in: context)
        }
    }
    func seed() throws {
        let current = try snapshot()
        var next = current
        let names: [(TransactionType,[String])] = [(.expense,["食費","日用品","交通費","住居費","医療費","娯楽費","その他"]),(.income,["給与","その他"])]
        var index = 1
        for (type, list) in names {
            for (order,name) in list.enumerated() {
                let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
                if !next.categories.contains(where: { $0.id == id }) {
                    next.categories.append(.init(id: id, name: name, type: type, sortOrder: order, createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)))
                }
                index += 1
            }
        }
        if next != current {
            let isolated = ModelContext(container); isolated.autosaveEnabled = false
            do {
                for value in next.categories where !current.categories.contains(where: { $0.id == value.id }) {
                    isolated.insert(StoredCategory(value))
                }
                try beforeSave(); try isolated.save()
            } catch { isolated.rollback(); throw error }
        }
    }
}
