import XCTest
import Foundation
import SwiftData
import PersonalKakeiboDomain
import PersonalKakeiboApplication

final class PersistenceTests: XCTestCase {
    @MainActor func store() throws -> Store {
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return Store(container: try ModelContainer(for: schema, configurations: configuration))
    }
    @MainActor func testCreateUpdateAndDelete() async throws {
        let store = try store(); try store.seed()
        let category = try XCTUnwrap(store.categories(type: .expense).first)
        let useCases = TransactionUseCases(transactions: store, categories: store)
        let entry = try useCases.create(type: .expense, amountText: "50", categoryId: category.id, occurredAt: Date())
        let updated = try useCases.update(id: entry.id, type: .expense, amountText: "70", categoryId: category.id, occurredAt: entry.occurredAt, memo: "架空の買い物")
        XCTAssertEqual(updated.id, entry.id); XCTAssertEqual(updated.createdAt, entry.createdAt)
        XCTAssertEqual(try store.find(id: entry.id)?.amount, 70)
        try store.setArchived(id: category.id, archived: true)
        XCTAssertThrowsError(try useCases.create(type: .expense, amountText: "1", categoryId: category.id, occurredAt: Date()))
        try useCases.delete(id: entry.id); XCTAssertNil(try store.find(id: entry.id))
    }
    @MainActor func testBackupRoundTripAndRepeatedImport() async throws {
        let source = try store(); try source.seed()
        let category = try XCTUnwrap(source.categories(type: .expense).first)
        _ = try TransactionUseCases(transactions: source, categories: source).create(type: .expense, amountText: "120", categoryId: category.id, occurredAt: Date(timeIntervalSince1970: 123456), memo: "架空,\"メモ\"\n次の行")
        try source.save(Budget(monthKey: "2026-02", amount: 10000))
        let snapshot = try source.snapshot()
        let decoded = try BackupFormat.decode(BackupFormat.encode(snapshot))
        XCTAssertTrue(BackupFormat.equivalent(decoded, snapshot))
        XCTAssertEqual(decoded.transactions[0].memo, snapshot.transactions[0].memo)
        let destination = try store()
        let first = try BackupFormat.preview(decoded, current: destination.snapshot(), overwrite: false)
        try destination.apply(first.merged, expecting: first.original)
        let second = try BackupFormat.preview(decoded, current: destination.snapshot(), overwrite: false)
        XCTAssertEqual(second.additions, 0); XCTAssertEqual(second.updates, 0)
        XCTAssertEqual(try destination.allTransactions().count, 1)
        let csv = String(decoding: try BackupFormat.csv(snapshot), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"\"メモ\"\"")); XCTAssertTrue(csv.contains("\n次の行"))
    }
    @MainActor func testInvalidImportAndStalePreviewDoNotWrite() async throws {
        let store = try store(); try store.seed()
        let original = try store.snapshot()
        var invalid = original
        invalid.transactions = [Transaction(type: .expense, amount: 1, categoryId: UUID(), occurredAt: Date())]
        XCTAssertThrowsError(try store.apply(invalid, expecting: original))
        XCTAssertTrue(BackupFormat.equivalent(try store.snapshot(), original))
        try store.save(Budget(monthKey: "2026-10", amount: 100))
        XCTAssertThrowsError(try store.apply(original, expecting: original))
        XCTAssertEqual(try store.allBudgets().count, 1)
    }
    func testTokyoMonthAndLeapYear() throws {
        let month = try Month(key: "2024-02")
        XCTAssertEqual(Month.calendar.dateComponents([.day], from: month.start, to: month.end).day, 29)
        XCTAssertEqual(month.shifted(1).key, "2024-03")
        for key in ["2024-13", "2024-00", "2024-2", "0000-01"] { XCTAssertThrowsError(try Month(key: key)) }
    }
    func testConflictsAndUnknownVersion() throws {
        let category = PersonalKakeiboDomain.Category(name: "架空", type: .expense)
        let snapshot = BackupSnapshot(transactions: [], categories: [category], budgets: [])
        var changed = snapshot; changed.categories[0].name = "変更"
        XCTAssertThrowsError(try BackupFormat.preview(changed, current: snapshot, overwrite: false))
        XCTAssertEqual(try BackupFormat.preview(changed, current: snapshot, overwrite: true).updates, 1)
        let data = try BackupFormat.encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["schemaVersion"] = 99
        let unknown = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try BackupFormat.decode(unknown))
        var duplicated = snapshot; duplicated.categories.append(category)
        XCTAssertThrowsError(try BackupFormat.validate(duplicated))
    }

    @MainActor func testInjectedSaveFailureRollsBackAllChanges() async throws {
        let store = try store(); try store.seed()
        let original = try store.snapshot()
        var merged = original
        merged.categories[0].name = "更新されない名前"
        merged.budgets.append(Budget(monthKey: "2026-10", amount: 100))
        let failing = Store(container: store.container, beforeSave: { throw StoreError.conflict })
        XCTAssertThrowsError(try failing.apply(merged, expecting: original))
        XCTAssertTrue(BackupFormat.equivalent(try store.snapshot(), original))
    }

    func testFractionalDatesAndStrictIntegerImport() throws {
        let category = PersonalKakeiboDomain.Category(name: "架空", type: .expense)
        let entry = Transaction(type: .expense, amount: 1, categoryId: category.id,
                                occurredAt: Date(timeIntervalSinceReferenceDate: 800000000.1234567))
        let snapshot = BackupSnapshot(transactions: [entry], categories: [category], budgets: [])
        let encoded = try BackupFormat.encode(snapshot)
        XCTAssertTrue(BackupFormat.equivalent(try BackupFormat.decode(encoded), snapshot))
        let decimal = Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"amount\" : 1", with: "\"amount\" : 1.5").utf8)
        XCTAssertThrowsError(try BackupFormat.decode(decimal))
        let wholeFloat = Data(String(decoding: encoded, as: UTF8.self).replacingOccurrences(of: "\"amount\" : 1", with: "\"amount\" : 1.0").utf8)
        XCTAssertThrowsError(try BackupFormat.decode(wholeFloat))
    }

    @MainActor func testBudgetAndCategoryRules() async throws {
        let store = try store()
        let settings = SettingsUseCases(categories: store, budgets: store)
        let month = try Month(key: "2026-10")
        XCTAssertNil(try store.budget(monthKey: month.key))
        XCTAssertThrowsError(try settings.setBudget(month: month, amountText: "0"))
        try settings.setBudget(month: month, amountText: "100")
        let first = try XCTUnwrap(store.budget(monthKey: month.key))
        try settings.setBudget(month: month, amountText: "200")
        let updated = try XCTUnwrap(store.budget(monthKey: month.key))
        XCTAssertEqual(first.id, updated.id); XCTAssertEqual(first.createdAt, updated.createdAt)
        XCTAssertEqual(updated.amount, 200)
        XCTAssertThrowsError(try settings.addCategory(name: "   ", type: .expense))
        XCTAssertThrowsError(try settings.addCategory(name: String(repeating: "あ", count: 41), type: .expense))
        try settings.addCategory(name: "架空のカテゴリ", type: .expense)
        let category = try XCTUnwrap(store.allCategories().first)
        XCTAssertThrowsError(try TransactionUseCases(transactions: store, categories: store).create(type: .expense, amountText: "1", categoryId: category.id, occurredAt: Date(), memo: String(repeating: "あ", count: 1001)))
        XCTAssertTrue(try store.allTransactions().isEmpty)
    }

    @MainActor func testDiskStoreSurvivesReopen() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".store")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        let schema = Schema(versionedSchema: KakeiboSchema.self)
        let configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        var original: BackupSnapshot!
        do {
            let store = Store(container: try ModelContainer(for: schema, configurations: configuration))
            try store.seed()
            let category = try XCTUnwrap(store.categories(type: .expense).first)
            _ = try TransactionUseCases(transactions: store, categories: store).create(type: .expense, amountText: "10", categoryId: category.id, occurredAt: Date())
            try store.save(Budget(monthKey: "2026-10", amount: 100))
            original = try store.snapshot()
        }
        let reopened = Store(container: try ModelContainer(for: schema, configurations: configuration))
        XCTAssertTrue(BackupFormat.equivalent(try reopened.snapshot(), original))
    }

    @MainActor func testLogicalDuplicatesDisplayLatestWithoutDeletion() async throws {
        let store = try store()
        let category = PersonalKakeiboDomain.Category(name: "旧名", type: .expense, updatedAt: Date(timeIntervalSince1970: 1))
        var updated = category; updated.name = "新名"; updated.updatedAt = Date(timeIntervalSince1970: 2)
        store.container.mainContext.insert(StoredCategory(category))
        store.container.mainContext.insert(StoredCategory(updated))
        try store.container.mainContext.save()
        XCTAssertEqual(try store.displaySnapshot().categories.first?.name, "新名")
        XCTAssertTrue(store.hasLogicalDuplicates)
        XCTAssertEqual(try store.allCategories().count, 2)
        XCTAssertThrowsError(try store.save(updated))
    }

    @MainActor func testTenThousandTransactionBackupAndRestore() async throws {
        let store = try store()
        let date = Date(timeIntervalSinceReferenceDate: 800000000)
        let category = PersonalKakeiboDomain.Category(name: "架空の支出", type: .expense, createdAt: date, updatedAt: date)
        let entries = (0..<10000).map { index in
            Transaction(type: .expense, amount: Int64(index + 1), categoryId: category.id, occurredAt: date, memo: "架空の負荷試験", createdAt: date, updatedAt: date)
        }
        let snapshot = BackupSnapshot(transactions: entries, categories: [category], budgets: [])
        let started = Date()
        let encoded = try BackupFormat.encode(snapshot)
        let decoded = try BackupFormat.decode(encoded)
        let preview = try BackupFormat.preview(decoded, current: store.snapshot(), overwrite: false)
        try store.apply(preview.merged, expecting: preview.original)
        XCTAssertEqual(try store.allTransactions().count, 10000)
        print("10,000-record test: bytes=\(encoded.count), seconds=\(Date().timeIntervalSince(started))")
    }
}
