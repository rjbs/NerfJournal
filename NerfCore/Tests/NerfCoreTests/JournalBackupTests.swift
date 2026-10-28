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

private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync
    let listId: String

    init() throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal"])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
    }

    func seed() async throws {
        try await db.write { db in
            var work = Category(id: nil, name: "Work", color: .blue, sortOrder: 0)
            try work.insert(db)
            var page = JournalPage(id: nil, date: day("2026-09-13"))
            try page.insert(db)
            var bundle = TaskBundle(id: nil, name: "Daily", sortOrder: 0, todosShouldMigrate: false)
            try bundle.insert(db)
            var bundleTodo = BundleTodo(id: nil, bundleID: 1, title: "Stretch", sortOrder: 0)
            try bundleTodo.insert(db)
        }
        _ = try await TaskWriter(sync: sync).createMany([
            Todo(id: nil, title: "A", shouldMigrate: true, start: day("2026-09-13"), categoryID: 1),
            Todo(id: nil, title: "B", shouldMigrate: false, start: day("2026-09-12"),
                 ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
        ])
        try await sync.engine.sync()
    }

    func tableCounts() throws -> [Int] {
        try db.read { db in
            try ["category", "journalPage", "taskBundle", "bundleTodo", "jinx_object", "jinx_pending"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")!
            }
        }
    }
}

final class JournalBackupTests: XCTestCase {

    func testExportCarriesUidsAndRoundTripsThroughJSON() async throws {
        let rig = try Rig()
        try await rig.seed()
        let snapshot = try await rig.sync.exportSnapshot()
        XCTAssertEqual(snapshot.version, 9)
        XCTAssertEqual(snapshot.todos.map(\.todo.title), ["A", "B"])
        XCTAssertEqual(snapshot.todos.compactMap(\.uid).count, 2)
        XCTAssertEqual(snapshot.categories.map(\.name), ["Work"])

        let data = try await rig.sync.exportData()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let todos = json["todos"] as! [[String: Any]]
        XCTAssertEqual(todos[0]["title"] as? String, "A")
        XCTAssertEqual(todos[0]["uid"] as? String, snapshot.todos[0].uid)
        XCTAssertEqual(todos[0]["categoryID"] as? Int, 1)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DatabaseExport.self, from: data)
        XCTAssertEqual(back.todos, snapshot.todos)
    }

    func testImportAdoptsByUidAndReplacesClientTables() async throws {
        let source = try Rig()
        try await source.seed()
        let data = try await source.sync.exportData()

        // A fresh client that already has the second todo (same uid) from the
        // server, plus local data the import replaces.
        let target = try Rig()
        try await target.db.write { db in
            var stale = Category(id: nil, name: "Stale", color: .red, sortOrder: 0)
            try stale.insert(db)
        }
        let sourceSnapshot = try await source.sync.exportSnapshot()
        let existingUid = try XCTUnwrap(sourceSnapshot.todos[1].uid)
        target.server.create("Task", ["title": "B", "uid": .string(existingUid), "start": "2026-09-12T00:00:00",
                                      "taskListIds": [.init(target.listId): true]])
        try await target.sync.engine.sync()

        let report = try await target.sync.importData(data)
        XCTAssertEqual(report, ImportReport(adopted: 1, alreadyPresent: 1))
        XCTAssertEqual(try target.tableCounts(), [1, 1, 1, 1, 3, 1], "one TaskList, two Tasks, one pending create")
        let names = try await target.db.read { db in try Category.fetchAll(db).map(\.name) }
        XCTAssertEqual(names, ["Work"])

        try await target.sync.engine.sync()
        let todos = try await TaskReader(sync: target.sync).todos()
        XCTAssertEqual(Set(todos.map(\.title)), ["A", "B"])
        XCTAssertEqual(todos.first { $0.title == "A" }?.categoryID, 1, "the imported category id still resolves")
    }

    func testImportOfPreJMAPFileGivesTodosFreshUids() async throws {
        let rig = try Rig()
        let legacy = """
        {"version": 8, "exportedAt": "2026-09-13T12:00:00Z", "categories": [], "taskBundles": [],
         "bundleTodos": [], "journalPages": [],
         "todos": [{"id": 5, "title": "Old", "shouldMigrate": true, "start": "2026-09-13"}]}
        """
        let report = try await rig.sync.importData(Data(legacy.utf8))
        XCTAssertEqual(report, ImportReport(adopted: 1, alreadyPresent: 0))
        let synced = try await TaskReader(sync: rig.sync).syncedTodos()
        XCTAssertEqual(synced.map(\.todo.title), ["Old"])
        XCTAssertNotNil(synced[0].uid)
    }

    func testResetEmptiesTheClientAndLeavesTheServerAlone() async throws {
        let rig = try Rig()
        try await rig.seed()
        _ = try await TaskWriter(sync: rig.sync).create(Todo(id: nil, title: "unsent", shouldMigrate: true, start: day("2026-09-13")))
        XCTAssertEqual(try rig.tableCounts(), [1, 1, 1, 1, 4, 1])

        try await rig.sync.resetLocalData()
        XCTAssertEqual(try rig.tableCounts(), [0, 0, 0, 0, 0, 0])
        XCTAssertEqual(rig.server.objects("Task").count, 2, "the server keeps what it had")

        try await rig.sync.engine.sync()
        let todos = try await TaskReader(sync: rig.sync).todos()
        XCTAssertEqual(Set(todos.map(\.title)), ["A", "B"], "the next sync fetches the server's Tasks afresh")
    }
}
