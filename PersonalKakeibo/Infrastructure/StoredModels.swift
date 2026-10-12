import Foundation
import SwiftData
import PersonalKakeiboDomain

@Model final class StoredTransaction {
    var id: UUID = UUID()
    var typeRaw: String = "expense"
    var amount: Int64 = 1
    var categoryId: UUID = UUID()
    var occurredAt: Date = Date()
    var memo: String = ""
    var sourceRaw: String = "manual"
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(_ value: PersonalKakeiboDomain.Transaction) {
        id = value.id; typeRaw = value.type.rawValue; amount = value.amount
        categoryId = value.categoryId; occurredAt = value.occurredAt; memo = value.memo
        sourceRaw = value.source.rawValue; createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func update(_ value: PersonalKakeiboDomain.Transaction) {
        id = value.id
        typeRaw = value.type.rawValue
        amount = value.amount
        categoryId = value.categoryId
        occurredAt = value.occurredAt
        memo = value.memo
        sourceRaw = value.source.rawValue
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
    func value() throws -> PersonalKakeiboDomain.Transaction {
        guard let type = TransactionType(rawValue: typeRaw) else { throw StoreError.invalidData }
        guard let source = TransactionSource(rawValue: sourceRaw) else { throw StoreError.invalidData }
        return PersonalKakeiboDomain.Transaction(id: id, type: type, amount: amount, categoryId: categoryId, occurredAt: occurredAt, memo: memo, source: source, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model final class StoredCategory {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = "expense"
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(_ value: PersonalKakeiboDomain.Category) {
        id = value.id; name = value.name; typeRaw = value.type.rawValue
        sortOrder = value.sortOrder; isArchived = value.isArchived
        createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func update(_ value: PersonalKakeiboDomain.Category) {
        id = value.id
        name = value.name
        typeRaw = value.type.rawValue
        sortOrder = value.sortOrder
        isArchived = value.isArchived
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
    func value() throws -> PersonalKakeiboDomain.Category {
        guard let type = TransactionType(rawValue: typeRaw) else { throw StoreError.invalidData }
        return PersonalKakeiboDomain.Category(id: id, name: name, type: type, sortOrder: sortOrder, isArchived: isArchived, createdAt: createdAt, updatedAt: updatedAt)
    }
}

@Model final class StoredBudget {
    var id: UUID = UUID()
    var monthKey: String = ""
    var amount: Int64 = 1
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    init(_ value: PersonalKakeiboDomain.Budget) {
        id = value.id; monthKey = value.monthKey; amount = value.amount
        createdAt = value.createdAt; updatedAt = value.updatedAt
    }
    func update(_ value: PersonalKakeiboDomain.Budget) {
        id = value.id
        monthKey = value.monthKey
        amount = value.amount
        createdAt = value.createdAt
        updatedAt = value.updatedAt
    }
    func value() throws -> PersonalKakeiboDomain.Budget {
        return PersonalKakeiboDomain.Budget(id: id, monthKey: monthKey, amount: amount, createdAt: createdAt, updatedAt: updatedAt)
    }
}

enum KakeiboSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredTransaction.self, StoredCategory.self, StoredBudget.self] }
}

// The original three entities keep their names and attributes for lightweight migration.
@Model final class StoredPlanningRecord {
    var id: UUID = UUID()
    var kind: String = ""
    var payload: Data = Data()
    var updatedAt: Date = Date()
    init(id: UUID, kind: String, payload: Data, updatedAt: Date) {
        self.id = id; self.kind = kind; self.payload = payload; self.updatedAt = updatedAt
    }
}

enum KakeiboSchema: VersionedSchema {
    static var versionIdentifier: Schema.Version { .init(2, 0, 0) }
    static var models: [any PersistentModel.Type] { KakeiboSchemaV1.models + [StoredPlanningRecord.self] }
}

enum KakeiboMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [KakeiboSchemaV1.self, KakeiboSchema.self] }
    static var stages: [MigrationStage] { [.lightweight(fromVersion: KakeiboSchemaV1.self, toVersion: KakeiboSchema.self)] }
}
