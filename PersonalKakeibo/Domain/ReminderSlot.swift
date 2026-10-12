import Foundation

public struct ReminderSlot: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var hour: Int
    public var minute: Int
    public var isEnabled: Bool
    public init(id: Int, hour: Int, minute: Int = 0, isEnabled: Bool = true) {
        self.id = id; self.hour = hour; self.minute = minute; self.isEnabled = isEnabled
    }
    public static let defaults = [ReminderSlot(id: 0, hour: 7), ReminderSlot(id: 1, hour: 12), ReminderSlot(id: 2, hour: 18)]
    public static func validate(_ slots: [ReminderSlot]) -> Bool {
        guard slots.count <= 3, Set(slots.map(\.id)).count == slots.count,
              slots.allSatisfy({ (0..<3).contains($0.id) && (0..<24).contains($0.hour) && (0..<60).contains($0.minute) }) else { return false }
        let times = slots.filter(\.isEnabled).map { $0.hour * 60 + $0.minute }
        return Set(times).count == times.count
    }
}
