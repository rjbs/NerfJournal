import Foundation
import GRDB

/// The whole journal, as written to an export file and read from one.
///
/// Made by ``JournalSync/exportSnapshot()`` and read by
/// ``JournalSync/importSnapshot(_:)``.
public struct DatabaseExport: Codable, Sendable {
    /// The version of the export file's format, from
    /// ``NerfSchema/currentVersion`` when it was made.
    ///
    /// Importing doesn't read it, but it is kept so that future code can
    /// tell one format from another.
    public let version: Int

    /// When the export was made.
    ///
    /// Importing doesn't read it, but it is useful to someone looking at an
    /// export file.
    public let exportedAt: Date

    /// The categories.  On import, each is matched to a category by name, or
    /// created.
    public let categories: [Category]

    /// The bundles.
    public let taskBundles: [TaskBundle]

    /// The todos in the bundles.
    public let bundleTodos: [BundleTodo]

    /// The pages.
    public let journalPages: [JournalPage]

    /// The todos, each with its Task's uid.
    public let todos: [ExportedTodo]

    /// Makes an export from its parts.
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
