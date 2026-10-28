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
    let reader: TaskReader
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
    }

    func serverTask(_ title: String, _ extra: [String: JSONValue] = [:]) -> String {
        var value: [String: JSONValue] = ["title": .string(title), "start": "2026-09-13T00:00:00", "taskListIds": [.init(listId): true]]
        value.merge(extra) { _, new in new }
        return server.create("Task", .object(value))
    }
}

final class TaskReaderTests: XCTestCase {

    func testReadsEveryTaskWithLocalKeyAsId() async throws {
        let rig = try Rig()
        let a = rig.serverTask("A", ["keywords": ["nerfjournal:category:Work": true]])
        let b = rig.serverTask("B", ["progress": "completed", "nerfjournal.rjbs.cloud:endedAt": "2026-09-14"])
        try await rig.sync.engine.sync()

        let synced = try await rig.reader.syncedTodos()
        XCTAssertEqual(synced.map(\.todo.title), ["A", "B"])
        XCTAssertEqual(synced.map(\.serverId), [a, b])
        XCTAssertEqual(synced.map(\.pending), [nil, nil])
        XCTAssertEqual(synced.map { $0.todo.id }, synced.map { $0.key.rawValue })
        XCTAssertEqual(synced[0].todo.categoryID, 1)
        XCTAssertEqual(synced[1].todo.ending, TodoEnding(day: day("2026-09-14"), kind: .done))
    }

    func testLocalCreatesShowAsPendingAndDestroysDisappear() async throws {
        let rig = try Rig()
        rig.serverTask("Remote")
        try await rig.sync.engine.sync()
        let remote = try await rig.reader.syncedTodos()[0]

        let todo = Todo(id: nil, title: "Local", shouldMigrate: true, start: day("2026-09-13"))
        let encoding = TaskCodec.encodeNew(todo, categories: [], uid: "u1", taskListId: rig.listId)
        _ = try await rig.sync.engine.create("Task", encoding)
        try await rig.sync.engine.destroy(remote.key)

        let synced = try await rig.reader.syncedTodos()
        XCTAssertEqual(synced.map(\.todo.title), ["Local"])
        XCTAssertEqual(synced[0].pending, .create)
        XCTAssertNil(synced[0].serverId)
    }
}
