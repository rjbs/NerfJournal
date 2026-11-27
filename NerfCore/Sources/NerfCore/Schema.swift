import Foundation
import GRDB
import JinxStore

/// The journal's SQLite schema.
///
/// Todos and categories live on the JMAP server, and are held locally in
/// the sync engine's own tables.  These are the tables beside them, for
/// what is kept by this client alone: bundles, pages, and export groups.
public enum NerfSchema {
    /// The version of the export file's format, recorded in each export.
    ///
    /// It must be raised when the shape of ``DatabaseExport`` changes.
    public static let currentVersion = 10

    /// Brings the database up to date, creating the journal's tables and
    /// the sync engine's, as needed.
    ///
    /// The app does this at launch, and the CLI expects it to have been
    /// done.
    public static func migrate(_ db: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("schema") { db in
            try db.create(table: "taskBundle") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("todosShouldMigrate", .boolean).notNull().defaults(to: true)
            }

            // categoryID is a sync-engine local key for a TaskList, so no
            // foreign key: CategoryWriter.delete clears it.
            try db.create(table: "bundleTodo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("bundleID", .integer).notNull()
                    .references("taskBundle", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("externalURL", .text)
                t.column("categoryID", .integer)
            }

            try db.create(table: "journalPage") { t in
                t.autoIncrementedPrimaryKey("id")
                // A civil date, "YYYY-MM-DD".
                t.column("date", .text).notNull().unique()
            }

            try db.create(table: "exportGroup") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // NULL categoryID represents uncategorized ("Other") todos.
            try db.create(table: "exportGroupMember") { t in
                t.column("groupID", .integer).notNull()
                    .references("exportGroup", onDelete: .cascade)
                t.column("categoryID", .integer)
            }
        }

        // The sync engine's own tables (jinx_object, jinx_pending, ...) live
        // in the same file as the journal, so one migrator owns both. Jinx's
        // migrations go last so that any later journal migration can still be
        // slotted in before them. -- claude, 2026-10-28
        GRDBSyncStore.registerMigrations(in: &migrator)

        try migrator.migrate(db)
    }
}
