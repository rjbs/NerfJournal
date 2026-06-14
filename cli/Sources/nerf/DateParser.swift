import Foundation

// Parses a short natural-language date string, mirroring the app's quick-entry
// `~` parser (NerfJournal/DateParser.swift) so `nerf add-todo --start` accepts
// the same vocabulary.  Returns the start-of-day Date for the match, or nil if
// the query is unrecognized.
//
// Supported forms (all case-insensitive, prefix-matched where unambiguous):
//   today / tomorrow
//   sun / mon / tue / wed / thu / fri / sat  (next occurrence, always >= 1 day ahead)
//   +N / +Nd                                 (N days from today)
//   +Nw                                      (N weeks from today)
//   an ISO 8601 date (2026-07-20) or timestamp (2026-07-20T09:00:00Z)
enum DateParser {
    static func parse(_ query: String) -> Date? {
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
