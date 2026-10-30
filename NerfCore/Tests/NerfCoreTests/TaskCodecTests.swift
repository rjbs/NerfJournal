import XCTest
import JinxJSON
import JinxStore
import NerfCore

private typealias Category = NerfCore.Category

private func instant(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: iso)!
}

private func day(_ iso: String) -> CivilDate { CivilDate(iso: iso)! }

private let newYork = TimeZone(identifier: "America/New_York")!

// The lists every case encodes against: a default list, two categories,
// and one category whose list has not reached the server.
private let lists = TaskListIndex(entries: [
    .init(key: LocalKey(10), serverId: "L0", name: "Tasks", color: .blue, sortOrder: 0, isDefault: true),
    .init(key: LocalKey(1), serverId: "L1", name: "Work", color: .blue, sortOrder: 0, isDefault: false),
    .init(key: LocalKey(2), serverId: "L2", name: "Home", color: .green, sortOrder: 1, isDefault: false),
    .init(key: LocalKey(3), serverId: nil, name: "Unsent", color: .red, sortOrder: 2, isDefault: false, pending: .create),
])

// The moment the spec's worked examples use: 14:03:22 in New York.
private let specMoment = Moment(instant: instant("2026-09-13T18:03:22Z"), offsetSeconds: -4 * 3600)

final class TaskCodecTests: XCTestCase {

    // MARK: - Encoding, from the spec's worked examples

    func testEncodesPendingMigratingTodo() throws {
        try checkEncodeNew(
            Todo(id: nil, title: "Review the release notes", shouldMigrate: true,
                 start: day("2026-09-13"), categoryID: 1, externalURL: "https://example.com/pr/42"),
            uid: "9d2f5b1e-3e4a-4c5b-8f7e-1a2b3c4d5e6f",
            expecting: [
                "@type": "Task",
                "uid": "9d2f5b1e-3e4a-4c5b-8f7e-1a2b3c4d5e6f",
                "taskListIds": ["L1": true],
                "title": "Review the release notes",
                "start": "2026-09-13T00:00:00",
                "showWithoutTime": true,
                "links": ["nerfjournal-external": ["@type": "Link", "href": "https://example.com/pr/42", "rel": "related"]],
            ]
        )
    }

    func testEncodesCompletionAtKnownMoment() throws {
        try checkEncode(
            Todo(id: nil, title: "Review the release notes", shouldMigrate: true,
                 start: day("2026-09-13"), ending: TodoEnding(moment: specMoment, kind: .done)),
            expecting: [
                "@type": "Task",
                "taskListIds": ["L0": true],
                "title": "Review the release notes",
                "start": "2026-09-13T00:00:00",
                "showWithoutTime": true,
                "progress": "completed",
                "progressUpdated": "2026-09-13T18:03:22Z",
                "nerfjournal.semiotic.systems:endedAt": "2026-09-13T14:03:22-04:00",
            ]
        )
    }

    func testEncodesSweptHabitualTodo() throws {
        try checkEncode(
            Todo(id: nil, title: "Read the on-call log", shouldMigrate: false,
                 start: day("2026-09-12"), ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
            now: instant("2026-09-13T12:00:07Z"),
            expecting: [
                "@type": "Task",
                "taskListIds": ["L0": true],
                "title": "Read the on-call log",
                "start": "2026-09-12T00:00:00",
                "showWithoutTime": true,
                "nerfjournal.semiotic.systems:autoCancel": true,
                "progress": "cancelled",
                "progressUpdated": "2026-09-13T12:00:07Z",
                "nerfjournal.semiotic.systems:endedAt": "2026-09-12",
            ]
        )
    }

    // MARK: - Which list

    func testUnknownCategoryFilesInTheDefaultList() throws {
        try checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"), categoryID: 99),
            expecting: ["@type": "Task", "taskListIds": ["L0": true], "title": "T",
                        "start": "2026-09-12T00:00:00", "showWithoutTime": true]
        )
    }

    func testUnsentCategoryIsRefused() {
        checkEncodeFails(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"), categoryID: 3),
            in: lists, expecting: .categoryNotSynced("Unsent")
        )
    }

    func testNoListsIsRefused() {
        checkEncodeFails(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12")),
            in: TaskListIndex(entries: []), expecting: .noTaskList
        )
    }

    // MARK: - Encoding against an existing Task

