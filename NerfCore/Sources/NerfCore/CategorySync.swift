import Foundation
import GRDB
import Jinx
import JinxJSON
import JinxStore

extension Notification.Name {
    // Posted by JournalSync after it creates a Category for a keyword it
    // had not seen, so a store holding the category list can reload.
    public static let nerfCategoriesDidChange = Notification.Name("org.rjbs.nerfjournal.categoriesDidChange")
}

// Categories have no object on the server; a Task carries its category as
// a keyword by name, and each client keeps its own color and order. Two
// things keep that honest. Reading creates a local Category for any name
// it does not know, so a category made on one client appears on another
// (the one write-on-read the spec allows, and it touches only local
// state). Renaming or deleting a Category rewrites the keyword on every
// Task carrying it, in one batch. -- claude, 2026-10-28
extension JournalSync {
    // Creates a Category, with the default color and appended to the sort
    // order, for every category keyword in the store that names none.
    // Returns the categories it created.
    @discardableResult
    public func adoptUnknownCategories() async throws -> [Category] {
        let names = Set(try await tasks().flatMap { TaskCodec.categoryNames(in: $0.value) })
        guard !names.isEmpty else { return [] }
        let created = try await writer.write { db -> [Category] in
            let known = Set(try Category.fetchAll(db).map(\.name))
            var nextOrder = (try Int.fetchOne(db, sql: "SELECT max(sortOrder) FROM category") ?? -1) + 1
            var created: [Category] = []
            for name in names.subtracting(known).sorted() {
                var category = Category(id: nil, name: name, color: .blue, sortOrder: nextOrder)
                try category.insert(db)
                created.append(category)
                nextOrder += 1
            }
            return created
        }
        if !created.isEmpty {
            NotificationCenter.default.post(name: .nerfCategoriesDidChange, object: nil)
        }
        return created
    }
}

extension TaskWriter {
    // Every Task carrying the keyword for `name`, by local key.
    private func keysCarrying(_ name: String) async throws -> [LocalKey] {
        try await sync.tasks().filter { object in
            object.pending != .destroy && TaskCodec.categoryNames(in: object.value).contains(name)
        }.map(\.key)
    }

    // Moves every carrying Task from one keyword to another. The Tasks'
    // other keywords are untouched; the diff for each is one removal and
    // one addition.
    public func renameCategoryKeyword(from oldName: String, to newName: String) async throws {
        guard oldName != newName else { return }
        let keys = try await keysCarrying(oldName)
        try await rewriteKeywords(keys) { keywords in
            keywords[TaskCodec.categoryKeywordPrefix + oldName] = nil
            keywords[TaskCodec.categoryKeywordPrefix + newName] = true
        }
    }

    // Removes the keyword for `name` from every carrying Task, which leaves
    // them uncategorized.
    public func removeCategoryKeyword(named name: String) async throws {
        let keys = try await keysCarrying(name)
        try await rewriteKeywords(keys) { keywords in
            keywords[TaskCodec.categoryKeywordPrefix + name] = nil
        }
    }

    private func rewriteKeywords(_ keys: [LocalKey], _ change: @Sendable (inout [String: JSONValue]) -> Void) async throws {
        guard !keys.isEmpty else { return }
        try await sync.engine.write { writer in
            for key in keys {
                try writer.update(key) { current in
                    var task = current
                    var keywords = current["keywords"]?.objectValue ?? [:]
                    change(&keywords)
                    task["keywords"] = keywords.isEmpty ? nil : .object(keywords)
                    return task
                }
            }
        }
    }
}
