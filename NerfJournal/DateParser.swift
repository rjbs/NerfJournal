import Foundation

// Parses a short natural-language date string typed after `~` in the
// quick-entry field.  Returns the start-of-day Date for the match, or nil if
// the query is unrecognized.
//
// Supported forms (all case-insensitive, prefix-matched where unambiguous):
//   today / tomorrow
//   sun / mon / tue / wed / thu / fri / sat  (next occurrence, always >= 1 day ahead)
//   +N / +Nd                                 (N days from today)
//   +Nw                                      (N weeks from today)
enum DateParser {
    static func parse(_ query: String) -> Date? {
        let q = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
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

        return nil
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
