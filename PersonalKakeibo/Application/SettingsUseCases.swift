import Foundation
import PersonalKakeiboDomain

@MainActor public struct SettingsUseCases {
    private let categories: any CategoryRepository
    private let budgets: any BudgetRepository
    public init(categories: any CategoryRepository, budgets: any BudgetRepository) {
        self.categories = categories; self.budgets = budgets
    }
    public func addCategory(name: String, type: TransactionType) throws {
        let name = try validatedName(name)
        let list = try categories.categories(type: type)
        let next = (list.map(\.sortOrder).max() ?? -1).addingReportingOverflow(1)
        guard !next.overflow else { throw KakeiboError.overflow }
        try categories.save(PersonalKakeiboDomain.Category(name: name, type: type, sortOrder: next.partialValue))
    }
    public func renameCategory(_ category: PersonalKakeiboDomain.Category, name: String) throws {
        var value = category; value.name = try validatedName(name); value.updatedAt = Date()
        try categories.save(value)
    }
    public func archive(id: UUID, archived: Bool) throws { try categories.setArchived(id: id, archived: archived) }
    public func reorder(ids: [UUID]) throws { try categories.reorder(ids: ids) }
    public func setBudget(month: Month, amountText: String) throws {
        let amount = try AmountValidator.parse(amountText)
        var value = try budgets.budget(monthKey: month.key) ?? Budget(monthKey: month.key, amount: amount)
        value.amount = amount; value.updatedAt = Date(); try budgets.save(value)
    }
    private func validatedName(_ input: String) throws -> String {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { throw KakeiboError.invalidCategoryName }
        return name
    }
}
