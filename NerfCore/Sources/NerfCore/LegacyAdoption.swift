import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore

// The one-time steps that move data a schema migration staged into the
// sync engine. Each runs at launch, does nothing once its staging table is
// gone, and is safe to run again after a crash at any point.
// -- claude, 2026-10-28
extension JournalSync {

    // MARK: - Categories (schema v10)

    public struct CategoryAdoptionReport: Sendable, Hashable {
        // Legacy categories that became new TaskLists on this run.
        public var created: Int
        // Legacy categories matched to a list that already existed, by name.
        public var matched: Int
        // Tasks moved out of a category keyword into their list.
        public var tasksMoved: Int

        public init(created: Int, matched: Int, tasksMoved: Int) {
            self.created = created
            self.matched = matched
            self.tasksMoved = tasksMoved
        }
    }

    private struct LegacyCategory: Sendable {
        var id: Int64
        var name: String
        var color: CategoryColor
        var sortOrder: Int
        var listKey: Int64?
    }

    // Turns the categories migration v10 staged in category_legacy into
    // TaskLists, moves every Task carrying a category keyword into its
    // list, points bundle todos, export groups and any staged legacy todos
    // at the lists, and drops the table. Returns nil when there is no
    // table.
    //
    // The lists must reach the server before a Task can be filed in them,
    // so this syncs in the middle; without the server it throws, and the
    // next launch tries again. Each step is idempotent: a legacy category
    // records its list's key as soon as the list exists and is matched by
    // name if that record was lost, a moved Task carries no keyword, and
    // the reference rewrite and the drop are one transaction.
    public func adoptLegacyCategories() async throws -> CategoryAdoptionReport? {
        let staged = try await writer.read { db -> [LegacyCategory]? in
            guard try db.tableExists("category_legacy") else { return nil }
            return try Row.fetchAll(db, sql: "SELECT * FROM category_legacy ORDER BY sortOrder, id").map { row in
                LegacyCategory(
                    id: row["id"],
                    name: row["name"],
                    color: CategoryColor(rawValue: row["color"]) ?? .blue,
                    sortOrder: row["sortOrder"],
                    listKey: row["listKey"]
                )
            }
        }
        guard var legacy = staged else { return nil }

        // Step 1: every legacy category gets a list, and remembers it.
        var index = try await listIndex()
        var created = 0, matched = 0
        for i in legacy.indices where legacy[i].listKey == nil {
            let key: LocalKey
            if let existing = index.entry(named: legacy[i].name) {
                key = existing.key
                matched += 1
            } else {
                let encoding = TaskListIndex.encodeList(name: legacy[i].name, color: legacy[i].color, sortOrder: legacy[i].sortOrder)
                key = try await engine.create(Self.listType.name, encoding)
                index = try await listIndex()
                created += 1
            }
            legacy[i].listKey = key.rawValue
            let (id, rawKey) = (legacy[i].id, key.rawValue)
            try await writer.write { db in
                try db.execute(sql: "UPDATE category_legacy SET listKey = ? WHERE id = ?", arguments: [rawKey, id])
            }
        }

        // Step 2: the new lists need server ids before Tasks can name them.
        if legacy.contains(where: { index.entry(forCategory: $0.listKey!)?.serverId == nil }) {
            try await engine.sync()
            index = try await listIndex()
        }
        var listIdByName: [String: String] = [:]
        for category in legacy {
            guard let id = index.entry(forCategory: category.listKey!)?.serverId else {
                throw JournalSyncError.categoryNotSynced(category.name)
            }
            listIdByName[category.name] = id
        }

        // Step 3: Tasks leave their keyword for their list. A Task naming
        // several categories takes the first in legacy order, as the
        // keyword decoder did.
        let legacyOrder = legacy.map(\.name)
        var moves: [LocalKey: String] = [:]
        for object in try await tasks() where object.pending != .destroy {
            let names = TaskCodec.legacyCategoryNames(in: object.value)
            guard let name = legacyOrder.first(where: names.contains), let listId = listIdByName[name] else { continue }
            moves[object.key] = listId
        }
        if !moves.isEmpty {
            let prefix = TaskCodec.legacyCategoryKeywordPrefix
            let movesNow = moves
            try await engine.write { writer in
                for (key, listId) in movesNow {
                    try writer.update(key) { current in
                        var task = current
                        task["taskListIds"] = .object([listId: true])
                        var keywords = current["keywords"]?.objectValue ?? [:]
                        for keyword in keywords.keys where keyword.hasPrefix(prefix) { keywords[keyword] = nil }
                        task["keywords"] = keywords.isEmpty ? nil : .object(keywords)
                        return task
                    }
                }
            }
        }

        // Step 4: references follow, and the staging table goes, together.
        let mapping = Dictionary(uniqueKeysWithValues: legacy.map { ($0.id, $0.listKey!) })
        try await writer.write { db in
            try Self.remapCategoryReferences(db, mapping)
            try db.execute(sql: "DROP TABLE category_legacy")
        }
        return CategoryAdoptionReport(created: created, matched: matched, tasksMoved: moves.count)
    }

