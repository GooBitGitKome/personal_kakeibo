import Foundation
import PersonalKakeiboDomain

/// Application operations are independent of SwiftUI and SwiftData.
@MainActor public struct TransactionUseCases {
    private let transactions: any TransactionRepository
    private let categories: any CategoryRepository

    public init(transactions: any TransactionRepository, categories: any CategoryRepository) {
        self.transactions = transactions
        self.categories = categories
    }

    @discardableResult
    public func create(type: TransactionType, amountText: String, categoryId: UUID,
                       occurredAt: Date, memo: String = "", now: Date = Date()) throws -> Transaction {
        let amount = try AmountValidator.parse(amountText)
        guard memo.count <= 1000 else { throw KakeiboError.invalidMemo }
        let value = Transaction(type: type, amount: amount, categoryId: categoryId,
                                occurredAt: occurredAt, memo: memo, createdAt: now, updatedAt: now)
        try AmountValidator.validate(value, category: try category(id: categoryId))
        try transactions.save(value)
        return value
    }

    @discardableResult
    public func update(id: UUID, type: TransactionType, amountText: String, categoryId: UUID,
                       occurredAt: Date, memo: String, now: Date = Date()) throws -> Transaction {
        guard let previous = try transactions.find(id: id) else { throw KakeiboError.notFound }
        guard memo.count <= 1000 else { throw KakeiboError.invalidMemo }
        var value = previous
        value.type = type
        value.amount = try AmountValidator.parse(amountText)
        value.categoryId = categoryId
        value.occurredAt = occurredAt
        value.memo = memo
        value.updatedAt = now
        try AmountValidator.validate(value, category: try category(id: categoryId), previous: previous)
        try transactions.save(value)
        return value
    }

    /// Presentation must obtain the user's delete confirmation before invoking this operation.
    public func delete(id: UUID) throws {
        try transactions.delete(id: id)
    }

    private func category(id: UUID) throws -> PersonalKakeiboDomain.Category? {
        let matches = try categories.allCategories().filter { $0.id == id }
        guard matches.count <= 1 else { throw KakeiboError.duplicateID }
        return matches.first
    }
}
