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
struct CivilDate: Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    // The civil date on which `instant` falls, as seen in `zone`.
    init(instant: Date, in zone: TimeZone) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.year, .month, .day], from: instant)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    static var today: CivilDate { CivilDate(instant: Date(), in: .current) }

    static func < (a: CivilDate, b: CivilDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    init?(iso: String) {
        let p = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard p.count == 3,
              let y = Int(p[0]), let m = Int(p[1]), let d = Int(p[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    // Day arithmetic that can cross month/year boundaries; delegated to Calendar
    // (in UTC, where every day is 24h) for correctness.
    func adding(days: Int) -> CivilDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = cal.date(from: DateComponents(year: year, month: month, day: day))!
        let moved = cal.date(byAdding: .day, value: days, to: base)!
        return CivilDate(instant: moved, in: cal.timeZone)
    }

    // Whole days from `other` to self (positive when self is later); computed in
    // UTC, where every day is 24h.
    func daysSince(_ other: CivilDate) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let a = cal.date(from: DateComponents(year: other.year, month: other.month, day: other.day))!
        let b = cal.date(from: DateComponents(year: year, month: month, day: day))!
        return cal.dateComponents([.day], from: a, to: b).day ?? 0
    }

    // Noon in `zone`, a safe anchor for date-only display formatting — far from
    // any midnight/DST edge that could round onto an adjacent day.
    func date(in zone: TimeZone = .current) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal.date(from: DateComponents(
            year: year, month: month, day: day, hour: 12))!
    }
}

// Encoded as the same "YYYY-MM-DD" string in JSON (export files, the TodoEnding
// blob) as in SQLite, regardless of the encoder's date strategy.
extension CivilDate: Codable {
    init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let cd = CivilDate(iso: s) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Not a YYYY-MM-DD civil date: \(s)"))
        }
        self = cd
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }
}

extension CivilDate: DatabaseValueConvertible {
    var databaseValue: DatabaseValue { iso.databaseValue }

    static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CivilDate? {
        guard let s = String.fromDatabaseValue(dbValue) else { return nil }
        return CivilDate(iso: s)
    }
}

extension CivilDate {
    // Decodes a day that newer JSON stores as "YYYY-MM-DD" but older exports
    // stored as an ISO-8601 instant at the writing zone's midnight — read back as
    // its New York civil date so pre-CivilDate backups still import.
    // -- claude, 2026-07-25
    static func lenientlyDecode<K>(_ container: KeyedDecodingContainer<K>,
                                   forKey key: K) throws -> CivilDate {
        if let cd = try? container.decode(CivilDate.self, forKey: key) { return cd }
        let legacyInstant = try container.decode(Date.self, forKey: key)
        return CivilDate(instant: legacyInstant, in: TimeZone(identifier: "America/New_York")!)
    }
}

// A precise moment: the true UTC instant plus the UTC offset in effect where and
// when the event happened. Keeping both lets us render the wall-clock time that
// was actually lived (Sydney 9am and US 6pm on one page each show their own local
// time) and compute which civil day the moment belonged to. -- claude, 2026-07-25
struct Moment: Hashable, Codable, Sendable {
    var instant: Date
    var offsetSeconds: Int

    var zone: TimeZone { TimeZone(secondsFromGMT: offsetSeconds) ?? .current }

    var civilDate: CivilDate { CivilDate(instant: instant, in: zone) }

    static func now() -> Moment {
        let now = Date()
        return Moment(instant: now,
                      offsetSeconds: TimeZone.current.secondsFromGMT(for: now))
    }
}

// Splitting a legacy `ending` timestamp (an instant stored before this app knew
// about civil dates) into the new day-or-moment shape. Two synthetic times the
// app used to stamp carry no real time-of-day and so become day-only endings:
// noon local (a done-marker on a past page) and 23:59:59 local (the auto-abandon
// sweep at the end of the last considered day). A genuine completion goes through
// Date() with sub-second precision and lands on neither sentinel, so it keeps its
// true instant and the UTC offset in effect at that instant. The instant must be
// read in the zone the data was written in — America/New_York for the one-time
// migration — because a bare "12:00:00" only appears in that zone, never in the
// UTC text SQLite actually stores. -- claude, 2026-07-25
enum LegacyEnding {
    // Returns the ending's civil day, plus a Moment when the time-of-day is real
    // (nil for the synthetic sentinels).
    static func classify(instant: Date, assuming zone: TimeZone) -> (day: CivilDate, moment: Moment?) {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let ymd = cal.dateComponents([.year, .month, .day], from: instant)
        let day = CivilDate(year: ymd.year!, month: ymd.month!, day: ymd.day!)

        func localTime(hour: Int, minute: Int, second: Int) -> Date {
            cal.date(from: DateComponents(
                year: day.year, month: day.month, day: day.day,
                hour: hour, minute: minute, second: second))!
        }
        // SQLite stores milliseconds, so match the sentinel instants within a ms.
        let tolerance = 0.001
        let noon = localTime(hour: 12, minute: 0, second: 0)
        let endOfDay = localTime(hour: 23, minute: 59, second: 59)
        if abs(instant.timeIntervalSince(noon)) < tolerance
            || abs(instant.timeIntervalSince(endOfDay)) < tolerance {
            return (day, nil)
        }
        return (day, Moment(instant: instant, offsetSeconds: zone.secondsFromGMT(for: instant)))
    }
}
