import Foundation

/// Reads the short dates typed after `~` in the field for adding a todo.
public enum DateParser {
    /// The start of the day that `query` names, in the current calendar, or
    /// nil if it names none.
    ///
    /// These are understood, ignoring case:
    ///
    /// - `today` and `tomorrow`, or any start of them.  A bare "t" is today.
    /// - The name of a day of the week, or any start of it, meaning the next
    ///   such day, at least one day ahead, so "monday" on a Monday is next
    ///   Monday.  A bare "s" is Sunday.
    /// - `+N` or `+Nd`, meaning N days from today, and `+Nw`, meaning N
    ///   weeks from today.
    /// - An ISO 8601 date, like 2026-07-20, or date-time, like
    ///   2026-07-20T09:00:00Z.  A date-time names the day it falls on in the
    ///   local time zone.
    public static func parse(_ query: String) -> Date? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let q = trimmed.lowercased()
        guard !q.isEmpty else { return nil }

        let cal  = Calendar.current
        let today = cal.startOfDay(for: Date())

        // "today" is checked before "tomorrow" so that a bare "t" resolves to
        // today; typing "tom" unambiguously resolves to tomorrow. -- claude, 2026-04-06
        if "today".hasPrefix(q)    { return today }
        if "tomorrow".hasPrefix(q) { return cal.date(byAdding: .day, value: 1, to: today) }

        // Day names in Calendar.weekday order (1 = Sunday … 7 = Saturday).
        // "sunday" and "saturday" are both checked before falling through; "s"
        // alone resolves to Sunday (first match wins).
        let days: [(String, Int)] = [
            ("sunday", 1), ("monday", 2), ("tuesday", 3),
            ("wednesday", 4), ("thursday", 5), ("friday", 6), ("saturday", 7),
        ]
        for (name, weekday) in days where name.hasPrefix(q) {
            return nextWeekday(weekday, after: today, cal: cal)
        }

        // +N / +Nd / +Nw
        if q.hasPrefix("+") {
            let rest = q.dropFirst()
            if rest.hasSuffix("w"), let n = Int(rest.dropLast()), n > 0 {
                return cal.date(byAdding: .weekOfYear, value: n, to: today)
            }
            let digits = rest.hasSuffix("d") ? String(rest.dropLast()) : String(rest)
            if let n = Int(digits), n > 0 {
                return cal.date(byAdding: .day, value: n, to: today)
            }
        }

        // ISO 8601, with or without a time.  A full timestamp is reduced to the
        // start of its day in the local calendar, matching the start-of-day Dates
        // the shorthand forms above produce — `start` is a day, not a moment, so
        // 2026-07-20T09:00:00Z and 2026-07-20 land on the same page. -- claude, 2026-06-14
        if let date = parseISO8601(trimmed) {
            return cal.startOfDay(for: date)
        }

        return nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: s) { return date }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: s) { return date }

        // Date-only "yyyy-MM-dd", read as a day in the local calendar.
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = .current
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: s)
    }

    // Returns the next calendar date that falls on `target` weekday.
    // Always at least one day ahead — so "monday" on a Monday means next Monday.
    private static func nextWeekday(_ target: Int, after today: Date, cal: Calendar) -> Date? {
        let todayWeekday = cal.component(.weekday, from: today)
        var daysAhead = target - todayWeekday
        if daysAhead <= 0 { daysAhead += 7 }
        return cal.date(byAdding: .day, value: daysAhead, to: today)
    }
}
