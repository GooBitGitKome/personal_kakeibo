import Foundation

@MainActor public protocol TransactionRepository {
    func save(_ transaction: Transaction) throws
    func find(id: UUID) throws -> Transaction?
    /// Includes the start and excludes the end; the caller supplies the month boundaries.
    func transactions(in range: Range<Date>, categoryId: UUID?) throws -> [Transaction]
    func delete(id: UUID) throws
    func allTransactions() throws -> [Transaction]
}

@MainActor public protocol CategoryRepository {
    func allCategories() throws -> [Category]
    func categories(type: TransactionType) throws -> [Category]
    func save(_ category: Category) throws
    func reorder(ids: [UUID]) throws
    func setArchived(id: UUID, archived: Bool) throws
}

@MainActor public protocol BudgetRepository {
    func budget(monthKey: String) throws -> Budget?
    func save(_ budget: Budget) throws
    func allBudgets() throws -> [Budget]
}

public struct BackupSnapshot: Equatable, Sendable {
    public var transactions: [Transaction]
    public var categories: [Category]
    public var budgets: [Budget]
    public var categoryBudgets: [CategoryBudget]
    public var recurringPlans: [RecurringPlan]
    public var occurrences: [PlanOccurrence]
    public init(transactions: [Transaction], categories: [Category], budgets: [Budget], categoryBudgets: [CategoryBudget] = [], recurringPlans: [RecurringPlan] = [], occurrences: [PlanOccurrence] = []) {
        self.transactions = transactions; self.categories = categories; self.budgets = budgets
        self.categoryBudgets = categoryBudgets; self.recurringPlans = recurringPlans; self.occurrences = occurrences
    }
}

@MainActor public protocol BackupRepository {
    func snapshot() throws -> BackupSnapshot
    /// Apply a fully validated snapshot in one local save, preserving prior data on failure.
    func apply(_ snapshot: BackupSnapshot, expecting current: BackupSnapshot) throws
}
