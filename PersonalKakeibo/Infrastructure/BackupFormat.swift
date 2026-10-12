import Foundation
import PersonalKakeiboDomain

struct BackupFile: Codable {
    var schemaVersion: Int = 2
    var exportedAt: Date = Date()
    var transactions: [Transaction]
    var categories: [PersonalKakeiboDomain.Category]
    var budgets: [Budget]
    var categoryBudgets: [CategoryBudget]? = nil
    var recurringPlans: [RecurringPlan]? = nil
    var occurrences: [PlanOccurrence]? = nil
    var snapshot: BackupSnapshot { .init(transactions: transactions, categories: categories, budgets: budgets, categoryBudgets: categoryBudgets ?? [], recurringPlans: recurringPlans ?? [], occurrences: occurrences ?? []) }
}
struct ImportPreview {
    let original: BackupSnapshot
    let merged: BackupSnapshot
    let additions: Int
    let updates: Int
}
enum BackupFormat {
    static func dateString(_ date: Date, using base: ISO8601DateFormatter) -> String {
        let reference = date.timeIntervalSinceReferenceDate
        let fraction = reference - floor(reference)
        let nanos = min(999_999_999, Int64((fraction * 1_000_000_000).rounded()))
        let seconds = Date(timeIntervalSinceReferenceDate: floor(reference))
        return String(base.string(from: seconds).dropLast()) + String(format: ".%09lldZ", nanos)
    }
    static func parseDate(_ value: String, using base: ISO8601DateFormatter) -> Date? {
        guard value.hasSuffix("Z"), let dot = value.lastIndex(of: ".") else { return nil }
        let fraction = value[value.index(after: dot)..<value.index(before: value.endIndex)]
        guard !fraction.isEmpty, fraction.count <= 9, fraction.utf8.allSatisfy({ (48...57).contains($0) }),
              let fractionValue = Double("0." + fraction) else { return nil }
        guard let seconds = base.date(from: String(value[..<dot]) + "Z") else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds.timeIntervalSinceReferenceDate + fractionValue)
    }
    static func formatter() -> ISO8601DateFormatter {
        let value = ISO8601DateFormatter(); value.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return value
    }
    static func encode(_ snapshot: BackupSnapshot) throws -> Data {
        try validate(snapshot)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dates = LockedBackupDates()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer(); try container.encode(dates.string(from: date))
        }
        return try encoder.encode(BackupFile(transactions: snapshot.transactions, categories: snapshot.categories, budgets: snapshot.budgets, categoryBudgets: snapshot.categoryBudgets, recurringPlans: snapshot.recurringPlans, occurrences: snapshot.occurrences))
    }
    static func decode(_ data: Data) throws -> BackupSnapshot {
        guard data.count <= 50 * 1024 * 1024 else { throw StoreError.invalidData }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StoreError.invalidData }
        for key in ["transactions", "budgets", "recurringPlans", "categoryBudgets"] {
            if object[key] == nil && ["recurringPlans", "categoryBudgets"].contains(key) { continue }
            guard let rows = object[key] as? [[String: Any]] else { throw StoreError.invalidData }
            for row in rows {
                for field in key == "categoryBudgets" ? ["dailyAmount", "monthlyAmount"] : ["amount"] {
                    if key == "categoryBudgets" && (row[field] == nil || row[field] is NSNull) { continue }
                    guard let amount = row[field] as? NSNumber,
                          !["d", "f", "c"].contains(String(cString: amount.objCType)) else { throw KakeiboError.invalidAmount }
                }
            }
        }
        let decoder = JSONDecoder()
        let dates = LockedBackupDates()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            guard let date = dates.date(from: value) else { throw StoreError.invalidData }; return date
        }
        let file = try decoder.decode(BackupFile.self, from: data)
        guard [1, 2].contains(file.schemaVersion) else { throw StoreError.unsupported }
        try validate(file.snapshot); return file.snapshot
    }
    static func validate(_ snapshot: BackupSnapshot) throws {
        let ids = snapshot.transactions.map(\.id) + snapshot.categories.map(\.id) + snapshot.budgets.map(\.id) + snapshot.categoryBudgets.map(\.id) + snapshot.recurringPlans.map(\.id) + snapshot.occurrences.map(\.id)
        guard Set(ids).count == ids.count else { throw KakeiboError.duplicateID }
        guard Set(snapshot.budgets.map(\.monthKey)).count == snapshot.budgets.count else { throw StoreError.conflict }
        for category in snapshot.categories {
            guard !category.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  category.name.count <= 40 else { throw KakeiboError.invalidCategoryName }
        }
        let categories = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0) })
        for entry in snapshot.transactions {
            guard entry.memo.count <= 1000 else { throw StoreError.invalidData }
            try AmountValidator.validate(entry, category: categories[entry.categoryId], previous: entry)
        }
        for budget in snapshot.budgets {
            _ = try Month(key: budget.monthKey)
            guard budget.amount > 0 else { throw KakeiboError.invalidAmount }
        }
        guard Set(snapshot.categoryBudgets.map(\.categoryId)).count == snapshot.categoryBudgets.count,
              Set(snapshot.occurrences.map(\.key)).count == snapshot.occurrences.count else { throw StoreError.conflict }
        for budget in snapshot.categoryBudgets {
            guard categories[budget.categoryId]?.type == .expense else { throw KakeiboError.missingCategory }
            guard budget.dailyAmount.map({ $0 > 0 }) ?? true,
                  budget.monthlyAmount.map({ $0 > 0 }) ?? true else { throw KakeiboError.invalidAmount }
        }
        for plan in snapshot.recurringPlans {
            guard plan.memo.count <= 1000, Planning.isSupportedDate(plan.startDate) else { throw StoreError.invalidData }
            let entry = Transaction(type: plan.type, amount: plan.amount, categoryId: plan.categoryId, occurredAt: plan.startDate)
            try AmountValidator.validate(entry, category: categories[plan.categoryId], previous: entry)
        }
        let planIds = Set(snapshot.recurringPlans.map(\.id))
        for occurrence in snapshot.occurrences {
            guard planIds.contains(occurrence.planId), Planning.isSupportedDate(occurrence.dueDate),
                  occurrence.dueDate == Month.calendar.startOfDay(for: occurrence.dueDate),
                  (occurrence.status == .recorded) == (occurrence.transactionId != nil) else { throw StoreError.invalidData }
            // Deleted transactions deliberately leave their occurrence resolved.
            if let id = occurrence.transactionId, let entry = snapshot.transactions.first(where: { $0.id == id }) {
                guard entry.source == .recurring else { throw StoreError.invalidData }
            }
        }
    }
    static func equivalent(_ a: BackupSnapshot, _ b: BackupSnapshot) -> Bool {
        a.transactions.sorted { $0.id.uuidString < $1.id.uuidString } == b.transactions.sorted { $0.id.uuidString < $1.id.uuidString }
        && a.categories.sorted { $0.id.uuidString < $1.id.uuidString } == b.categories.sorted { $0.id.uuidString < $1.id.uuidString }
        && a.budgets.sorted { $0.id.uuidString < $1.id.uuidString } == b.budgets.sorted { $0.id.uuidString < $1.id.uuidString }
        && a.categoryBudgets.sorted { $0.id.uuidString < $1.id.uuidString } == b.categoryBudgets.sorted { $0.id.uuidString < $1.id.uuidString }
        && a.recurringPlans.sorted { $0.id.uuidString < $1.id.uuidString } == b.recurringPlans.sorted { $0.id.uuidString < $1.id.uuidString }
        && a.occurrences.sorted { $0.id.uuidString < $1.id.uuidString } == b.occurrences.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    static func preview(_ incoming: BackupSnapshot, current: BackupSnapshot, overwrite: Bool) throws -> ImportPreview {
        try validate(incoming); try validate(current)
        for category in incoming.categories {
            if let previous = current.categories.first(where: { $0.id == category.id }), previous.type != category.type {
                throw KakeiboError.categoryTypeMismatch
            }
        }
        var additions = 0; var updates = 0
        func merge<T: Identifiable & Equatable>(_ existing: [T], _ imported: [T]) throws -> [T] where T.ID == UUID {
            var result = existing
            var indices = Dictionary(uniqueKeysWithValues: existing.enumerated().map { ($0.element.id, $0.offset) })
            for value in imported {
                if let index = indices[value.id] {
                    if result[index] != value {
                        guard overwrite else { throw StoreError.conflict }
                        result[index] = value; updates += 1
                    }
                } else { indices[value.id] = result.count; result.append(value); additions += 1 }
            }
            return result
        }
        let merged = try BackupSnapshot(transactions: merge(current.transactions, incoming.transactions), categories: merge(current.categories, incoming.categories), budgets: merge(current.budgets, incoming.budgets), categoryBudgets: merge(current.categoryBudgets, incoming.categoryBudgets), recurringPlans: merge(current.recurringPlans, incoming.recurringPlans), occurrences: merge(current.occurrences, incoming.occurrences))
        try validate(merged)
        return ImportPreview(original: current, merged: merged, additions: additions, updates: updates)
    }
    static func csv(_ snapshot: BackupSnapshot) throws -> Data {
        try validate(snapshot)
        let categories = Dictionary(uniqueKeysWithValues: snapshot.categories.map { ($0.id, $0.name) })
        func quote(_ text: String, userInput: Bool = false) -> String {
            var value = text
            if userInput, let first = value.trimmingCharacters(in: .whitespacesAndNewlines).first, "=+-@".contains(first) { value = "'" + value }
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var lines = ["id,type,amount,categoryId,categoryName,occurredAt,memo,source,createdAt,updatedAt"]
        let dates = formatter()
        for entry in snapshot.transactions.sorted(by: { $0.occurredAt < $1.occurredAt }) {
            lines.append([quote(entry.id.uuidString), quote(entry.type.rawValue), String(entry.amount), quote(entry.categoryId.uuidString), quote(categories[entry.categoryId]!, userInput: true), quote(dates.string(from: entry.occurredAt)), quote(entry.memo, userInput: true), quote(entry.source.rawValue), quote(dates.string(from: entry.createdAt)), quote(dates.string(from: entry.updatedAt))].joined(separator: ","))
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

// Encoder/decoder custom strategies are Sendable. Serialize access to their shared formatter.
private final class LockedBackupDates: @unchecked Sendable {
    private let formatter = ISO8601DateFormatter()
    private let lock = NSLock()
    init() { formatter.formatOptions = [.withInternetDateTime] }
    func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return BackupFormat.dateString(date, using: formatter)
    }
    func date(from string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return BackupFormat.parseDate(string, using: formatter)
    }
}
