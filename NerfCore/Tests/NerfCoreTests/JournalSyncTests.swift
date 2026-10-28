import XCTest
import GRDB
import Jinx
import JinxJSON
import JinxScriptedServer
import JinxTypes
import NerfCore

private typealias Category = NerfCore.Category

private func day(_ iso: String) -> CivilDate { CivilDate(iso: iso)! }

// A journal database with the full schema, Jinx tables included, wired to
// a scripted server. The server starts with one TaskList unless told not to.
private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync
    let listId: String?

    init(withTaskList: Bool = true) throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = withTaskList ? server.create("TaskList", ["name": "Journal"]) : nil
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
    }
}

final class JournalSyncTests: XCTestCase {

    func testSchemaIncludesJinxTables() throws {
        let db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        }
        XCTAssertTrue(tables.contains("todo"))
        XCTAssertTrue(tables.contains("jinx_object"))
        XCTAssertTrue(tables.contains("jinx_pending"))
    }

    func testTaskListIdIsFetchedOnFirstAskAndThenCached() async throws {
        let rig = try Rig()
        let first = try await rig.sync.taskListId()
        XCTAssertEqual(first, rig.listId)
        rig.server.clearRequests()
        let second = try await rig.sync.taskListId()
        XCTAssertEqual(second, first)
        XCTAssertTrue(rig.server.requests.isEmpty, "a cached answer sends nothing")
    }

    func testNoTaskListIsAnError() async throws {
        let rig = try Rig(withTaskList: false)
        do {
            _ = try await rig.sync.taskListId()
            XCTFail("expected noTaskList")
        } catch JournalSyncError.noTaskList {
        }
    }

    func testCreatedTodoReachesTheServerAndReadsBack() async throws {
        let rig = try Rig()
        let work = Category(id: 1, name: "Work", color: .blue, sortOrder: 0)
        let todo = Todo(id: nil, title: "Review the release notes", shouldMigrate: false,
                        start: day("2026-09-13"), categoryID: 1, externalURL: "https://example.com/pr/42")
        let listId = try await rig.sync.taskListId()
        let encoding = TaskCodec.encodeNew(todo, categories: [work], uid: "uid-1", taskListId: listId)
        let key = try await rig.sync.engine.create("Task", encoding)
        try await rig.sync.engine.sync()

        let stored = try await rig.sync.engine.object(key: key)
        let synced = try XCTUnwrap(stored)
        let id = try XCTUnwrap(synced.id, "the create was pushed and the id came back")
        let onServer = try XCTUnwrap(rig.server.object("Task", id))
        XCTAssertEqual(onServer["title"], "Review the release notes")
        XCTAssertEqual(onServer["taskListIds"], [.init(listId): true])
        XCTAssertEqual(onServer["nerfjournal.rjbs.cloud:autoCancel"], true)
        XCTAssertEqual(onServer["keywords"], ["nerfjournal:category:Work": true])

        let tasks = try await rig.sync.tasks()
        XCTAssertEqual(tasks.count, 1)
        let decoded = TaskCodec.decode(tasks[0].value, id: tasks[0].key.rawValue, categories: [work])
        XCTAssertEqual(decoded, Todo(id: key.rawValue, title: todo.title, shouldMigrate: false,
                                     start: todo.start, categoryID: 1, externalURL: todo.externalURL))
        let status = try await rig.sync.status()
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testForeignTaskArrivesOnSync() async throws {
        let rig = try Rig()
        let id = rig.server.create("Task", [
            "title": "From elsewhere", "start": "2026-09-13T09:00:00", "progress": "failed",
            "updated": "2026-09-14T12:00:00Z", "taskListIds": [.init(rig.listId!): true],
        ])
        try await rig.sync.engine.sync()
        let stored = try await rig.sync.engine.object(type: "Task", id: id)
        let synced = try XCTUnwrap(stored)
        let decoded = TaskCodec.decode(synced.value, id: synced.key.rawValue, categories: [], zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(decoded, Todo(id: synced.key.rawValue, title: "From elsewhere", shouldMigrate: true,
                                     start: day("2026-09-13"), ending: TodoEnding(day: day("2026-09-14"), kind: .abandoned)))
    }

    func testSignalNameIsStableAndShort() {
        let a = JournalSync.signalName(forDatabaseAt: "/a/journal.sqlite")
        XCTAssertEqual(a, JournalSync.signalName(forDatabaseAt: "/a/journal.sqlite"))
        XCTAssertNotEqual(a, JournalSync.signalName(forDatabaseAt: "/b/journal.sqlite"))
        XCTAssertTrue(a.hasPrefix("org.rjbs.nerfjournal.jinx."))
        XCTAssertEqual(a.count, "org.rjbs.nerfjournal.jinx.".count + 16)
    }

    func testSettingsSources() {
        XCTAssertEqual(SyncSettings.from(environment: [:]), .prototype)
        XCTAssertEqual(
            SyncSettings.from(environment: ["NERF_JMAP_URL": "https://jmap.example/session", "NERF_JMAP_ACCOUNT": "u1"]),
            SyncSettings(sessionURL: URL(string: "https://jmap.example/session")!, accountId: "u1"))
        let defaults = UserDefaults(suiteName: "org.rjbs.nerfjournal.tests.\(UUID().uuidString)")!
        XCTAssertEqual(SyncSettings.from(defaults), .prototype)
        defaults.set("https://jmap.example/session", forKey: SyncSettings.sessionURLDefaultsKey)
        defaults.set("u2", forKey: SyncSettings.accountIdDefaultsKey)
        XCTAssertEqual(SyncSettings.from(defaults),
                       SyncSettings(sessionURL: URL(string: "https://jmap.example/session")!, accountId: "u2"))
    }
}
