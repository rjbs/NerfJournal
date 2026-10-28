import Foundation
import GRDB

// Snapshot of the entire database, used for export and import.
public struct DatabaseExport: Codable, Sendable {
    // version mirrors the DB schema version at export time. Not currently
    // consumed on import, but retained so future code can gate on it if
    // schema versions diverge. -- claude, 2026-03-02
    public let version: Int
    // exportedAt is informational metadata in the JSON; not used by the
    // importer, but useful to a human inspecting an export file. -- claude, 2026-03-02
    public let exportedAt: Date
    public let categories: [Category]
    public let taskBundles: [TaskBundle]
    public let bundleTodos: [BundleTodo]
    public let journalPages: [JournalPage]
    public let todos: [ExportedTodo]

    public init(version: Int, exportedAt: Date, categories: [Category], taskBundles: [TaskBundle],
         bundleTodos: [BundleTodo], journalPages: [JournalPage], todos: [ExportedTodo]) {
        self.version      = version
        self.exportedAt   = exportedAt
        self.categories   = categories
        self.taskBundles  = taskBundles
        self.bundleTodos  = bundleTodos
        self.journalPages = journalPages
        self.todos        = todos
    }

    // Custom decoder so that imports of pre-v3 exports (lacking `categories`)
    // succeed with an empty category list rather than a decode error. Exports
    // from before notes were removed (v7) carry a `notes` key, which the
    // synthesized CodingKeys ignore — those notes are silently dropped on
    // import. -- claude, 2026-06-18
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version     = try c.decode(Int.self,           forKey: .version)
        exportedAt  = try c.decode(Date.self,          forKey: .exportedAt)
        categories  = try c.decodeIfPresent([Category].self,    forKey: .categories)  ?? []
        taskBundles = try c.decode([TaskBundle].self,  forKey: .taskBundles)
        bundleTodos = try c.decode([BundleTodo].self,  forKey: .bundleTodos)
        journalPages = try c.decode([JournalPage].self, forKey: .journalPages)
        todos       = try c.decode([ExportedTodo].self, forKey: .todos)
    }
}

