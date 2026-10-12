import Foundation

public struct Month: Equatable, Sendable {
    public static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }
    public let start: Date
    public var end: Date { Self.calendar.date(byAdding: .month, value: 1, to: start)! }
    public var range: Range<Date> { start..<end }
    public var key: String {
        let parts = Self.calendar.dateComponents([.year, .month], from: start)
        return String(format: "%04d-%02d", parts.year!, parts.month!)
    }
    public init(date: Date = Date()) {
        start = Self.calendar.date(from: Self.calendar.dateComponents([.year, .month], from: date))!
    }
    public init(key: String) throws {
        let pieces = key.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 2, key.count == 7, let year = Int(pieces[0]),
              let month = Int(pieces[1]), (1...9999).contains(year), (1...12).contains(month),
              key == String(format: "%04d-%02d", year, month),
              let date = Self.calendar.date(from: DateComponents(year: year, month: month)) else {
            throw KakeiboError.invalidMonth
        }
        start = date
    }
    public func shifted(_ count: Int) -> Month {
        Month(date: Self.calendar.date(byAdding: .month, value: count, to: start)!)
    }
}
