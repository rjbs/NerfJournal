import Foundation
import GRDB

// A calendar day with no time-of-day and no time zone — a "civil date" in the
// floating/local sense. A journal day is a subjective span, not an instant: one
// page can legitimately hold events from either side of a time-zone change (fly
// Sydney→US and "Saturday" is honestly more than 24 hours long). Modelling the
// day as bare year/month/day, independent of any zone, is what makes that work
// and what stops the calendar from breaking when you view your journal from a
// time zone other than the one it was written in. -- claude, 2026-07-25
//
// Persisted as ISO "YYYY-MM-DD" TEXT, whose lexicographic order matches
// chronological order, so `ORDER BY`, `<=`, and range filters work directly in
// SQL with no date math.
public struct CivilDate: Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    // The civil date on which `instant` falls, as seen in `zone`.
    public init(instant: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: instant)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public static var today: CivilDate { CivilDate(instant: Date(), in: .current) }

    public static func < (a: CivilDate, b: CivilDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public init?(iso: String) {
        let p = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    // Day arithmetic that can cross month/year boundaries; delegated to Calendar
    // (in UTC, where every day is 24h) for correctness.
    public func adding(days: Int) -> CivilDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: year, month: month, day: day))!
        let moved = cal.date(byAdding: .day, value: days, to: base)!
        return CivilDate(instant: moved, in: cal.timeZone)
    }

    // Whole days from `other` to self (positive when self is later); computed in
    // UTC, where every day is 24h.
    public func daysSince(_ other: CivilDate) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let a = cal.date(from: DateComponents(year: other.year, month: other.month, day: other.day))!
        let b = cal.date(from: DateComponents(year: year, month: month, day: day))!
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // Noon in `zone`, a safe anchor for date-only display formatting — far from
    // any midnight/DST edge that could round onto an adjacent day.
    public func date(in zone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: 12))!
    }
}

// Encoded as the same "YYYY-MM-DD" string in JSON (export files, the TodoEnding
// blob) as in SQLite, regardless of the encoder's date strategy.
extension CivilDate: Codable {
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let cd = CivilDate(iso: s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a YYYY-MM-DD civil date: \(s)"))
        }
        self = cd
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

extension CivilDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { iso.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CivilDate? {
        guard let s = String.fromDatabaseValue(dbValue) else { return nil }
        return CivilDate(iso: s)
    }
}

// A precise moment: the true UTC instant plus the UTC offset in effect where and
// when the event happened. Keeping both lets us render the wall-clock time that
// was actually lived (Sydney 9am and US 6pm on one page each show their own local
// time) and compute which civil day the moment belonged to. -- claude, 2026-07-25
public struct Moment: Hashable, Codable, Sendable {
    public var instant: Date
    public var offsetSeconds: Int

    public init(instant: Date, offsetSeconds: Int) {
        self.instant = instant
        self.offsetSeconds = offsetSeconds
    }

    public var zone: TimeZone { TimeZone(secondsFromGMT: offsetSeconds) ?? .current }

    public var civilDate: CivilDate { CivilDate(instant: instant, in: zone) }

    public static func now() -> Moment {
        let now = Date()
        return Moment(instant: now,
                      offsetSeconds: TimeZone.current.secondsFromGMT(for: now))
    }
}

