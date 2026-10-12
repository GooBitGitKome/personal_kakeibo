import Foundation
import PersonalKakeiboDomain

@MainActor public struct PlanningUseCases {
    private let planning: any PlanningRepository
    private let categories: any CategoryRepository
    public init(planning: any PlanningRepository, categories: any CategoryRepository) {
        self.planning = planning; self.categories = categories
    }
    public func setBudget(previous: CategoryBudget?, categoryId: UUID, daily: String, monthly: String, reminds: Bool) throws {
        guard let category = try categories.allCategories().first(where: { $0.id == categoryId }), category.type == .expense, !category.isArchived else { throw KakeiboError.missingCategory }
        let day = daily.trimmingCharacters(in: .whitespacesAndNewlines)
        let month = monthly.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = previous ?? CategoryBudget(categoryId: categoryId)
        value.dailyAmount = day.isEmpty ? nil : try AmountValidator.parse(day)
        value.monthlyAmount = month.isEmpty ? nil : try AmountValidator.parse(month)
        value.reminds = reminds && (value.dailyAmount != nil || value.monthlyAmount != nil)
        value.updatedAt = Date()
        try planning.save(value)
    }
    public func savePlan(_ plan: RecurringPlan) throws {
        let transaction = Transaction(type: plan.type, amount: plan.amount, categoryId: plan.categoryId, occurredAt: plan.startDate, memo: plan.memo)
        guard plan.memo.count <= 1000 else { throw KakeiboError.invalidMemo }
        guard Planning.isSupportedDate(plan.startDate) else { throw KakeiboError.invalidMonth }
        let category = try categories.allCategories().first { $0.id == plan.categoryId }
        // Disabled plans may retain an archived category, but cannot be reactivated with it.
        try AmountValidator.validate(transaction, category: category, previous: plan.isEnabled ? nil : transaction)
        try planning.save(plan)
    }
    public func deletePlan(id: UUID) throws { try planning.deletePlan(id: id) }
    public func record(_ due: DuePlan, amount: String, categoryId: UUID, date: Date, memo: String) throws {
        guard memo.count <= 1000 else { throw KakeiboError.invalidMemo }
        let transaction = Transaction(type: due.plan.type, amount: try AmountValidator.parse(amount), categoryId: categoryId, occurredAt: date, memo: memo, source: .recurring)
        try AmountValidator.validate(transaction, category: try categories.allCategories().first { $0.id == categoryId })
        try planning.resolve(PlanOccurrence(planId: due.plan.id, dueDate: due.date, status: .recorded, transactionId: transaction.id), transaction: transaction)
    }
    public func skip(_ due: DuePlan) throws {
        try planning.resolve(PlanOccurrence(planId: due.plan.id, dueDate: due.date, status: .skipped), transaction: nil)
    }
}
