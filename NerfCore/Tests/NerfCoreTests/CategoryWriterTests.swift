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
    let reader: TaskReader
    let tasks: TaskWriter
    let categories: CategoryWriter
    let listId: String

    init() throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal", "isDefault": true, "sortOrder": 0])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
        reader = TaskReader(sync: sync)
        tasks = TaskWriter(sync: sync)
        categories = CategoryWriter(sync: sync)
    }

    func serverLists() -> [(name: String, color: String?, sortOrder: Int?)] {
        server.objects("TaskList").values
            .map { ($0["name"]?.stringValue ?? "", $0["color"]?.stringValue, $0["sortOrder"]?.intValue) }
            .sorted { ($0.2 ?? 0, $0.0) < ($1.2 ?? 0, $1.0) }
    }

    func serverListIds(of key: LocalKey) async throws -> JSONValue? {
        guard let id = try await sync.engine.object(key: key)?.id else { return nil }
        return server.object("Task", id)?["taskListIds"]
    }
}

final class CategoryWriterTests: XCTestCase {

    func testCreatePushesTheListAndAppendsItToTheOrder() async throws {
        let rig = try Rig()
        let work = try await rig.categories.create(name: "Work", color: .blue)
        let home = try await rig.categories.create(name: "Home", color: .green)

        let index = try await rig.sync.listIndex()
        XCTAssertEqual(index.categories.map(\.name), ["Work", "Home"])
        XCTAssertEqual(index.categories.map(\.id), [work.rawValue, home.rawValue])
        XCTAssertEqual(index.categories.map(\.sortOrder), [0, 1])
        XCTAssertTrue(index.categoryEntries.allSatisfy { $0.serverId != nil }, "each create was pushed before returning")
        XCTAssertEqual(rig.serverLists().map(\.name), ["Journal", "Work", "Home"])
        XCTAssertEqual(rig.serverLists().map(\.color), [nil, "blue", "green"])
    }

    func testRenameRecolorAndReorder() async throws {
        let rig = try Rig()
        let work = try await rig.categories.create(name: "Work", color: .blue)
        let home = try await rig.categories.create(name: "Home", color: .green)

        try await rig.categories.rename(work, to: "Office")
        try await rig.categories.setColor(home, to: .purple)
        try await rig.categories.reorder([home, work])
        try await rig.sync.engine.sync()

        let names = try await rig.sync.categories().map(\.name)
        XCTAssertEqual(names, ["Home", "Office"])
        XCTAssertEqual(rig.serverLists().map { ($0.name, $0.color, $0.sortOrder) }.map { "\($0.0) \($0.1 ?? "-") \($0.2 ?? -1)" },
                       ["Home purple 0", "Journal - 0", "Office blue 1"])
    }

    func testDeleteMovesTasksToTheDefaultListBeforeDestroying() async throws {
        let rig = try Rig()
        let work = try await rig.categories.create(name: "Work", color: .blue)
        let keys = try await rig.tasks.createMany([
            Todo(id: nil, title: "A", shouldMigrate: true, start: day("2026-09-13"), categoryID: work.rawValue),
            Todo(id: nil, title: "B", shouldMigrate: true, start: day("2026-09-13")),
        ])
        try await rig.sync.engine.sync()
        try await rig.db.write { db in
            var bundle = TaskBundle(id: nil, name: "Daily", sortOrder: 0, todosShouldMigrate: true)
            try bundle.insert(db)
            var bundleTodo = BundleTodo(id: nil, bundleID: 1, title: "Stretch", sortOrder: 0, categoryID: work.rawValue)
            try bundleTodo.insert(db)
            try db.execute(sql: "INSERT INTO exportGroup (id, name, sortOrder) VALUES (1, 'G', 0)")
            try db.execute(sql: "INSERT INTO exportGroupMember (groupID, categoryID) VALUES (1, ?), (1, NULL)", arguments: [work.rawValue])
        }
        rig.server.clearRequests()

        try await rig.categories.delete(work)
        try await rig.sync.engine.sync()

        let names = try await rig.sync.categories().map(\.name)
        XCTAssertEqual(names, [])
        XCTAssertEqual(rig.serverLists().map(\.name), ["Journal"])
        let a = try await rig.serverListIds(of: keys[0])
        XCTAssertEqual(a, [.init(rig.listId): true])
        let todos = try await rig.reader.todos()
        XCTAssertEqual(todos.map(\.categoryID), [nil, nil])
        let sets = rig.server.requests.flatMap { $0.methodCalls.map(\.name) }.filter { $0.hasSuffix("/set") }
        XCTAssertEqual(sets, ["Task/set", "TaskList/set"], "the moves travel before the destroy")
        let refs = try await rig.db.read { db in
            (try Int64?.fetchOne(db, sql: "SELECT categoryID FROM bundleTodo") ?? nil,
             try Int.fetchOne(db, sql: "SELECT count(*) FROM exportGroupMember")!)
        }
        XCTAssertNil(refs.0)
        XCTAssertEqual(refs.1, 1, "the Other membership stays")
    }

    func testDeleteOfAnUnsentListIsLocal() async throws {
        let rig = try Rig()
        _ = try await rig.sync.listIndex()
        let key = try await rig.sync.engine.create("TaskList", TaskListIndex.encodeList(name: "Draft", color: .red, sortOrder: 0))
        rig.server.clearRequests()

        try await rig.categories.delete(key)
        let names = try await rig.sync.categories().map(\.name)
        XCTAssertEqual(names, [])
        XCTAssertTrue(rig.server.requests.isEmpty)
    }

    func testFilingInAnUnsentCategoryIsRefused() async throws {
        let rig = try Rig()
        _ = try await rig.sync.listIndex()
        let key = try await rig.sync.engine.create("TaskList", TaskListIndex.encodeList(name: "Draft", color: .red, sortOrder: 0))
        let names = try await rig.sync.categories().map(\.name)
        XCTAssertEqual(names, ["Draft"], "the category shows before it is pushed")

        do {
            _ = try await rig.tasks.create(Todo(id: nil, title: "T", shouldMigrate: true, start: day("2026-09-13"), categoryID: key.rawValue))
            XCTFail("expected categoryNotSynced")
        } catch JournalSyncError.categoryNotSynced(let name) {
            XCTAssertEqual(name, "Draft")
        }
        let todos = try await rig.reader.todos()
        XCTAssertEqual(todos, [], "nothing was filed in the default list instead")
    }
}
