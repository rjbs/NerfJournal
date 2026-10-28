import Foundation
import GRDB
import NerfCore

extension Notification.Name {
    static let nerfJournalDatabaseDidChange = Notification.Name("org.rjbs.nerfjournal.databaseDidChange")
    // Posted by PageStore.refreshContents() so other stores can stay in sync
    // with live todo mutations without a full database reload. -- claude, 2026-03-06
    static let nerfJournalTodosDidChange = Notification.Name("org.rjbs.nerfjournal.todosDidChange")
}

struct AppDatabase {
    let dbQueue: DatabaseQueue
    // The journal's sync engine, sharing the database file. Built here so
    // that it exists exactly once per process; AppDelegate starts it
    // running at launch. -- claude, 2026-10-28
    let sync: JournalSync

    static let shared: AppDatabase = {
        let fm = FileManager.default
        let support = try! fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = support.appendingPathComponent("NerfJournal", isDirectory: true)
        try! fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("journal.sqlite").path
        return try! AppDatabase(path: path)
    }()

    init(path: String) throws {
        dbQueue = try DatabaseQueue(path: path)
        try NerfSchema.migrate(dbQueue)
        sync = try JournalSync(writer: dbQueue, databasePath: path, settings: SyncSettings.from(.standard))
    }

    func exportData() async throws -> Data {
        let snapshot = try await dbQueue.read { db in
            DatabaseExport(
                version: NerfSchema.currentVersion,
                exportedAt: Date(),
                categories: try Category.order(Column("sortOrder")).fetchAll(db),
                taskBundles: try TaskBundle.order(Column("id")).fetchAll(db),
                bundleTodos: try BundleTodo.order(Column("id")).fetchAll(db),
                journalPages: try JournalPage.order(Column("date")).fetchAll(db),
                todos: try Todo.order(Column("id")).fetchAll(db)
            )
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(snapshot)
    }

    // Replaces all data with the contents of the export. The entire operation
    // runs in one transaction, so a malformed import leaves the database unchanged.
    func importData(_ data: Data) async throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(DatabaseExport.self, from: data)
        try await dbQueue.write { db in
            try Todo.deleteAll(db)
            try BundleTodo.deleteAll(db)
            try JournalPage.deleteAll(db)
            try TaskBundle.deleteAll(db)
            try Category.deleteAll(db)
            for var r in snapshot.categories   { try r.insert(db) }
            for var r in snapshot.taskBundles  { try r.insert(db) }
            for var r in snapshot.bundleTodos  { try r.insert(db) }
            for var r in snapshot.journalPages { try r.insert(db) }
            for var r in snapshot.todos        { try r.insert(db) }
        }
    }

    func factoryReset() async throws {
        try await dbQueue.write { db in
            try Todo.deleteAll(db)
            try BundleTodo.deleteAll(db)
            try JournalPage.deleteAll(db)
            try TaskBundle.deleteAll(db)
            try Category.deleteAll(db)
            return
        }
    }
}
