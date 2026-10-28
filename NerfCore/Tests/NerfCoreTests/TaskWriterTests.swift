import XCTest
import GRDB
import Jinx
import JinxJSON
import JinxScriptedServer
import JinxStore
import JinxTypes
import NerfCore

private typealias Category = NerfCore.Category

private func day(_ iso: String) -> CivilDate { CivilDate(iso: iso)! }
private let noon = Date(timeIntervalSince1970: 1_789_000_000)

private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync
    let reader: TaskReader
    let writer: TaskWriter
    let listId: String

    init() throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal"])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        try db.write { db in
            var work = Category(id: nil, name: "Work", color: .blue, sortOrder: 0)
            try work.insert(db)
        }
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
        reader = TaskReader(sync: sync)
        writer = TaskWriter(sync: sync)
    }

    func todos() async throws -> [Todo] { try await reader.todos() }

    func serverValue(_ key: LocalKey) async throws -> JSONValue? {
        guard let id = try await sync.engine.object(key: key)?.id else { return nil }
        return server.object("Task", id)
    }
}

final class TaskWriterTests: XCTestCase {

    func testCreateManyIsOneBatchWithFreshUids() async throws {
        let rig = try Rig()
        let keys = try await rig.writer.createMany([
            Todo(id: nil, title: "A", shouldMigrate: true, start: day("2026-09-13"), categoryID: 1),
            Todo(id: nil, title: "B", shouldMigrate: false, start: day("2026-09-14"), externalURL: "https://b.example/"),
        ])
        XCTAssertEqual(keys.count, 2)
        let todos = try await rig.todos()
        XCTAssertEqual(todos.map(\.title), ["A", "B"])
        XCTAssertEqual(todos.map(\.id), keys.map(\.rawValue))

        try await rig.sync.engine.sync()
        let sets = rig.server.calls(named: "Task/set")
        XCTAssertEqual(sets.count, 1, "both creates travel in one Task/set")
        let uids = Set(rig.server.objects("Task").values.compactMap { $0["uid"]?.stringValue })
        XCTAssertEqual(uids.count, 2)
        let first = try await rig.serverValue(keys[0])
        XCTAssertEqual(first?["taskListIds"], [.init(rig.listId): true])
    }

    func testUpdateChangesOnlyWhatChangedAndKeepsForeignProperties() async throws {
        let rig = try Rig()
        let id = rig.server.create("Task", [
            "title": "Remote", "start": "2026-09-13T00:00:00", "description": "theirs",
            "keywords": ["urgent": true], "taskListIds": [.init(rig.listId): true],
        ])
        try await rig.sync.engine.sync()
        let stored = try await rig.sync.engine.object(type: "Task", id: id)
        let key = try XCTUnwrap(stored).key
        rig.server.clearRequests()

        try await rig.writer.update(key, now: noon) { todo in
            todo.title = "Renamed"
            todo.categoryID = 1
        }
        try await rig.sync.engine.sync()

        let set = try XCTUnwrap(rig.server.calls(named: "Task/set").first)
        XCTAssertEqual(set.arguments["update"], [
            .init(id): [
                "title": "Renamed",
                "keywords/nerfjournal:category:Work": true,
                "showWithoutTime": true,
                "@type": "Task",
            ],
        ])
        let onServer = try XCTUnwrap(rig.server.object("Task", id))
        XCTAssertEqual(onServer["description"], "theirs")
        XCTAssertEqual(onServer["keywords"], ["urgent": true, "nerfjournal:category:Work": true])
    }

    func testCompleteReopenAndDestroy() async throws {
        let rig = try Rig()
        let key = try await rig.writer.create(Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-13")))
        let moment = Moment(instant: noon, offsetSeconds: -4 * 3600)

        try await rig.writer.update(key) { $0.ending = TodoEnding(moment: moment, kind: .done) }
        var todo = try await rig.todos()[0]
        XCTAssertEqual(todo.ending, TodoEnding(moment: moment, kind: .done))

        try await rig.writer.update(key) { $0.ending = nil }
        todo = try await rig.todos()[0]
        XCTAssertNil(todo.ending)
        let object = try await rig.sync.engine.object(key: key)
        let value = try XCTUnwrap(object).value
        XCTAssertEqual(value["progress"], "needs-action")
        XCTAssertNil(value["nerfjournal.rjbs.cloud:endedAt"])

        try await rig.writer.destroy([key])
        let remaining = try await rig.todos()
        XCTAssertEqual(remaining, [])
    }

    func testSweepCancelsStaleHabitsAsOfTheirStartDay() async throws {
        let rig = try Rig()
        let keys = try await rig.writer.createMany([
            Todo(id: nil, title: "old habit", shouldMigrate: false, start: day("2026-09-10")),
            Todo(id: nil, title: "today's habit", shouldMigrate: false, start: day("2026-09-13")),
            Todo(id: nil, title: "old chore", shouldMigrate: true, start: day("2026-09-10")),
            Todo(id: nil, title: "done habit", shouldMigrate: false, start: day("2026-09-11"),
                 ending: TodoEnding(day: day("2026-09-11"), kind: .done)),
        ])
        let swept = try await rig.writer.sweep(asOf: day("2026-09-13"), now: noon)
        XCTAssertEqual(swept, [keys[0]])
        let todos = try await rig.todos()
        XCTAssertEqual(todos[0].ending, TodoEnding(day: day("2026-09-10"), kind: .abandoned))
        XCTAssertNil(todos[1].ending)
        XCTAssertNil(todos[2].ending)
        XCTAssertEqual(todos[3].ending?.kind, .done)

        let again = try await rig.writer.sweep(asOf: day("2026-09-13"), now: noon)
        XCTAssertEqual(again, [], "a second sweep finds nothing")
    }
}
