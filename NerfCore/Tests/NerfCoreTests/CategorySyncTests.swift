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
    let writer: TaskWriter
    let listId: String

    init(categories: [String] = ["Work"]) throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal"])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        try db.write { db in
            for (index, name) in categories.enumerated() {
                var category = Category(id: nil, name: name, color: .green, sortOrder: index)
                try category.insert(db)
            }
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

    func serverTask(_ title: String, keywords: [String: JSONValue]) -> String {
        server.create("Task", [
            "title": .string(title), "start": "2026-09-13T00:00:00",
            "keywords": .object(keywords), "taskListIds": [.init(listId): true],
        ])
    }

    func categoryNames() throws -> [(String, Int, CategoryColor)] {
        try db.read { db in
            try Category.order(Column("sortOrder")).fetchAll(db).map { ($0.name, $0.sortOrder, $0.color) }
        }
    }

    func keywords(_ id: String) -> JSONValue? { server.object("Task", id)?["keywords"] }
}

final class CategorySyncTests: XCTestCase {

    func testReadingCreatesCategoriesForUnknownKeywords() async throws {
        let rig = try Rig()
        rig.serverTask("A", keywords: ["nerfjournal:category:Home": true, "urgent": true])
        rig.serverTask("B", keywords: ["nerfjournal:category:Work": true, "nerfjournal:category:Errands": true])
        try await rig.sync.engine.sync()

        let todos = try await rig.reader.todos()
        let names = try rig.categoryNames()
        XCTAssertEqual(names.map(\.0), ["Work", "Errands", "Home"])
        XCTAssertEqual(names.map(\.1), [0, 1, 2])
        XCTAssertEqual(names.map(\.2), [.green, .blue, .blue])
        XCTAssertEqual(todos.map(\.categoryID), [3, 1], "A gets the new Home; B keeps Work, the lowest sort order")

        try await rig.reader.todos()
        XCTAssertEqual(try rig.categoryNames().count, 3, "a second read creates nothing")
    }

    func testRenameRewritesKeywordOnCarryingTasksOnly() async throws {
        let rig = try Rig()
        let a = rig.serverTask("A", keywords: ["nerfjournal:category:Work": true, "urgent": true])
        let b = rig.serverTask("B", keywords: ["nerfjournal:category:Home": true])
        let c = rig.serverTask("C", keywords: [:])
        try await rig.sync.engine.sync()
        rig.server.clearRequests()

        try await rig.writer.renameCategoryKeyword(from: "Work", to: "Office")
        try await rig.sync.engine.sync()

        XCTAssertEqual(rig.server.calls(named: "Task/set").count, 1)
        XCTAssertEqual(rig.server.calls(named: "Task/set").first?.arguments["update"], [
            .init(a): ["keywords/nerfjournal:category:Work": .null, "keywords/nerfjournal:category:Office": true],
        ])
        XCTAssertEqual(rig.keywords(a), ["nerfjournal:category:Office": true, "urgent": true])
        XCTAssertEqual(rig.keywords(b), ["nerfjournal:category:Home": true])
        XCTAssertEqual(rig.keywords(c), [:])
    }

    func testRemoveLeavesTasksUncategorized() async throws {
        let rig = try Rig()
        let a = rig.serverTask("A", keywords: ["nerfjournal:category:Work": true, "urgent": true])
        let b = rig.serverTask("B", keywords: ["nerfjournal:category:Work": true])
        try await rig.sync.engine.sync()

        try await rig.writer.removeCategoryKeyword(named: "Work")
        try await rig.sync.engine.sync()

        XCTAssertEqual(rig.keywords(a), ["urgent": true])
        XCTAssertEqual(rig.keywords(b), nil)
        let todos = try await rig.reader.todos()
        XCTAssertEqual(todos.map(\.categoryID), [nil, nil])
    }
}
