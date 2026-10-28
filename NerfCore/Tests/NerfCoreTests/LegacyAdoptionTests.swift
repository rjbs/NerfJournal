import XCTest
import GRDB
import Jinx
import JinxJSON
import JinxScriptedServer
import JinxTypes
import NerfCore

private typealias Category = NerfCore.Category

private func day(_ iso: String) -> CivilDate { CivilDate(iso: iso)! }

// A journal database in its v8 shape with a few todos and categories, as
// the installed app left it before the JMAP backend, wired to a scripted
// server that already has a default TaskList. `serverTasks` are Tasks the
// server holds before adoption, for the v9 shape where todos had already
// moved but categories were keywords.
private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync
    let listId: String

    init(todos: [Todo], categories: [Category] = [], serverLists: [String] = []) throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal", "isDefault": true, "sortOrder": 0])
        for (index, name) in serverLists.enumerated() {
            server.create("TaskList", ["name": .string(name), "sortOrder": .number(Double(index))])
        }
        db = try DatabaseQueue()
        try NerfSchema.migrate(db, upTo: "v8")
        try db.write { db in
            for c in categories {
                try db.execute(sql: "INSERT INTO category (id, name, color, sortOrder) VALUES (?, ?, ?, ?)",
                               arguments: [c.id, c.name, c.color.rawValue, c.sortOrder])
            }
            for var t in todos { try t.insert(db) }
            // A bundle todo in the first category and one in none; an export
            // group holding every category and the Other bucket.
            try db.execute(sql: "INSERT INTO taskBundle (id, name, sortOrder, todosShouldMigrate) VALUES (1, 'Daily', 0, 1)")
            try db.execute(sql: "INSERT INTO bundleTodo (id, bundleID, title, sortOrder, categoryID) VALUES (1, 1, 'Stretch', 0, ?), (2, 1, 'Walk', 1, NULL)",
                           arguments: [categories.first?.id])
            try db.execute(sql: "INSERT INTO exportGroup (id, name, sortOrder) VALUES (1, 'G', 0)")
            for c in categories {
                try db.execute(sql: "INSERT INTO exportGroupMember (groupID, categoryID) VALUES (1, ?)", arguments: [c.id])
            }
            try db.execute(sql: "INSERT INTO exportGroupMember (groupID, categoryID) VALUES (1, NULL)")
        }
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
    }

    @discardableResult
    func serverTask(_ title: String, keywords: [String: JSONValue]) -> String {
        server.create("Task", [
            "title": .string(title), "start": "2026-09-13T00:00:00", "uid": .string(UUID().uuidString),
            "keywords": .object(keywords), "taskListIds": [.init(listId): true],
        ])
    }

    func legacyRows() throws -> [Row] {
        try db.read { db in try Row.fetchAll(db, sql: "SELECT * FROM todo_legacy ORDER BY id") }
    }

    func tableExists(_ name: String) throws -> Bool {
        try db.read { db in try db.tableExists(name) }
    }

    func references() throws -> (bundleTodos: [Int64?], members: [Int64?]) {
        try db.read { db in
            (try Int64?.fetchAll(db, sql: "SELECT categoryID FROM bundleTodo ORDER BY id"),
             try Int64?.fetchAll(db, sql: "SELECT categoryID FROM exportGroupMember ORDER BY categoryID"))
        }
    }

    func serverLists() -> [(name: String, color: String?, sortOrder: Int?)] {
        server.objects("TaskList").values
            .map { ($0["name"]?.stringValue ?? "", $0["color"]?.stringValue, $0["sortOrder"]?.intValue) }
            .sorted { ($0.2 ?? 0, $0.0) < ($1.2 ?? 0, $1.0) }
    }

    func serverTasksByTitle() -> [String: JSONValue] {
        Dictionary(uniqueKeysWithValues: server.objects("Task").values.map { ($0["title"]?.stringValue ?? "", $0) })
    }
}

private let work = Category(id: 1, name: "Work", color: .blue, sortOrder: 0)
private let home = Category(id: 2, name: "Home", color: .green, sortOrder: 1)
private let sampleTodos = [
    Todo(id: nil, title: "Pending", shouldMigrate: true, start: day("2026-09-13"), categoryID: 1, externalURL: "https://example.com/1"),
    Todo(id: nil, title: "Swept", shouldMigrate: false, start: day("2026-09-12"),
         ending: TodoEnding(day: day("2026-09-12"), kind: .abandoned)),
    Todo(id: nil, title: "Done", shouldMigrate: true, start: day("2026-09-10"),
         ending: TodoEnding(moment: Moment(instant: Date(timeIntervalSince1970: 1_789_000_000), offsetSeconds: -4 * 3600), kind: .done)),
]

