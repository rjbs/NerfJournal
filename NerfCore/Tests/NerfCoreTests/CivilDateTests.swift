import XCTest
import NerfCore

private func instant(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private func tz(_ id: String) -> TimeZone { TimeZone(identifier: id)! }

final class CivilDateTests: XCTestCase {

    // MARK: - Parsing and ISO round-trip

    func testISORoundTrip() {
        checkISO("2026-07-09")
        checkISO("2026-01-01")
        checkISO("2026-12-31")
    }

    func testISORejectsGarbage() {
        checkISOInvalid("2026-13-01")   // month out of range
        checkISOInvalid("2026-07-40")   // day out of range
        checkISOInvalid("2026/07/09")   // wrong separator
        checkISOInvalid("not-a-date")
    }

    // MARK: - Ordering

    func testOrderingIsChronological() {
        checkOrder("2026-07-09", before: "2026-07-10")
        checkOrder("2026-07-31", before: "2026-08-01")
        checkOrder("2025-12-31", before: "2026-01-01")
    }

    // MARK: - Day arithmetic across boundaries

    func testAddingDays() {
        checkAddingDays("2026-07-09", plus: 1, equals: "2026-07-10")
        checkAddingDays("2026-07-31", plus: 1, equals: "2026-08-01")   // month roll
        checkAddingDays("2026-12-31", plus: 1, equals: "2027-01-01")   // year roll
        checkAddingDays("2026-03-01", plus: -1, equals: "2026-02-28")  // back over Feb
        checkAddingDays("2026-07-10", plus: -1, equals: "2026-07-09")
    }

    // MARK: - Which civil day an instant falls on, per zone

    func testInstantToCivilDatePerZone() {
        // 02:00 UTC: still the 8th in New York (-4), already the 9th in Sydney (+10).
        checkCivilDay(instant: "2026-07-09T02:00:00Z", zone: "America/New_York", isDay: "2026-07-08")
        checkCivilDay(instant: "2026-07-09T02:00:00Z", zone: "Australia/Sydney",  isDay: "2026-07-09")
        // Local midnight in NY (04:00 UTC, EDT) is the 9th there.
        checkCivilDay(instant: "2026-07-09T04:00:00Z", zone: "America/New_York", isDay: "2026-07-09")
    }

    // MARK: - Moment: wall clock and civil day from instant + offset

    func testMomentCivilDayUsesItsOwnOffset() {
        // Same instant, two offsets, two lived civil days — the Sydney→US case.
        checkMomentCivilDay(instant: "2026-07-24T13:00:00Z", offsetSeconds: 10 * 3600, isDay: "2026-07-24") // 23:00 AEST
        checkMomentCivilDay(instant: "2026-07-24T02:00:00Z", offsetSeconds: -4 * 3600, isDay: "2026-07-23") // 22:00 EDT prev day
    }

    // MARK: - LegacyEnding.classify: sentinel detection (assumes New York)

    func testNoonSentinelBecomesDayOnly() {
        // Noon EDT = 16:00 UTC; noon EST = 17:00 UTC. Both are the done-marker hack.
        checkEndingIsDayOnly(instant: "2026-07-09T16:00:00Z", isDay: "2026-07-09")
        checkEndingIsDayOnly(instant: "2026-01-09T17:00:00Z", isDay: "2026-01-09")
    }

    func testEndOfDaySentinelBecomesDayOnly() {
        // 23:59:59 EDT on the 9th = 03:59:59 UTC on the 10th.
        checkEndingIsDayOnly(instant: "2026-07-10T03:59:59Z", isDay: "2026-07-09")
    }

    func testRealCompletionKeepsMomentAndOffset() {
        // 18:47:23 UTC = 14:47:23 EDT — a genuine click, not a sentinel.
        checkEndingIsMoment(instant: "2026-07-09T18:47:23Z", isDay: "2026-07-09", offsetSeconds: -4 * 3600)
    }

    func testNoonOnADifferentSecondIsStillAMoment() {
        // 12:00:01 EDT (16:00:01 UTC) is one second off the sentinel — a real time.
        checkEndingIsMoment(instant: "2026-07-09T16:00:01Z", isDay: "2026-07-09", offsetSeconds: -4 * 3600)
    }

    // MARK: - Helpers

    private func checkISO(_ iso: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CivilDate(iso: iso)?.iso, iso, file: file, line: line)
    }

    private func checkISOInvalid(_ iso: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(CivilDate(iso: iso), "expected \(iso) to be rejected", file: file, line: line)
    }

    private func checkOrder(_ earlier: String, before later: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(CivilDate(iso: earlier)! < CivilDate(iso: later)!,
                      "\(earlier) should sort before \(later)", file: file, line: line)
    }

    private func checkAddingDays(_ start: String, plus days: Int, equals expected: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CivilDate(iso: start)!.adding(days: days), CivilDate(iso: expected)!,
                       file: file, line: line)
    }

    private func checkCivilDay(instant iso: String, zone id: String, isDay expected: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CivilDate(instant: instant(iso), in: tz(id)), CivilDate(iso: expected)!,
                       file: file, line: line)
    }

    private func checkMomentCivilDay(instant iso: String, offsetSeconds: Int, isDay expected: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let m = Moment(instant: instant(iso), offsetSeconds: offsetSeconds)
        XCTAssertEqual(m.civilDate, CivilDate(iso: expected)!, file: file, line: line)
    }

    private func checkEndingIsDayOnly(instant iso: String, isDay expected: String,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let r = LegacyEnding.classify(instant: instant(iso), assuming: tz("America/New_York"))
        XCTAssertEqual(r.day, CivilDate(iso: expected)!, file: file, line: line)
        XCTAssertNil(r.moment, "expected \(iso) to be a day-only sentinel", file: file, line: line)
    }

    private func checkEndingIsMoment(instant iso: String, isDay expected: String, offsetSeconds: Int,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let r = LegacyEnding.classify(instant: instant(iso), assuming: tz("America/New_York"))
        XCTAssertEqual(r.day, CivilDate(iso: expected)!, file: file, line: line)
        XCTAssertEqual(r.moment?.offsetSeconds, offsetSeconds, file: file, line: line)
        XCTAssertEqual(r.moment?.instant, instant(iso), file: file, line: line)
    }
}
