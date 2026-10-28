import XCTest
import GRDB
import Jinx
import JinxJSON
import JinxScriptedServer
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
        listId = server.create("TaskList", ["name": "Journal", "isDefault": true])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
    }

    // A Work category, a page, a bundle with a Work todo, and two todos,
    // all on the server.
    func seed() async throws -> Int64 {
        let work = try await CategoryWriter(sync: sync).create(name: "Work", color: .blue).rawValue
        try await db.write { db in
            var page = JournalPage(id: nil, date: day("2026-09-13"))
            try page.insert(db)
            var bundle = TaskBundle(id: nil, name: "Daily", sortOrder: 0, todosShouldMigrate: false)
            try bundle.insert(db)
            var bundleTodo = BundleTodo(id: nil, bundleID: 1, title: "Stretch", sortOrder: 0, categoryID: work)
            try bundleTodo.insert(db)
        }
        _ = try await TaskWriter(sync: sync).createMany([
            Todo(id: nil, title: "A", shouldMigrate: true, start: day("2026-09-13"), categoryID: work),
            Todo(id: nil, title: "B", shouldMigrate: false, start: day("2026-09-12"),
                 ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
        ])
        try await sync.engine.sync()
        return work
    }

    func tableCounts() throws -> [Int] {
        try db.read { db in
            try ["journalPage", "taskBundle", "bundleTodo", "jinx_object", "jinx_pending"].map {
                try Int.fetchOne(db, sql: "SELECT count(*) FROM \($0)")!
            }
        }
    }

    func categoryNames() async throws -> [String] {
        try await sync.categories().map(\.name)
    }

    func bundleTodoCategory() throws -> Int64? {
        try db.read { db in try Int64?.fetchOne(db, sql: "SELECT categoryID FROM bundleTodo") ?? nil }
    }
}

final class JournalBackupTests: XCTestCase {

    func testExportCarriesUidsAndRoundTripsThroughJSON() async throws {
        let rig = try Rig()
        let work = try await rig.seed()
        let snapshot = try await rig.sync.exportSnapshot()
        XCTAssertEqual(snapshot.version, 10)
        XCTAssertEqual(snapshot.todos.map(\.todo.title), ["A", "B"])
        XCTAssertEqual(snapshot.todos.compactMap(\.uid).count, 2)
        XCTAssertEqual(snapshot.categories.map(\.name), ["Work"])
        XCTAssertEqual(snapshot.categories.map(\.id), [work])

        let data = try await rig.sync.exportData()
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let todos = json["todos"] as! [[String: Any]]
        XCTAssertEqual(todos[0]["title"] as? String, "A")
        XCTAssertEqual(todos[0]["uid"] as? String, snapshot.todos[0].uid)
        XCTAssertEqual(todos[0]["categoryID"] as? Int64, work)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(DatabaseExport.self, from: data)
        XCTAssertEqual(back.todos, snapshot.todos)
        XCTAssertEqual(back.categories, snapshot.categories)
    }

    func testImportMapsCategoriesByNameAdoptsByUidAndReplacesClientTables() async throws {
        let source = try Rig()
        _ = try await source.seed()
        let data = try await source.sync.exportData()

        // A fresh client with a category of its own, that already has the
        // second todo (same uid) from the server, plus local data the
        // import replaces.
        let target = try Rig()
        _ = try await CategoryWriter(sync: target.sync).create(name: "Stale", color: .red)
        let sourceSnapshot = try await source.sync.exportSnapshot()
        let existingUid = try XCTUnwrap(sourceSnapshot.todos[1].uid)
        target.server.create("Task", ["title": "B", "uid": .string(existingUid), "start": "2026-09-12T00:00:00",
                                      "taskListIds": [.init(target.listId): true]])
        try await target.sync.engine.sync()

        let report = try await target.sync.importData(data)
        XCTAssertEqual(report, ImportReport(adopted: 1, alreadyPresent: 1, categoriesCreated: 1))
        XCTAssertEqual(try target.tableCounts(), [1, 1, 1, 5, 1], "three lists, two Tasks, one pending create")
        let names = try await target.categoryNames()
        XCTAssertEqual(names, ["Stale", "Work"], "the file's category is added after the client's own")
        let work = try await target.sync.categories()[1].id
        XCTAssertEqual(try target.bundleTodoCategory(), work, "the bundle todo follows the file's category to its new list")

        try await target.sync.engine.sync()
        let todos = try await TaskReader(sync: target.sync).todos()
        XCTAssertEqual(Set(todos.map(\.title)), ["A", "B"])
        XCTAssertEqual(todos.first { $0.title == "A" }?.categoryID, work)
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
        _ = try await rig.seed()
        _ = try await TaskWriter(sync: rig.sync).create(Todo(id: nil, title: "unsent", shouldMigrate: true, start: day("2026-09-13")))
        XCTAssertEqual(try rig.tableCounts(), [1, 1, 1, 5, 1])

        try await rig.sync.resetLocalData()
        XCTAssertEqual(try rig.tableCounts(), [0, 0, 0, 0, 0])
        XCTAssertEqual(rig.server.objects("Task").count, 2, "the server keeps what it had")
        XCTAssertEqual(rig.server.objects("TaskList").count, 2)

        try await rig.sync.engine.sync()
        let todos = try await TaskReader(sync: rig.sync).todos()
        XCTAssertEqual(Set(todos.map(\.title)), ["A", "B"], "the next sync fetches the server's Tasks afresh")
        let names = try await rig.categoryNames()
        XCTAssertEqual(names, ["Work"])
    }
}
