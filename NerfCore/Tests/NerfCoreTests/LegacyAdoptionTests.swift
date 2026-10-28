import XCTest
import GRDB
import Jinx
import JinxJSON
import JinxScriptedServer
import JinxTypes
import NerfCore

private typealias Category = NerfCore.Category

private func day(_ iso: String) -> CivilDate { CivilDate(iso: iso)! }

// A journal database in its v8 shape with a few todos, as the installed
// app leaves it, wired to a scripted server that already has a TaskList.
private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync

    init(todos: [Todo], categories: [Category] = []) throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        server.create("TaskList", ["name": "Journal"])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db, upTo: "v8")
        try db.write { db in
            for var c in categories { try c.insert(db) }
            for var t in todos { try t.insert(db) }
        }
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
    }

    func legacyRows() throws -> [Row] {
        try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM todo_legacy ORDER BY id") }
    }

    func tableExists(_ name: String) throws -> Bool {
        try db.read { db in try db.tableExists(name) }
    }
}

private let work = Category(id: 1, name: "Work", color: .blue, sortOrder: 0)
private let sampleTodos = [
    Todo(id: nil, title: "Pending", shouldMigrate: true, start: day("2026-09-13"), categoryID: 1, externalURL: "https://example.com/1"),
    Todo(id: nil, title: "Swept", shouldMigrate: false, start: day("2026-09-12"),
         ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
    Todo(id: nil, title: "Done", shouldMigrate: true, start: day("2026-09-10"),
         ending: TodoEnding(moment: Moment(instant: Date(timeIntervalSince1970: 1_789_000_000), offsetSeconds: -4 * 3600), kind: .done)),
]

final class LegacyAdoptionTests: XCTestCase {

    func testMigrationV9StagesEveryRowWithAUid() throws {
        let rig = try Rig(todos: sampleTodos, categories: [work])
        XCTAssertFalse(try rig.tableExists("todo"))
        let rows = try rig.legacyRows()
        XCTAssertEqual(rows.map { $0["title"] as String }, ["Pending", "Swept", "Done"])
        let uids = rows.map { $0["uid"] as String }
        XCTAssertEqual(Set(uids).count, 3)
        XCTAssertTrue(uids.allSatisfy { UUID(uuidString: $0) != nil })
        XCTAssertEqual(rows[0]["categoryID"] as Int64?, 1)
    }

    func testAdoptionCreatesTasksAndDropsTheTable() async throws {
        let rig = try Rig(todos: sampleTodos, categories: [work])
        let uids = try rig.legacyRows().map { $0["uid"] as String }

        let report = try await rig.sync.adoptLegacyTodos()
        XCTAssertEqual(report, .init(adopted: 3, alreadyPresent: 0))
        XCTAssertFalse(try rig.tableExists("todo_legacy"))

        let tasks = try await rig.sync.tasks()
        XCTAssertEqual(tasks.map { $0.value["uid"]?.stringValue }, uids)
        XCTAssertEqual(tasks.map(\.pending), [.create, .create, .create])
        let decoded = tasks.map { TaskCodec.decode($0.value, id: nil, categories: [work]) }
        XCTAssertEqual(decoded, sampleTodos)
        XCTAssertNil(tasks[1].value["progressUpdated"], "a day-only ending has no instant to report")

        try await rig.sync.engine.sync()
        XCTAssertEqual(rig.server.objects("Task").count, 3)
        let status = try await rig.sync.status()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(Set(rig.server.objects("Task").values.compactMap { $0["uid"]?.stringValue }), Set(uids))
    }

    func testAdoptionSkipsRowsAlreadyAdopted() async throws {
        let rig = try Rig(todos: sampleTodos, categories: [work])
        // Rehearse a crash after the adopt but before the drop: adopt the
        // first row by hand, leaving the table in place.
        let first = try rig.legacyRows()[0]
        let listId = try await rig.sync.taskListId()
        let todo = Todo(id: nil, title: first["title"], shouldMigrate: first["shouldMigrate"], start: first["start"],
                        categoryID: first["categoryID"], externalURL: first["externalURL"])
        _ = try await rig.sync.engine.create("Task", TaskCodec.encodeNew(todo, categories: [work], uid: first["uid"], taskListId: listId))

        let report = try await rig.sync.adoptLegacyTodos()
        XCTAssertEqual(report, .init(adopted: 2, alreadyPresent: 1))
        let count = try await rig.sync.tasks().count
        XCTAssertEqual(count, 3)
        XCTAssertFalse(try rig.tableExists("todo_legacy"))

        let again = try await rig.sync.adoptLegacyTodos()
        XCTAssertNil(again, "nothing to do once the table is gone")
    }

    func testAdoptionWithNothingStagedStillDropsTheTable() async throws {
        let rig = try Rig(todos: [])
        let report = try await rig.sync.adoptLegacyTodos()
        XCTAssertEqual(report, .init(adopted: 0, alreadyPresent: 0))
        XCTAssertFalse(try rig.tableExists("todo_legacy"))
    }
}
