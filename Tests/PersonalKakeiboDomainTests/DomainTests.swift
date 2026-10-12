import Foundation
import XCTest
@testable import PersonalKakeiboDomain

final class DomainTests: XCTestCase {
    func testAmountBoundaries() throws {
        XCTAssertEqual(try AmountValidator.parse("1"), 1)
        XCTAssertEqual(try AmountValidator.parse(String(Int64.max)), Int64.max)
        for value in ["", "0", "-1", "1.5", " 1", "1,000", "１２", "9223372036854775808"] {
            XCTAssertThrowsError(try AmountValidator.parse(value)) { XCTAssertEqual($0 as? KakeiboError, .invalidAmount) }
        }
    }

    func testRangeIncludesStartExcludesEndAndGroupsExpenses() throws {
        let start = Date(timeIntervalSince1970: 100)
        let end = Date(timeIntervalSince1970: 200)
        let category = UUID()
        let entries = [
            Transaction(type: .expense, amount: 50, categoryId: category, occurredAt: start),
            Transaction(type: .income, amount: 80, categoryId: UUID(), occurredAt: start),
            Transaction(type: .expense, amount: 999, categoryId: category, occurredAt: end)
        ]
        let summary = try MonthlySummary.calculate(entries, in: start..<end)
        XCTAssertEqual(summary.income, 80)
        XCTAssertEqual(summary.expense, 50)
        XCTAssertEqual(summary.balance, 30)
        XCTAssertEqual(summary.expensesByCategory[category], 50)
        XCTAssertEqual(try MonthlySummary.calculate([], in: start..<end).balance, 0)
    }

    func testOverflowIsExplicitError() {
        let date = Date()
        let entries = [Int64.max, 1].map { Transaction(type: .expense, amount: $0, categoryId: UUID(), occurredAt: date) }
        XCTAssertThrowsError(try MonthlySummary.calculate(entries, in: date..<date.addingTimeInterval(1))) {
            XCTAssertEqual($0 as? KakeiboError, .overflow)
        }
    }

    func testArchivedCategoryCanOnlyBeRetainedOnEdit() throws {
        let category = Category(name: "食費", type: .expense, isArchived: true)
        let entry = Transaction(type: .expense, amount: 10, categoryId: category.id, occurredAt: Date())
        XCTAssertThrowsError(try AmountValidator.validate(entry, category: category))
        try AmountValidator.validate(entry, category: category, previous: entry)
        var income = entry
        income.type = .income
        XCTAssertThrowsError(try AmountValidator.validate(income, category: category, previous: entry))
        XCTAssertThrowsError(try AmountValidator.validate(entry, category: nil))
    }
}
