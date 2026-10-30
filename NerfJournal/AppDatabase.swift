import Foundation
import GRDB
import NerfCore

extension Notification.Name {
    static let nerfJournalDatabaseDidChange = Notification.Name("systems.semiotic.nerfjournal.databaseDidChange")
    // Posted by PageStore.refreshContents() so other stores can stay in sync
    // with live todo mutations without a full database reload. -- claude, 2026-03-06
    static let nerfJournalTodosDidChange = Notification.Name("systems.semiotic.nerfjournal.todosDidChange")
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

    // Export, import and reset span both halves of the store (the journal's
    // own tables and the engine's), so NerfCore owns them. -- claude, 2026-10-28
    func exportData() async throws -> Data {
        try await sync.exportData()
    }

    func importData(_ data: Data) async throws {
        _ = try await sync.importData(data)
    }

    // Empties this client only. The server keeps its Tasks, and the next
    // sync fetches them again.
    func factoryReset() async throws {
        try await sync.resetLocalData()
    }
}