    // Rewrites every categoryID column through `mapping` in one statement
    // per table, so no row is mapped twice. A reference to a category the
    // mapping lacks becomes no category; an export group membership for
    // one is removed, since NULL there means the "Other" bucket.
    static func remapCategoryReferences(_ db: Database, _ mapping: [Int64: Int64]) throws {
        let cases = mapping.map { "WHEN \($0.key) THEN \($0.value)" }.joined(separator: " ")
        let expression = cases.isEmpty ? "NULL" : "CASE categoryID \(cases) ELSE NULL END"
        let known = mapping.keys.map(String.init).joined(separator: ", ")
        try db.execute(sql: "UPDATE bundleTodo SET categoryID = \(expression) WHERE categoryID IS NOT NULL")
        try db.execute(sql: "DELETE FROM exportGroupMember WHERE categoryID IS NOT NULL AND categoryID NOT IN (\(known.isEmpty ? "-1" : known))")
        try db.execute(sql: "UPDATE exportGroupMember SET categoryID = \(expression) WHERE categoryID IS NOT NULL")
        if try db.tableExists("todo_legacy") {
            try db.execute(sql: "UPDATE todo_legacy SET categoryID = \(expression) WHERE categoryID IS NOT NULL")
        }
    }

    // MARK: - Todos (schema v9)

    public struct AdoptionReport: Sendable, Hashable {
        // Rows turned into pending creates on this run.
        public var adopted: Int
        // Rows a previous run had already adopted, found by uid.
        public var alreadyPresent: Int

        public init(adopted: Int, alreadyPresent: Int) {
            self.adopted = adopted
            self.alreadyPresent = alreadyPresent
        }
    }

    private struct LegacyRow: Sendable {
        var uid: String
        var todo: Todo
    }

    // Moves the todos migration v9 staged in todo_legacy into the engine as
    // pending creates, then drops the table. Returns nil when there is no
    // table, which is every launch after the first successful one. Safe to
    // run again after a crash at any point: rows already adopted are
    // recognized by uid and skipped. The creates reach the server through
    // the engine's ordinary sync-out. Runs after adoptLegacyCategories,
    // which has rewritten each row's categoryID to a list key.
    public func adoptLegacyTodos() async throws -> AdoptionReport? {
        let staged = try await writer.read { db -> [LegacyRow]? in
            guard try db.tableExists("todo_legacy") else { return nil }
            return try Row.fetchAll(db, sql: "SELECT * FROM todo_legacy ORDER BY id").map { row in
                LegacyRow(
                    uid: row["uid"],
                    todo: Todo(
                        id: row["id"],
                        title: row["title"],
                        shouldMigrate: row["shouldMigrate"],
                        start: row["start"],
                        ending: row["ending"],
                        categoryID: row["categoryID"],
                        externalURL: row["externalURL"]
                    )
                )
            }
        }
        guard let staged else { return nil }

        let lists = try await listIndex()
        let present = Set(try await tasks().compactMap { $0.value["uid"]?.stringValue })
        let fresh = staged.filter { !present.contains($0.uid) }
        if !fresh.isEmpty {
            let encodings = try fresh.map {
                try TaskCodec.encodeNew($0.todo, lists: lists, uid: $0.uid, now: nil)
            }
            try await engine.write { writer in
                _ = try writer.adopt(Self.taskType.name, encodings)
            }
        }
        try await writer.write { db in
            try db.execute(sql: "DROP TABLE todo_legacy")
        }
        return AdoptionReport(adopted: fresh.count, alreadyPresent: staged.count - fresh.count)
    }
}
