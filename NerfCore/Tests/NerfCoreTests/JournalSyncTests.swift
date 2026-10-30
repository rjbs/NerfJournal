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
// a scripted server that has a default list and a "Work" list.
private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync
    let listId: String
    let workId: String

    init() throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal", "isDefault": true])
        workId = server.create("TaskList", ["name": "Work", "color": "blue", "sortOrder": 1])
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

    func testSchemaHasTheClientTablesAndJinxTables() throws {
        let db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations' ORDER BY name")
        }
        let clientTables = tables.filter { !$0.hasPrefix("jinx_") }
        XCTAssertEqual(clientTables, ["bundleTodo", "exportGroup", "exportGroupMember", "journalPage", "taskBundle"],
                       "todos and categories live in the engine's tables, not their own")
        XCTAssertTrue(tables.contains("jinx_object"))
        XCTAssertTrue(tables.contains("jinx_pending"))
    }

    func testCreatedTodoReachesTheServerAndReadsBack() async throws {
        let rig = try Rig()
        let lists = try await rig.sync.listIndex()
        let work = try XCTUnwrap(lists.entry(named: "Work"))
        let todo = Todo(id: nil, title: "Review the release notes", shouldMigrate: false,
                        start: day("2026-09-13"), categoryID: work.key.rawValue, externalURL: "https://example.com/pr/42")
        let encoding = try TaskCodec.encodeNew(todo, lists: lists, uid: "uid-1")
        let key = try await rig.sync.engine.create("Task", encoding)
        try await rig.sync.engine.sync()

        let stored = try await rig.sync.engine.object(key: key)
        let synced = try XCTUnwrap(stored)
        let id = try XCTUnwrap(synced.id, "the create was pushed and the id came back")
        let onServer = try XCTUnwrap(rig.server.object("Task", id))
        XCTAssertEqual(onServer["title"], "Review the release notes")
        XCTAssertEqual(onServer["taskListIds"], [.init(rig.workId): true])
        XCTAssertEqual(onServer["nerfjournal.semiotic.systems:autoCancel"], true)
        XCTAssertNil(onServer["keywords"])

        let tasks = try await rig.sync.tasks()
        XCTAssertEqual(tasks.count, 1)
        let decoded = TaskCodec.decode(tasks[0].value, id: tasks[0].key.rawValue, lists: lists)
        XCTAssertEqual(decoded, Todo(id: key.rawValue, title: todo.title, shouldMigrate: false,
                                     start: todo.start, categoryID: work.key.rawValue, externalURL: todo.externalURL))
        let status = try await rig.sync.status()
        XCTAssertEqual(status.pendingCount, 0)
    }

    func testForeignTaskArrivesOnSync() async throws {
        let rig = try Rig()
        let id = rig.server.create("Task", [
            "title": "From elsewhere", "start": "2026-09-13T09:00:00", "progress": "failed",
            "updated": "2026-09-14T12:00:00Z", "taskListIds": [.init(rig.listId): true],
        ])
        try await rig.sync.engine.sync()
        let lists = try await rig.sync.listIndex()
        let stored = try await rig.sync.engine.object(type: "Task", id: id)
        let synced = try XCTUnwrap(stored)
        let decoded = TaskCodec.decode(synced.value, id: synced.key.rawValue, lists: lists, zone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(decoded, Todo(id: synced.key.rawValue, title: "From elsewhere", shouldMigrate: true,
                                     start: day("2026-09-13"), ending: TodoEnding(day: day("2026-09-14"), kind: .abandoned)))
    }

    func testSignalNameIsStableAndShort() {
        let a = JournalSync.signalName(forDatabaseAt: "/a/journal.sqlite")
        XCTAssertEqual(a, JournalSync.signalName(forDatabaseAt: "/a/journal.sqlite"))
        XCTAssertNotEqual(a, JournalSync.signalName(forDatabaseAt: "/b/journal.sqlite"))
        XCTAssertTrue(a.hasPrefix("systems.semiotic.nerfjournal.jinx."))
        XCTAssertEqual(a.count, "systems.semiotic.nerfjournal.jinx.".count + 16)
    }

    func testSettingsSources() {
        XCTAssertEqual(SyncSettings.from(environment: [:]), .prototype)
        XCTAssertEqual(
            SyncSettings.from(environment: ["NERF_JMAP_URL": "https://jmap.example/session", "NERF_JMAP_ACCOUNT": "u1"]),
            SyncSettings(sessionURL: URL(string: "https://jmap.example/session")!, accountId: "u1"))
        // Registered rather than set: a set value is written to disk, and
        // the suite would leave a plist in ~/Library/Preferences on every
        // run. -- claude, 2026-10-30
        let defaults = UserDefaults(suiteName: "systems.semiotic.nerfjournal.tests.\(UUID().uuidString)")!
        XCTAssertEqual(SyncSettings.from(defaults), .prototype)
        defaults.register(defaults: [
            SyncSettings.sessionURLDefaultsKey: "https://jmap.example/session",
            SyncSettings.accountIdDefaultsKey: "u2",
        ])
        XCTAssertEqual(SyncSettings.from(defaults),
                       SyncSettings(sessionURL: URL(string: "https://jmap.example/session")!, accountId: "u2"))
    }

    func testSettingsLayerAndReadPreferencesFiles() throws {
        let saved = SyncSettings(sessionURL: URL(string: "https://saved.example/session")!, accountId: "saved")
        checkSettings(environment: [:], over: saved, expecting: saved)
        checkSettings(environment: ["NERF_JMAP_URL": "https://env.example/session"], over: saved,
                      expecting: SyncSettings(sessionURL: URL(string: "https://env.example/session")!, accountId: "saved"))
        checkSettings(environment: ["NERF_JMAP_ACCOUNT": ""], over: saved, expecting: saved)

        try checkPreferences(["jmapSessionURL": "https://file.example/session", "jmapAccountId": "f"],
                             expecting: SyncSettings(sessionURL: URL(string: "https://file.example/session")!, accountId: "f"))
        try checkPreferences(["jmapAccountId": "f", "other": 1],
                             expecting: SyncSettings(sessionURL: SyncSettings.prototype.sessionURL, accountId: "f"))
        try checkPreferences([:], expecting: .prototype)
        XCTAssertNil(SyncSettings.from(preferencesAt: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).plist")))
    }

    private func checkSettings(environment: [String: String], over base: SyncSettings, expecting expected: SyncSettings,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(SyncSettings.from(environment: environment, over: base), expected, file: file, line: line)
    }

    private func checkPreferences(_ values: [String: Any], expecting expected: SyncSettings,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: url) }
        try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: url)
        XCTAssertEqual(SyncSettings.from(preferencesAt: url), expected, file: file, line: line)
    }
}
