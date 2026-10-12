import Foundation

public enum AmountValidator {
    public static func parse(_ text: String) throws -> Int64 {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int64(text), value > 0 else { throw KakeiboError.invalidAmount }
        return value
    }

    public static func validate(_ transaction: Transaction, category: Category?,
                                previous: Transaction? = nil) throws {
        guard transaction.amount > 0 else { throw KakeiboError.invalidAmount }
        guard let category, category.id == transaction.categoryId else { throw KakeiboError.missingCategory }
        guard category.type == transaction.type else { throw KakeiboError.categoryTypeMismatch }
        if category.isArchived {
            guard let previous, previous.id == transaction.id,
                  previous.categoryId == category.id, previous.type == transaction.type else {
                throw KakeiboError.archivedCategory
            }
        }
    }
}

public struct MonthlySummary: Equatable, Sendable {
    public let income: Int64
    public let expense: Int64
    public let balance: Int64
    public let expensesByCategory: [UUID: Int64]

    public static func calculate(_ transactions: [Transaction], in range: Range<Date>) throws -> Self {
        var income: Int64 = 0
        var expense: Int64 = 0
        var grouped: [UUID: Int64] = [:]
        for transaction in transactions where range.contains(transaction.occurredAt) {
            guard transaction.amount > 0 else { throw KakeiboError.invalidAmount }
            switch transaction.type {
            case .income: income = try checkedAdd(income, transaction.amount)
            case .expense:
                expense = try checkedAdd(expense, transaction.amount)
                grouped[transaction.categoryId] = try checkedAdd(grouped[transaction.categoryId, default: 0], transaction.amount)
            }
        }
        let (balance, overflow) = income.subtractingReportingOverflow(expense)
        guard !overflow else { throw KakeiboError.overflow }
        return Self(income: income, expense: expense, balance: balance, expensesByCategory: grouped)
    }
}

private func checkedAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
    let (result, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw KakeiboError.overflow }
    return result
}
