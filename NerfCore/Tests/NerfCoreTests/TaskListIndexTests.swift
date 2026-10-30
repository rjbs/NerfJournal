import XCTest
import GRDB
import Jinx
import JinxJSON
import JinxScriptedServer
import JinxStore
import JinxTypes
import NerfCore

private typealias Category = NerfCore.Category

// A client over a scripted server whose lists the test chooses.
private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync

    init() throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        sync = try JournalSync(
            writer: db,
            settings: SyncSettings(sessionURL: ScriptedServer.baseUrl, accountId: "rjbs"),
            transport: server,
            signalName: nil
        )
    }

    @discardableResult
    func list(_ name: String, _ extra: [String: JSONValue] = [:]) -> String {
        var value: [String: JSONValue] = ["name": .string(name)]
        value.merge(extra) { _, new in new }
        return server.create("TaskList", .object(value))
    }
}

final class TaskListIndexTests: XCTestCase {

    // MARK: - Colors

    func testCSSColorsRead() {
        checkColor("blue", expecting: .blue)
        checkColor(" Teal ", expecting: .teal)
        checkColor("#0000ff", expecting: .blue)
        checkColor("#FF0000", expecting: .red)
        checkColor("#f00", expecting: .red)
        checkColor("#ffb6c1", expecting: .pink, "light pink is nearest pink")
        checkColor("#20b2aa", expecting: .teal, "light sea green is nearest teal")
        checkColor("rebeccapurple", expecting: nil)
        checkColor("#12345", expecting: nil)
        checkColor("", expecting: nil)
    }

    func testDerivedColorIsStable() {
        for name in ["Work", "Home", "Errands", "", "日本語"] {
            XCTAssertEqual(CategoryColor.derived(from: name), CategoryColor.derived(from: name))
        }
        XCTAssertEqual(CategoryColor.allCases.map(\.cssName), CategoryColor.allCases.map(\.rawValue))
    }

    // MARK: - The index

    func testDefaultIsTheFlaggedListOrElseTheFirst() throws {
        try checkDefault(lists: [("B", ["sortOrder": 1]), ("A", ["sortOrder": 2, "isDefault": true])], expecting: "A")
        try checkDefault(lists: [("B", ["sortOrder": 1]), ("A", ["sortOrder": 2])], expecting: "B")
        try checkDefault(lists: [], expecting: nil)
    }

    func testCategoriesAreTheOtherListsInOrder() async throws {
        let rig = try Rig()
        rig.list("Tasks", ["isDefault": true, "sortOrder": 0])
        rig.list("Home", ["sortOrder": 2, "color": "green"])
        rig.list("Work", ["sortOrder": 1, "color": "#0000ff"])
        rig.list("Misc", ["sortOrder": 1])
        rig.list("Nameless", ["sortOrder": 3, "color": "not a color"])
        rig.list("Doomed", ["sortOrder": 4])
        try await rig.sync.engine.sync()
        let doomed = try await rig.sync.lists().first { $0.value["name"] == "Doomed" }!
        try await rig.sync.engine.destroy(doomed.key)

        let index = try await rig.sync.listIndex()
        XCTAssertEqual(index.entries.map(\.name), ["Tasks", "Misc", "Work", "Home", "Nameless"])
        XCTAssertEqual(index.categories.map(\.name), ["Misc", "Work", "Home", "Nameless"])
        XCTAssertEqual(index.categories.map(\.color), [.derived(from: "Misc"), .blue, .green, .derived(from: "Nameless")])
        XCTAssertEqual(index.categories.map(\.sortOrder), [1, 1, 2, 3])
        XCTAssertEqual(index.categories.map(\.id), index.categoryEntries.map(\.key.rawValue))
        XCTAssertTrue(index.categoryEntries.allSatisfy { $0.serverId != nil })
        XCTAssertEqual(index.entry(named: "Work")?.name, "Work")
        XCTAssertNil(index.entry(named: "Tasks"), "the default list is not a category")
    }

    func testCategoryIDFollowsTheFirstCategoryListInOrder() async throws {
        let rig = try Rig()
        let tasks = rig.list("Tasks", ["isDefault": true])
        let work = rig.list("Work", ["sortOrder": 1])
        let home = rig.list("Home", ["sortOrder": 2])
        try await rig.sync.engine.sync()
        let index = try await rig.sync.listIndex()
        let workKey = try XCTUnwrap(index.entry(named: "Work")).key.rawValue
        let homeKey = try XCTUnwrap(index.entry(named: "Home")).key.rawValue

        XCTAssertEqual(index.categoryID(forListIds: [.init(home): true, .init(work): true]), workKey)
        XCTAssertEqual(index.categoryID(forListIds: [.init(home): true, .init(tasks): true]), homeKey)
        XCTAssertNil(index.categoryID(forListIds: [.init(tasks): true]))
        XCTAssertNil(index.categoryID(forListIds: [.init(work): false]))
        XCTAssertNil(index.categoryID(forListIds: ["L-elsewhere": true]))
        XCTAssertNil(index.categoryID(forListIds: nil))
    }

    func testAnEmptyStoreFetchesListsOnceAndThenReadsLocally() async throws {
        let rig = try Rig()
        let id = rig.list("Tasks", ["isDefault": true])
        let first = try await rig.sync.defaultListId()
        XCTAssertEqual(first, id)
        rig.server.clearRequests()
        let second = try await rig.sync.defaultListId()
        XCTAssertEqual(second, first)
        XCTAssertTrue(rig.server.requests.isEmpty, "a stored answer sends nothing")
    }

    func testNoListsIsAnError() async throws {
        let rig = try Rig()
        do {
            _ = try await rig.sync.defaultListId()
            XCTFail("expected noTaskList")
        } catch JournalSyncError.noTaskList {
        }
    }

    // MARK: - Helpers

    private func checkColor(_ css: String, expecting expected: CategoryColor?, _ note: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CategoryColor(css: css), expected, note, file: file, line: line)
    }

    private func checkDefault(lists: [(String, [String: JSONValue])], expecting expected: String?,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let entries = lists.enumerated().map { offset, list in
            TaskListIndex.Entry(
                key: LocalKey(Int64(offset + 1)), serverId: "L\(offset)", name: list.0, color: .blue,
                sortOrder: list.1["sortOrder"]?.intValue ?? 0,
                isDefault: list.1["isDefault"] == .bool(true)
            )
        }
        XCTAssertEqual(TaskListIndex(entries: entries).defaultEntry?.name, expected, file: file, line: line)
    }
}
