import Foundation
import Observation
import PersonalKakeiboDomain

@MainActor @Observable final class DevicePreferences {
    private let defaults: UserDefaults
    private(set) var slots: [ReminderSlot]
    private(set) var defaultExpense: UUID?
    private(set) var defaultIncome: UUID?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaultExpense = defaults.string(forKey: "defaultExpense").flatMap(UUID.init(uuidString:))
        defaultIncome = defaults.string(forKey: "defaultIncome").flatMap(UUID.init(uuidString:))
        if let data = defaults.data(forKey: "reminderSlots"),
           let saved = try? JSONDecoder().decode([ReminderSlot].self, from: data), ReminderSlot.validate(saved), saved.count == 3 {
            slots = saved
        } else { slots = ReminderSlot.defaults }
    }
    func defaultCategory(for type: TransactionType) -> UUID? { type == .expense ? defaultExpense : defaultIncome }
    func setDefault(_ id: UUID?, for type: TransactionType) {
        if type == .expense { defaultExpense = id } else { defaultIncome = id }
        defaults.set(id?.uuidString, forKey: type == .expense ? "defaultExpense" : "defaultIncome")
    }
    func setSlots(_ slots: [ReminderSlot]) throws {
        guard slots.count == 3, ReminderSlot.validate(slots) else { throw StoreError.conflict }
        let data = try JSONEncoder().encode(slots)
        defaults.set(data, forKey: "reminderSlots"); self.slots = slots
    }
}
