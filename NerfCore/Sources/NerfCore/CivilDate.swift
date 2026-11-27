import Foundation
import GRDB

/// A day on the calendar, with no time of day and no time zone.
///
/// This is a "civil date" in the floating sense.  A journal day is a
/// subjective span, not an instant: one page can hold events from either side
/// of a change of time zone (fly from Sydney to the US and "Saturday" is
/// honestly more than 24 hours long).  Modeling the day as a bare year, month,
/// and day, independent of any zone, is what makes that work, and what stops
/// the calendar from breaking when the journal is read in a time zone other
/// than the one it was written in.
///
/// In SQLite and in JSON it is an ISO 8601 string, "YYYY-MM-DD", whatever the
/// encoder's date strategy.  The strings sort in the order of the days, so
/// `ORDER BY`, `<=`, and range filters work directly in SQL with no date
/// math.
public struct CivilDate: Hashable, Comparable, Sendable {
    /// The year, like 2026.
    public var year: Int

    /// The month, from 1 to 12.
    public var month: Int

    /// The day of the month, from 1 to 31.
    public var day: Int

    /// Makes a date from its parts, which are not checked.
    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The civil date on which `instant` falls, as seen in `zone`.
    public init(instant: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: instant)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    /// Today, in the current time zone.
    ///
    /// A view that must notice midnight should not read this, but get the
    /// day from something that changes when the day does.
    public static var today: CivilDate { CivilDate(instant: Date(), in: .current) }

    /// Whether `a` is an earlier day than `b`.
    public static func < (a: CivilDate, b: CivilDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// The date as an ISO 8601 string, "YYYY-MM-DD".
    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Reads a date from an ISO 8601 string, "YYYY-MM-DD", or fails.
    ///
    /// The month must be from 1 to 12 and the day from 1 to 31, but a day
    /// past the end of its month, like February 30, is not caught.
    public init?(iso: String) {
        let p = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    /// The date `days` days later, or earlier if `days` is negative.
    ///
    /// The arithmetic is done by `Calendar` in UTC, where every day is 24
    /// hours long, so it crosses the ends of months and years correctly.
    public func adding(days: Int) -> CivilDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: year, month: month, day: day))!
        let moved = cal.date(byAdding: .day, value: days, to: base)!
        return CivilDate(instant: moved, in: cal.timeZone)
    }

    /// The number of whole days from `other` to this date, which is
    /// positive when this date is later.
    ///
    /// Like ``adding(days:)``, it is computed in UTC, where every day is 24
    /// hours long.
    public func daysSince(_ other: CivilDate) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let a = cal.date(from: DateComponents(year: other.year, month: other.month, day: other.day))!
        let b = cal.date(from: DateComponents(year: year, month: month, day: day))!
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    /// Noon on this date in `zone`, for formatting the date for display.
    ///
    /// Noon is far from midnight and from the hours at which daylight saving
    /// time changes, either of which could round the instant onto the day
    /// before or after.
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
    /// Decodes a date from an ISO 8601 string, "YYYY-MM-DD".
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let cd = CivilDate(iso: s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a YYYY-MM-DD civil date: \(s)"))
        }
        self = cd
    }

    /// Encodes the date as an ISO 8601 string, "YYYY-MM-DD".
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

extension CivilDate: DatabaseValueConvertible {
    /// The date as an ISO 8601 string, "YYYY-MM-DD", for SQLite.
    public var databaseValue: DatabaseValue { iso.databaseValue }

    /// Reads a date from SQLite, where it is an ISO 8601 string.
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CivilDate? {
        guard let s = String.fromDatabaseValue(dbValue) else { return nil }
        return CivilDate(iso: s)
    }
}

/// An instant, and the offset from UTC in effect where and when it happened.
///
/// Unlike a ``CivilDate``, a moment is a precise point in time.  Keeping the
/// offset with the instant means the time can be shown on the clock it was
/// lived by, so that 9am in Sydney and 6pm in the US, on one page, each show
/// their own local time, and that the moment's ``civilDate`` is the day it was
/// where it happened.
public struct Moment: Hashable, Codable, Sendable {
    /// The instant.
    public var instant: Date

    /// The offset from UTC, in seconds, where and when the moment happened.
    public var offsetSeconds: Int

    /// Makes a moment from its parts.
    public init(instant: Date, offsetSeconds: Int) {
        self.instant = instant
        self.offsetSeconds = offsetSeconds
    }

    /// A time zone with the moment's fixed offset.
    ///
    /// It is the current time zone in the unlikely case that the offset is
    /// one `TimeZone` won't take.
    public var zone: TimeZone { TimeZone(secondsFromGMT: offsetSeconds) ?? .current }

    /// The day the moment fell on, where it happened.
    public var civilDate: CivilDate { CivilDate(instant: instant, in: zone) }

    /// The moment now, at the current time zone's offset.
    public static func now() -> Moment {
        let now = Date()
        return Moment(instant: now,
                      offsetSeconds: TimeZone.current.secondsFromGMT(for: now))
    }
}

