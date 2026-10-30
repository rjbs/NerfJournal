import Foundation
import GRDB
import JinxStore
import NerfCore

// Categories are TaskLists in the sync engine; this store reads them
// through JournalSync and writes them through CategoryWriter. Every
// committed change to a TaskList, local or synced in, reloads the list.
// -- claude, 2026-10-28
@MainActor
final class CategoryStore: ObservableObject {
    private let db: AppDatabase
    private let writer: CategoryWriter
    private var changeTask: Task<Void, Never>?

    @Published var categories: [Category] = []

    init(database: AppDatabase = .shared) {
        self.db = database
        self.writer = CategoryWriter(sync: database.sync)
        NotificationCenter.default.addObserver(
            forName: .nerfJournalDatabaseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.load()
            }
        }
        changeTask = Task { [weak self] in
            let changes = await database.sync.engine.changes()
            for await change in changes {
                guard change.types[JournalSync.listType.name] != nil else { continue }
                try? await self?.load()
            }
        }
    }

    isolated deinit {
        changeTask?.cancel()
    }

    private func key(_ category: Category) -> LocalKey { LocalKey(category.id!) }

    func load() async throws {
        categories = try await db.sync.categories()
    }

    func addCategory(name: String, color: CategoryColor = .blue) async throws {
        try await writer.create(name: name, color: color)
        try await load()
    }

    func deleteCategory(_ category: Category) async throws {
        try await writer.delete(key(category))
        try await load()
    }

    func renameCategory(_ category: Category, to name: String) async throws {
        try await writer.rename(key(category), to: name)
        try await load()
    }

    func setCategoryColor(_ color: CategoryColor, for category: Category) async throws {
        try await writer.setColor(key(category), to: color)
        try await load()
    }

    func moveCategories(from offsets: IndexSet, to destination: Int) async throws {
        var cats = categories
        cats.move(fromOffsets: offsets, toOffset: destination)
        try await writer.reorder(cats.map(key))
        try await load()
    }
}