final class LegacyAdoptionTests: XCTestCase {

    // MARK: - Staging

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

    func testMigrationV10StagesCategoriesAndDropsTheForeignKeys() throws {
        let rig = try Rig(todos: [], categories: [work, home])
        XCTAssertFalse(try rig.tableExists("category"))
        let staged = try rig.db.read { db in
            try Row.fetchAll(db, sql: "SELECT name, listKey FROM category_legacy ORDER BY id").map { ($0["name"] as String, $0["listKey"] as Int64?) }
        }
        XCTAssertEqual(staged.map(\.0), ["Work", "Home"])
        XCTAssertEqual(staged.map(\.1), [nil, nil])
        let foreignKeys = try rig.db.read { db in
            try ["bundleTodo", "exportGroupMember"].map { table in
                try String.fetchAll(db, sql: "SELECT \"table\" FROM pragma_foreign_key_list(?)", arguments: [table])
            }
        }
        XCTAssertEqual(foreignKeys, [["taskBundle"], ["exportGroup"]])
        XCTAssertEqual(try rig.references().bundleTodos, [1, nil], "values survive the rebuild")
        XCTAssertEqual(try rig.references().members, [nil, 1, 2])
    }

    // MARK: - Categories

    func testCategoryAdoptionCreatesListsAndRewritesReferences() async throws {
        let rig = try Rig(todos: sampleTodos, categories: [work, home])
        try await rig.db.write { db in
            try db.execute(sql: "UPDATE exportGroupMember SET categoryID = 99 WHERE categoryID = 2")
        }

        let report = try await rig.sync.adoptLegacyCategories()
        XCTAssertEqual(report, .init(created: 2, matched: 0, tasksMoved: 0))
        XCTAssertFalse(try rig.tableExists("category_legacy"))
        XCTAssertEqual(rig.serverLists().map { "\($0.name) \($0.color ?? "-") \($0.sortOrder ?? -1)" },
                       ["Journal - 0", "Work blue 0", "Home green 1"])

        let categories = try await rig.sync.categories()
        XCTAssertEqual(categories.map(\.name), ["Work", "Home"])
        let workKey = try XCTUnwrap(categories[0].id)
        XCTAssertEqual(try rig.references().bundleTodos, [workKey, nil])
        XCTAssertEqual(try rig.references().members, [nil, workKey], "a member naming no category leaves the group")
        XCTAssertEqual(try rig.legacyRows().map { $0["categoryID"] as Int64? }, [workKey, nil, nil])

        let again = try await rig.sync.adoptLegacyCategories()
        XCTAssertNil(again, "nothing to do once the table is gone")
    }

    func testCategoryAdoptionMovesKeywordTasksIntoTheirLists() async throws {
        let rig = try Rig(todos: [], categories: [work, home])
        rig.serverTask("A", keywords: ["nerfjournal:category:Home": true, "urgent": true])
        rig.serverTask("B", keywords: ["nerfjournal:category:Home": true, "nerfjournal:category:Work": true])
        rig.serverTask("C", keywords: ["nerfjournal:category:Gone": true])
        rig.serverTask("D", keywords: [:])
        try await rig.sync.engine.sync()

        let report = try await rig.sync.adoptLegacyCategories()
        XCTAssertEqual(report, .init(created: 2, matched: 0, tasksMoved: 2))
        try await rig.sync.engine.sync()

        let lists = Dictionary(uniqueKeysWithValues: rig.server.objects("TaskList").map { ($1["name"]?.stringValue ?? "", $0) })
        let tasks = rig.serverTasksByTitle()
        XCTAssertEqual(tasks["A"]?["taskListIds"], [.init(lists["Home"]!): true])
        XCTAssertEqual(tasks["A"]?["keywords"], ["urgent": true])
        XCTAssertEqual(tasks["B"]?["taskListIds"], [.init(lists["Work"]!): true], "the first category in legacy order wins")
        XCTAssertNil(tasks["B"]?["keywords"])
        XCTAssertEqual(tasks["C"]?["taskListIds"], [.init(rig.listId): true])
        XCTAssertEqual(tasks["C"]?["keywords"], ["nerfjournal:category:Gone": true], "a keyword naming no category is not ours to judge")
        XCTAssertEqual(tasks["D"]?["taskListIds"], [.init(rig.listId): true])

        let todos = try await TaskReader(sync: rig.sync).todos()
        let categories = try await rig.sync.categories()
        XCTAssertEqual(todos.map(\.categoryID), [categories[1].id, categories[0].id, nil, nil])
    }

