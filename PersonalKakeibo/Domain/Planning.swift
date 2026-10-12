import Foundation

public struct CategoryBudget: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var categoryId: UUID
    public var dailyAmount: Int64?
    public var monthlyAmount: Int64?
    public var reminds: Bool
    public var updatedAt: Date
    public init(id: UUID = UUID(), categoryId: UUID, dailyAmount: Int64? = nil, monthlyAmount: Int64? = nil, reminds: Bool = false, updatedAt: Date = Date()) {
        self.id = id; self.categoryId = categoryId; self.dailyAmount = dailyAmount
        self.monthlyAmount = monthlyAmount; self.reminds = reminds; self.updatedAt = updatedAt
    }
}

public enum Recurrence: String, Codable, CaseIterable, Sendable {
    case daily, weekly, monthly
    public var label: String { switch self { case .daily: "毎日"; case .weekly: "毎週"; case .monthly: "毎月" } }
}

public struct RecurringPlan: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var type: TransactionType
    public var categoryId: UUID
    public var amount: Int64
    public var memo: String
    public var startDate: Date
    public var recurrence: Recurrence
    public var isEnabled: Bool
    public var reminds: Bool
    public var updatedAt: Date
    public init(id: UUID = UUID(), type: TransactionType, categoryId: UUID, amount: Int64, memo: String = "", startDate: Date = Date(), recurrence: Recurrence = .monthly, isEnabled: Bool = true, reminds: Bool = false, updatedAt: Date = Date()) {
        self.id = id; self.type = type; self.categoryId = categoryId; self.amount = amount
        self.memo = memo; self.startDate = startDate; self.recurrence = recurrence
        self.isEnabled = isEnabled; self.reminds = reminds; self.updatedAt = updatedAt
    }
    /// The day in the original start date remains the monthly anchor, including after February.
    public func date(at index: Int) -> Date? {
        guard index >= 0, Planning.isSupportedDate(startDate) else { return nil }
        let calendar = Month.calendar
        let start = calendar.startOfDay(for: startDate)
        switch recurrence {
        case .daily: return calendar.date(byAdding: .day, value: index, to: start)
        case .weekly:
            let days = index.multipliedReportingOverflow(by: 7)
            return days.overflow ? nil : calendar.date(byAdding: .day, value: days.partialValue, to: start)
        case .monthly:
            guard let month = calendar.date(byAdding: .month, value: index, to: Month(date: start).start),
                  let days = calendar.range(of: .day, in: .month, for: month) else { return nil }
            return calendar.date(byAdding: .day, value: min(calendar.component(.day, from: start), days.count) - 1, to: month)
        }
    }
}

public enum OccurrenceStatus: String, Codable, Sendable { case recorded, skipped }

public struct PlanOccurrence: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var planId: UUID
    public var dueDate: Date
    public var status: OccurrenceStatus
    public var transactionId: UUID?
    public var updatedAt: Date
    public init(id: UUID = UUID(), planId: UUID, dueDate: Date, status: OccurrenceStatus, transactionId: UUID? = nil, updatedAt: Date = Date()) {
        self.id = id; self.planId = planId; self.dueDate = Month.calendar.startOfDay(for: dueDate)
        self.status = status; self.transactionId = transactionId; self.updatedAt = updatedAt
    }
    public var key: String { Self.key(planId: planId, date: dueDate) }
    public static func key(planId: UUID, date: Date) -> String {
        let parts = Month.calendar.dateComponents([.year, .month, .day], from: date)
        return "\(planId.uuidString):\(parts.year!)-\(parts.month!)-\(parts.day!)"
    }
}

public struct DuePlan: Identifiable, Equatable, Sendable {
    public var plan: RecurringPlan
    public var date: Date
    public var id: String { PlanOccurrence.key(planId: plan.id, date: date) }
    public init(plan: RecurringPlan, date: Date) { self.plan = plan; self.date = date }
}

public enum Planning {
    private static let earliestDate = Month.calendar.date(from: DateComponents(year: 1, month: 1, day: 1))!
    private static let latestDate = Month.calendar.date(from: DateComponents(year: 10000, month: 1, day: 1))!
    public static func isSupportedDate(_ date: Date) -> Bool { date >= earliestDate && date < latestDate }
    /// Limits the visible backlog, without discarding older unresolved occurrences.
    public static func pending(plans: [RecurringPlan], occurrences: [PlanOccurrence], through today: Date, limit: Int = 200) -> [DuePlan] {
        guard limit > 0, isSupportedDate(today) else { return [] }
        let completed = Set(occurrences.map(\.key))
        let end = Month.calendar.startOfDay(for: today)
        var results: [DuePlan] = []
        for plan in plans where plan.isEnabled {
            var index = 0; var count = 0
            while let date = plan.date(at: index), date <= end {
                let due = DuePlan(plan: plan, date: date)
                if !completed.contains(due.id) { results.append(due); count += 1 }
                if count >= limit { break }
                index += 1
            }
        }
        return Array(results.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }.prefix(limit))
    }

    /// Uses an explicit daily budget, otherwise a whole-yen estimate for the Tokyo month.
    public static func dailyEstimate(budget: CategoryBudget, date: Date) -> Int64? {
        if let daily = budget.dailyAmount { return daily }
        guard let monthly = budget.monthlyAmount, isSupportedDate(date),
              let days = Month.calendar.range(of: .day, in: .month, for: date) else { return nil }
        return monthly / Int64(days.count)
    }

    public static func remaining(budget: CategoryBudget, transactions: [Transaction], date: Date) throws -> (daily: Int64?, monthly: Int64?) {
        let calendar = Month.calendar
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { throw KakeiboError.invalidMonth }
        let relevant = transactions.filter { $0.type == .expense && $0.categoryId == budget.categoryId }
        let daily = try MonthlySummary.calculate(relevant, in: start..<end).expense
        let monthly = try MonthlySummary.calculate(relevant, in: Month(date: date).range).expense
        return (budget.dailyAmount.map { $0 - daily }, budget.monthlyAmount.map { $0 - monthly })
    }
}

@MainActor public protocol PlanningRepository {
    func save(_ budget: CategoryBudget) throws
    func save(_ plan: RecurringPlan) throws
    /// Deletes a plan and its occurrences, preserving recorded transactions.
    func deletePlan(id: UUID) throws
    /// Atomically records a transaction and its occurrence, or skips the occurrence.
    func resolve(_ occurrence: PlanOccurrence, transaction: Transaction?) throws
}