    func testReopeningClearsTheEnding() throws {
        try checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12")),
            existing: [
                "progress": "completed",
                "progressUpdated": "2026-09-13T12:00:07Z",
                "nerfjournal.semiotic.systems:endedAt": "2026-09-13",
            ],
            expecting: [
                "@type": "Task", "taskListIds": ["L0": true], "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "needs-action",
            ]
        )
    }

    func testForeignInProcessIsKept() throws {
        try checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12")),
            existing: ["progress": "in-process"],
            expecting: [
                "@type": "Task", "taskListIds": ["L0": true], "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "in-process",
            ]
        )
    }

    func testDayOnlyEndingKeepsProgressUpdatedWhenUnchanged() throws {
        try checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"),
                 ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
            existing: ["progress": "cancelled", "progressUpdated": "2026-09-13T12:00:07Z"],
            now: instant("2026-10-01T00:00:00Z"),
            expecting: [
                "@type": "Task", "taskListIds": ["L0": true], "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "cancelled",
                "progressUpdated": "2026-09-13T12:00:07Z",
                "nerfjournal.semiotic.systems:endedAt": "2026-09-12",
            ]
        )
    }

    func testDayOnlyEndingStampsProgressUpdatedWhenProgressChanges() throws {
        try checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"),
                 ending: TodoEnding(day: day("2026-09-12"), kind: .done)),
            existing: ["progress": "cancelled", "progressUpdated": "2026-09-13T12:00:07Z"],
            now: instant("2026-10-01T00:00:00Z"),
            expecting: [
                "@type": "Task", "taskListIds": ["L0": true], "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "progress": "completed",
                "progressUpdated": "2026-10-01T00:00:00Z",
                "nerfjournal.semiotic.systems:endedAt": "2026-09-12",
            ]
        )
    }

    func testForeignKeywordsAndLinksSurviveAndListsAreReplaced() throws {
        try checkEncode(
            Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-12"), categoryID: 2),
            existing: [
                "taskListIds": ["L0": true, "L1": true],
                "keywords": ["urgent": true, "theirs": true],
                "links": [
                    "nerfjournal-external": ["@type": "Link", "href": "https://old.example/"],
                    "spec": ["@type": "Link", "href": "https://spec.example/"],
                ],
            ],
            expecting: [
                "@type": "Task", "taskListIds": ["L2": true], "title": "T", "start": "2026-09-12T00:00:00", "showWithoutTime": true,
                "keywords": ["urgent": true, "theirs": true],
                "links": ["spec": ["@type": "Link", "href": "https://spec.example/"]],
            ]
        )
    }

    // MARK: - Round trips

    func testRoundTrips() throws {
        try checkRoundTrip(Todo(id: 7, title: "Plain", shouldMigrate: true, start: day("2026-09-13")))
        try checkRoundTrip(Todo(id: 8, title: "Habit", shouldMigrate: false, start: day("2026-09-13"),
                                categoryID: 2, externalURL: "https://example.com/"))
        try checkRoundTrip(Todo(id: 9, title: "Done", shouldMigrate: true, start: day("2026-09-13"),
                                ending: TodoEnding(moment: specMoment, kind: .done), categoryID: 1))
        try checkRoundTrip(Todo(id: 10, title: "Swept", shouldMigrate: false, start: day("2026-09-12"),
                                ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)))
        try checkRoundTrip(Todo(id: 11, title: "Done at Z", shouldMigrate: true, start: day("2026-09-13"),
                                ending: TodoEnding(moment: Moment(instant: instant("2026-09-13T23:30:00Z"), offsetSeconds: 0), kind: .done)))
        try checkRoundTrip(Todo(id: 12, title: "Done in Tokyo", shouldMigrate: true, start: day("2026-09-13"),
                                ending: TodoEnding(moment: Moment(instant: instant("2026-09-13T23:30:00Z"), offsetSeconds: 9 * 3600), kind: .done)))
    }

    // MARK: - Lenient reading

    func testAutoCancelIsTrueOnlyForJSONTrue() {
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "nerfjournal.semiotic.systems:autoCancel": true],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: false, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "nerfjournal.semiotic.systems:autoCancel": "true"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "nerfjournal.semiotic.systems:autoCancel": 1],
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
                         "nerfjournal.semiotic.systems:endedAt": "2026-09-13"],
                        expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        }
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "failed",
                     "nerfjournal.semiotic.systems:endedAt": "2026-09-14"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-14"), kind: .abandoned)))
    }

    func testEndedAtShapes() {
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed",
                     "nerfjournal.semiotic.systems:endedAt": "2026-09-13T23:30:00-04:00"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-13"),
                                                       time: Moment(instant: instant("2026-09-14T03:30:00Z"), offsetSeconds: -4 * 3600),
                                                       kind: .done)))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed",
                     "nerfjournal.semiotic.systems:endedAt": "2026-09-14T03:30:00Z"],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"),
                                    ending: TodoEnding(day: day("2026-09-14"),
                                                       time: Moment(instant: instant("2026-09-14T03:30:00Z"), offsetSeconds: 0),
                                                       kind: .done)))
    }

    func testEndingDayFallbackChain() {
        let garbage: JSONValue = "soon"
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "progress": "completed",
                     "nerfjournal.semiotic.systems:endedAt": garbage,
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

    func testTaskListIdsDecideTheCategory() {
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "taskListIds": ["L2": true, "L1": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"), categoryID: 1))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "taskListIds": ["L0": true, "L2": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13"), categoryID: 2))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "taskListIds": ["L0": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "taskListIds": ["L9": true]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        checkDecode(["title": "T", "start": "2026-09-13T00:00:00", "taskListIds": ["L1": false]],
                    expecting: Todo(id: 1, title: "T", shouldMigrate: true, start: day("2026-09-13")))
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
                             expecting expected: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try TaskCodec.encode(todo, lists: lists, existing: existing, now: now)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkEncodeNew(_ todo: Todo, uid: String,
                                expecting expected: JSONValue, file: StaticString = #filePath, line: UInt = #line) throws {
        let actual = try TaskCodec.encodeNew(todo, lists: lists, uid: uid)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkEncodeFails(_ todo: Todo, in index: TaskListIndex, expecting expected: JournalSyncError,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TaskCodec.encode(todo, lists: index), file: file, line: line) { error in
            XCTAssertEqual(String(describing: error), String(describing: expected), file: file, line: line)
        }
    }

    private func checkDecode(_ task: JSONValue, expecting expected: Todo,
                             file: StaticString = #filePath, line: UInt = #line) {
        let actual = TaskCodec.decode(task, id: expected.id, lists: lists, zone: newYork)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func checkRoundTrip(_ todo: Todo, file: StaticString = #filePath, line: UInt = #line) throws {
        let encoded = try TaskCodec.encode(todo, lists: lists)
        let decoded = TaskCodec.decode(encoded, id: todo.id, lists: lists, zone: newYork)
        XCTAssertEqual(decoded, todo, file: file, line: line)
    }
}
