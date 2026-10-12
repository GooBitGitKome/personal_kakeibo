import XCTest
import PersonalKakeiboDomain

final class PlanningTests: XCTestCase {
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        Month.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    func testMonthlyAnchorSurvivesShortMonthsAndLeapYears() throws {
        let plan = RecurringPlan(type: .expense, categoryId: UUID(), amount: 100, startDate: date(2024, 1, 31), recurrence: .monthly)
        XCTAssertEqual(plan.date(at: 1), date(2024, 2, 29))
        XCTAssertEqual(plan.date(at: 2), date(2024, 3, 31))
        XCTAssertEqual(plan.date(at: 13), date(2025, 2, 28))
        XCTAssertEqual(plan.date(at: 14), date(2025, 3, 31))
        XCTAssertNil(plan.date(at: -1))
        var invalid = plan; invalid.startDate = Date(timeIntervalSince1970: .infinity)
        XCTAssertNil(invalid.date(at: 0))
    }
    func testDailyWeeklyDueDatesAndResolvedOccurrences() throws {
        let daily = RecurringPlan(type: .expense, categoryId: UUID(), amount: 100, startDate: date(2026, 10, 1, 18), recurrence: .daily)
        let weekly = RecurringPlan(type: .income, categoryId: UUID(), amount: 100, startDate: date(2026, 9, 30), recurrence: .weekly)
        let resolved = PlanOccurrence(planId: daily.id, dueDate: date(2026, 10, 1), status: .skipped)
        let pending = Planning.pending(plans: [daily, weekly], occurrences: [resolved], through: date(2026, 10, 7, 12))
        XCTAssertEqual(pending.filter { $0.plan.id == daily.id }.count, 6)
        XCTAssertEqual(pending.filter { $0.plan.id == weekly.id }.map(\.date), [date(2026, 9, 30), date(2026, 10, 7)])
        var disabled = daily; disabled.isEnabled = false
        XCTAssertTrue(Planning.pending(plans: [disabled], occurrences: [], through: date(2026, 10, 7)).isEmpty)
        XCTAssertEqual(Planning.pending(plans: [daily], occurrences: [], through: date(2026, 10, 7), limit: 2).map(\.date), [date(2026, 10, 1), date(2026, 10, 2)])
        XCTAssertTrue(Planning.pending(plans: [daily], occurrences: [], through: date(2026, 9, 30)).isEmpty)
        XCTAssertTrue(Planning.pending(plans: [daily], occurrences: [], through: date(2026, 10, 7), limit: 0).isEmpty)
    }
    func testBudgetTokyoBoundariesAndOverspending() throws {
        let category = UUID()
        let budget = CategoryBudget(categoryId: category, dailyAmount: 500, monthlyAmount: 2000)
        let transactions = [
            Transaction(type: .expense, amount: 800, categoryId: category, occurredAt: date(2026, 10, 1)),
            Transaction(type: .expense, amount: 600, categoryId: category, occurredAt: date(2026, 10, 1, 23)),
            Transaction(type: .expense, amount: 200, categoryId: category, occurredAt: date(2026, 10, 2)),
            Transaction(type: .expense, amount: 9000, categoryId: category, occurredAt: date(2026, 9, 30, 23)),
            Transaction(type: .income, amount: 9000, categoryId: category, occurredAt: date(2026, 10, 1)),
            Transaction(type: .expense, amount: 9000, categoryId: UUID(), occurredAt: date(2026, 10, 1))
        ]
        let first = try Planning.remaining(budget: budget, transactions: transactions, date: date(2026, 10, 1))
        XCTAssertEqual(first.daily, -900); XCTAssertEqual(first.monthly, 400)
        let second = try Planning.remaining(budget: budget, transactions: transactions, date: date(2026, 10, 2))
        XCTAssertEqual(second.daily, 300)
        let next = try Planning.remaining(budget: budget, transactions: transactions, date: date(2026, 11, 1))
        XCTAssertEqual(next.daily, 500); XCTAssertEqual(next.monthly, 2000)
        let cleared = try Planning.remaining(budget: CategoryBudget(categoryId: category), transactions: transactions, date: date(2026, 10, 1))
        XCTAssertNil(cleared.daily); XCTAssertNil(cleared.monthly)
    }
    func testBudgetOverflowIsReported() throws {
        let id = UUID()
        let transactions = [Int64.max, 1].map { Transaction(type: .expense, amount: $0, categoryId: id, occurredAt: date(2026, 10, 1)) }
        XCTAssertThrowsError(try Planning.remaining(budget: CategoryBudget(categoryId: id, dailyAmount: 100), transactions: transactions, date: date(2026, 10, 1)))
    }
    func testDailyBudgetEstimateUsesTokyoMonthAndDailyOverride() {
        var budget = CategoryBudget(categoryId: UUID(), monthlyAmount: 31000)
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 2, 1)), 1107)
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2024, 2, 1)), 1068)
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 4, 1)), 1033)
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 10, 1)), 1000)
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 9, 30, 23)), 1033)
        budget.dailyAmount = 700
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 2, 1)), 700)
        budget.monthlyAmount = nil
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 2, 1)), 700)
        budget.dailyAmount = nil
        XCTAssertNil(Planning.dailyEstimate(budget: budget, date: date(2026, 2, 1)))
        budget.monthlyAmount = 1
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 2, 1)), 0)
        budget.monthlyAmount = Int64.max
        XCTAssertEqual(Planning.dailyEstimate(budget: budget, date: date(2026, 2, 1)), Int64.max / 28)
        XCTAssertNil(Planning.dailyEstimate(budget: budget, date: Date(timeIntervalSince1970: .infinity)))
    }
    func testReminderSlotsCapDuplicatesAndDisabledSlots() {
        XCTAssertEqual(ReminderSlot.defaults.map(\.hour), [7, 12, 18])
        XCTAssertTrue(ReminderSlot.validate(ReminderSlot.defaults))
        var slots = ReminderSlot.defaults
        slots[1].hour = 7
        XCTAssertFalse(ReminderSlot.validate(slots))
        slots[1].isEnabled = false
        XCTAssertTrue(ReminderSlot.validate(slots))
        slots.append(ReminderSlot(id: 3, hour: 20))
        XCTAssertFalse(ReminderSlot.validate(slots))
        XCTAssertFalse(ReminderSlot.validate([ReminderSlot(id: 0, hour: 24)]))
    }
}