    func testCategoryAdoptionMatchesExistingListsByName() async throws {
        let rig = try Rig(todos: [], categories: [work, home], serverLists: ["Work"])
        let report = try await rig.sync.adoptLegacyCategories()
        XCTAssertEqual(report, .init(created: 1, matched: 1, tasksMoved: 0))
        XCTAssertEqual(rig.serverLists().map(\.name), ["Journal", "Work", "Home"])
        let categories = try await rig.sync.categories()
        XCTAssertEqual(try rig.references().bundleTodos, [categories[0].id, nil])
    }

    func testCategoryAdoptionResumesAfterACrash() async throws {
        let rig = try Rig(todos: [], categories: [work, home])
        // Rehearse a crash after the lists were created but before they were
        // recorded: create Work by hand, leaving category_legacy untouched.
        _ = try await rig.sync.listIndex()
        _ = try await rig.sync.engine.create("TaskList", TaskListIndex.encodeList(name: "Work", color: .blue, sortOrder: 0))

        let report = try await rig.sync.adoptLegacyCategories()
        XCTAssertEqual(report, .init(created: 1, matched: 1, tasksMoved: 0))
        XCTAssertEqual(rig.serverLists().map(\.name), ["Journal", "Work", "Home"], "no duplicate Work")
    }

    func testCategoryAdoptionWithoutTheServerLeavesTheTable() async throws {
        let rig = try Rig(todos: [], categories: [work])
        _ = try await rig.sync.listIndex()
        rig.server.enqueue(.transportFailure)
        do {
            _ = try await rig.sync.adoptLegacyCategories()
            XCTFail("expected the sync to fail")
        } catch {
        }
        XCTAssertTrue(try rig.tableExists("category_legacy"))
        XCTAssertEqual(try rig.references().bundleTodos, [1, nil], "references are untouched until the lists exist")

        let report = try await rig.sync.adoptLegacyCategories()
        XCTAssertEqual(report, .init(created: 0, matched: 0, tasksMoved: 0), "the list made before the crash is remembered")
        XCTAssertFalse(try rig.tableExists("category_legacy"))
    }

    // MARK: - Todos

    func testAdoptionCreatesTasksAndDropsTheTable() async throws {
        let rig = try Rig(todos: sampleTodos, categories: [work])
        let uids = try rig.legacyRows().map { $0["uid"] as String }
        _ = try await rig.sync.adoptLegacyCategories()
        let workKey = try await rig.sync.categories()[0].id

        let report = try await rig.sync.adoptLegacyTodos()
        XCTAssertEqual(report, .init(adopted: 3, alreadyPresent: 0))
        XCTAssertFalse(try rig.tableExists("todo_legacy"))

        let tasks = try await rig.sync.tasks()
        XCTAssertEqual(tasks.map { $0.value["uid"]?.stringValue }, uids)
        XCTAssertEqual(tasks.map(\.pending), [.create, .create, .create])
        let lists = try await rig.sync.listIndex()
        let decoded = tasks.map { TaskCodec.decode($0.value, id: nil, lists: lists) }
        var expected = sampleTodos
        expected[0].categoryID = workKey
        XCTAssertEqual(decoded, expected)
        XCTAssertNil(tasks[1].value["progressUpdated"], "a day-only ending has no instant to report")

        try await rig.sync.engine.sync()
        XCTAssertEqual(rig.server.objects("Task").count, 3)
        let status = try await rig.sync.status()
        XCTAssertEqual(status.pendingCount, 0)
        XCTAssertEqual(Set(rig.server.objects("Task").values.compactMap { $0["uid"]?.stringValue }), Set(uids))
        let workId = rig.server.objects("TaskList").first { $1["name"] == "Work" }!.key
        XCTAssertEqual(rig.serverTasksByTitle()["Pending"]?["taskListIds"], [.init(workId): true])
    }

    func testAdoptionSkipsRowsAlreadyAdopted() async throws {
        let rig = try Rig(todos: sampleTodos, categories: [work])
        _ = try await rig.sync.adoptLegacyCategories()
        // Rehearse a crash after the adopt but before the drop: adopt the
        // first row by hand, leaving the table in place.
        let first = try rig.legacyRows()[0]
        let lists = try await rig.sync.listIndex()
        let todo = Todo(id: nil, title: first["title"], shouldMigrate: first["shouldMigrate"], start: first["start"],
                        categoryID: first["categoryID"], externalURL: first["externalURL"])
        _ = try await rig.sync.engine.create("Task", try TaskCodec.encodeNew(todo, lists: lists, uid: first["uid"]))

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
