import XCTest
import JinxJSON
import NerfCore

private typealias Category = NerfCore.Category

private func instant(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private func day(_ iso: String) -> CivilDate { CivilDate(iso: iso)! }

private let newYork = TimeZone(identifier: "America/New_York")!

private let work = Category(id: 1, name: "Work", color: .blue, sortOrder: 0)
private let home = Category(id: 2, name: "Home", color: .green, sortOrder: 1)
private let categories = [home, work]

// The moment the spec's worked examples use: 14:03:22 in New York.
private let specMoment = Moment(instant: instant("2026-09-13T18:03:22Z"), offsetSeconds: -4 * 3600)

final class TaskCodecTests: XCTestCase {

    // MARK: - Encoding, from the spec's worked examples

    func testEncodesPendingMigratingTodo() {
        checkEncodeNew(
            Todo(id: nil, title: "Review the release notes", shouldMigrate: true,
                 start: day("2026-09-13"), categoryID: 1, externalURL: "https://example.com/pr/42"),
            uid: "9d2f5b1e-3e4a-4c5b-8f7e-1a2b3c4d5e6f", taskListId: "L1",
            expecting: [
                "@type": "Task",
                "uid": "9d2f5b1e-3e4a-4c5b-8f7e-1a2b3c4d5e6f",
                "taskListIds": ["L1": true],
                "title": "Review the release notes",
                "start": "2026-09-13T00:00:00",
                "showWithoutTime": true,
                "keywords": ["nerfjournal:category:Work": true],
                "links": ["nerfjournal-external": ["@type": "Link", "href": "https://example.com/pr/42", "rel": "related"]],
            ]
        )
    }

    func testEncodesCompletionAtKnownMoment() {
        checkEncode(
            Todo(id: nil, title: "Review the release notes", shouldMigrate: true,
                 start: day("2026-09-13"), ending: TodoEnding(moment: specMoment, kind: .done)),
            expecting: [
                "@type": "Task",
                "title": "Review the release notes",
                "start": "2026-09-13T00:00:00",
                "showWithoutTime": true,
                "progress": "completed",
                "progressUpdated": "2026-09-13T18:03:22Z",
                "nerfjournal.rjbs.cloud:endedAt": "2026-09-13T14:03:22-04:00",
            ]
        )
    }

    func testEncodesSweptHabitualTodo() {
        checkEncode(
            Todo(id: nil, title: "Read the on-call log", shouldMigrate: false,
                 start: day("2026-09-12"), ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
            now: instant("2026-09-13T12:00:07Z"),
            expecting: [
                "@type": "Task",
                "title": "Read the on-call log",
                "start": "2026-09-12T00:00:00",
                "showWithoutTime": true,
                "nerfjournal.rjbs.cloud:autoCancel": true,
                "progress": "cancelled",
                "progressUpdated": "2026-09-13T12:00:07Z",
                "nerfjournal.rjbs.cloud:endedAt": "2026-09-12",
            ]
        )
    }

    // MARK: - Encoding against an existing Task

    func testReopeningClearsTheEnding() {
        checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12")),
            existing: [
                "progress": "completed",
                "progressUpdated": "2026-09-13T12:00:07Z",
                "nerfjournal.rjbs.cloud:endedAt": "2026-09-13",
            ],
            expecting: [
                "@type": "Task", "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "needs-action",
            ]
        )
    }

    func testForeignInProcessIsKept() {
        checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12")),
            existing: ["progress": "in-process"],
            expecting: [
                "@type": "Task", "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "in-process",
            ]
        )
    }

    func testDayOnlyEndingKeepsProgressUpdatedWhenUnchanged() {
        checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"),
                 ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
            existing: ["progress": "cancelled", "progressUpdated": "2026-09-13T12:00:07Z"],
            now: instant("2026-10-01T00:00:00Z"),
            expecting: [
                "@type": "Task", "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "cancelled",
                "progressUpdated": "2026-09-13T12:00:07Z",
                "nerfjournal.rjbs.cloud:endedAt": "2026-09-12",
            ]
        )
    }

    func testDayOnlyEndingStampsProgressUpdatedWhenProgressChanges() {
        checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"),
                 ending: TodoEnding(day: day("2026-09-12"), kind: .done)),
            existing: ["progress": "cancelled", "progressUpdated": "2026-09-13T12:00:07Z"],
            now: instant("2026-10-01T00:00:00Z"),
            expecting: [
                "@type": "Task", "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "completed",
                "progressUpdated": "2026-10-01T00:00:00Z",
                "nerfjournal.rjbs.cloud:endedAt": "2026-09-12",
            ]
        )
    }

    func testForeignKeywordsAndLinksSurviveAndOurCategoryIsReplaced() {
        checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"), categoryID: 2),
            existing: [
                "keywords": ["nerfjournal:category:Work": true, "nerfjournal:category:Stale": true, "urgent": true],
                "links": [
                    "nerfjournal-external": ["@type": "Link", "href": "https://old.example/"],
                    "spec": ["@type": "Link", "href": "https://spec.example/"],
                ],
            ],
            expecting: [
                "@type": "Task", "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "keywords": ["nerfjournal:category:Home": true, "urgent": true],
                "links": ["spec": ["@type": "Link", "href": "https://spec.example/"]],
            ]
        )
    }

    // MARK: - Round trips

    func testRoundTrips() {
        checkRoundTrip(Todo(id: 7, title: "Plain", shouldMigrate: true, start: day("2026-09-13")))
        checkRoundTrip(Todo(id: 8, title: "Habit", shouldMigrate: false, start: day("2026-09-13"),
                            categoryID: 2, externalURL: "https://example.com/"))
        checkRoundTrip(Todo(id: 9, title: "Done", shouldMigrate: true, start: day("2026-09-13"),
                            ending: TodoEnding(moment: specMoment, kind: .done), categoryID: 1))
        checkRoundTrip(Todo(id: 10, title: "Swept", shouldMigrate: false, start: day("2026-09-12"),
                            ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)))
        checkRoundTrip(Todo(id: 11, title: "Done at Z", shouldMigrate: true, start: day("2026-09-13"),
                            ending: TodoEnding(moment: Moment(instant: instant("2026-09-13T23:30:00Z"), offsetSeconds: 0), kind: .done)))
        checkRoundTrip(Todo(id: 12, title: "Done in Tokyo", shouldMigrate: true, start: day("2026-09-13"),
                            ending: TodoEnding(moment: Moment(instant: instant("2026-09-13T23:30:00Z"), offsetSeconds: 9 * 3600), kind: .done)))
    }

    // MARK: - Lenient reading

    func testAutoCancelIsTrueOnlyForJSONTrue() {
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "nerfjournal.rjbs.cloud:autoCancel": true],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: false, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "nerfjournal.rjbs.cloud:autoCancel": "true"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "nerfjournal.rjbs.cloud:autoCancel": 1],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
    }

    func testStartIgnoresTimeAndZoneAndFallsBackToCreated() {
        checkDecode(["title": "T", "start": "2026-09-13T22:15:00", "timeZone": "Asia/Tokyo"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "created": "2026-09-14T02:30:00Z"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
    }

    func testProgressValues() {
        for pending in ["needs-action", "in-process"] {
            checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": .string(pending),
                         "nerfjournal.rjbs.cloud:endedAt": "2026-09-13"],
                        expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        }
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "failed",
                     "nerfjournal.rjbs.cloud:endedAt": "2026-09-14"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-14"), kind: .abandoned)))
    }

    func testEndedAtShapes() {
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed",
                     "nerfjournal.rjbs.cloud:endedAt": "2026-09-13T23:30:00-04:00"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-13"),
                                                       time: Moment(instant: instant("2026-09-14T03:30:00Z"), offsetSeconds: -4 * 3600),
                                                       kind: .done)))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed",
                     "nerfjournal.rjbs.cloud:endedAt": "2026-09-14T03:30:00Z"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-14"),
                                                       time: Moment(instant: instant("2026-09-14T03:30:00Z"), offsetSeconds: 0),
                                                       kind: .done)))
    }

    func testEndingDayFallbackChain() {
        let garbage: JSONValue = "soon"
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed",
                     "nerfjournal.rjbs.cloud:endedAt": garbage,
                     "progressUpdated": "2026-09-16T02:00:00Z", "updated": "2026-09-20T02:00:00Z"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-15"), kind: .done)))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "cancelled",
                     "updated": "2026-09-20T02:00:00Z"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-19"), kind: .abandoned)))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-13"), kind: .done)))
    }

    func testCategoryKeywords() {
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00",
                     "keywords": ["nerfjournal:category:Home": true, "nerfjournal:category:Work": true, "urgent": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"), categoryID: 1))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00",
                     "keywords": ["nerfjournal:category:Nope": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00",
                     "keywords": ["nerfjournal:category:work": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkCategoryNames(["keywords": ["nerfjournal:category:Nope": true, "nerfjournal:category:Work": true, "urgent": true]],
                           expecting: ["Nope", "Work"])
        checkCategoryNames(["keywords": [:]], expecting: [])
        checkCategoryNames([:], expecting: [])
    }

    func testLinks() {
        let ours: JSONValue = ["@type": "Link", "href": "https://ours.example/"]
        let theirs: JSONValue = ["@type": "Link", "href": "https://theirs.example/"]
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "links": ["nerfjournal-external": ours, "x": theirs]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"), externalURL: "https://ours.example/"))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "links": ["x": theirs]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"), externalURL: "https://theirs.example/"))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "links": ["x": theirs, "y": theirs]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "links": [:]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
    }

    // MARK: - Helpers

    private func checkEncode(_ todo: Todo, existing: JSONValue? = nil, now: Date = instant("2026-01-01T00:00:00Z"),
                             expecting expected: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        let actual = TaskCodec.encode(todo, categories: categories, existing: existing, now: now)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkEncodeNew(_ todo: Todo, uid: String, taskListId: String,
                                expecting expected: JSONValue, file: StaticString = #filePath, line: UInt = #line) {
        let actual = TaskCodec.encodeNew(todo, categories: categories, uid: uid, taskListId: taskListId)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkDecode(_ task: JSONValue, expecting expected: Todo,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = TaskCodec.decode(task, id: expected.id, categories: categories, zone: newYork)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkRoundTrip(_ todo: Todo, file: StaticString = #filePath, line: UInt = #line) {
        let encoded = TaskCodec.encode(todo, categories: categories)
        let decoded = TaskCodec.decode(encoded, id: todo.id, categories: categories, zone: newYork)
        XCTAssertEqual(decoded, todo, file: file, line: line)
    }

    private func checkCategoryNames(_ task: JSONValue, expecting expected: [String],
                                    file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(TaskCodec.categoryNames(in: task).sorted(), expected, file: file, line: line)
    }
}

