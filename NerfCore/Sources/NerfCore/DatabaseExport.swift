import Foundation
import GRDB

// Snapshot of the journal, used for export and import.
public struct DatabaseExport: Codable, Sendable {
    // The export file format version (NerfSchema.currentVersion) at export
    // time. Not consumed on import, but retained so future code can gate
    // on it. -- claude, 2026-03-02
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
}

