import Foundation
import GRDB
import NerfCore

@MainActor
final class CategoryStore: ObservableObject {
    private let db: AppDatabase
    private let writer: TaskWriter

    @Published var categories: [Category] = []

    init(database: AppDatabase = .shared) {
        self.db = database
        self.writer = TaskWriter(sync: database.sync)
        for name: Notification.Name in [.nerfJournalDatabaseDidChange, .nerfCategoriesDidChange] {
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await self.load()
                }
            }
        }
    }

    func load() async throws {
        categories = try await db.dbQueue.read { db in
            try Category.order(Column("sortOrder")).fetchAll(db)
        }
    }

    func addCategory(name: String, color: CategoryColor = .blue) async throws {
        let nextOrder = (categories.map(\.sortOrder).max() ?? -1) + 1
        try await db.dbQueue.write { db in
            var category = Category(id: nil, name: name, color: color, sortOrder: nextOrder)
            try category.insert(db)
        }
        try await load()
    }

    // A category is known to the server only as the keyword on each Task,
    // so deleting or renaming one rewrites those keywords, in one batch. The
    // Tasks go first: if the local row changed first and the rewrite then
    // failed, the next read would see an unknown keyword and recreate the
    // old category. -- claude, 2026-10-28
    func deleteCategory(_ category: Category) async throws {
        try await writer.removeCategoryKeyword(named: category.name)
        try await db.dbQueue.write { db in
            try Category.filter(Column("id") == category.id).deleteAll(db)
            return
        }
        try await load()
    }

    func renameCategory(_ category: Category, to name: String) async throws {
        try await writer.renameCategoryKeyword(from: category.name, to: name)
        try await db.dbQueue.write { db in
            try Category
                .filter(Column("id") == category.id)
                .updateAll(db, [Column("name").set(to: name)])
            return
        }
        try await load()
    }

    func setCategoryColor(_ color: CategoryColor, for category: Category) async throws {
        try await db.dbQueue.write { db in
            try Category
                .filter(Column("id") == category.id)
                .updateAll(db, [Column("color").set(to: color)])
            return
        }
        try await load()
    }

    func moveCategories(from offsets: IndexSet, to destination: Int) async throws {
        var cats = categories
        cats.move(fromOffsets: offsets, toOffset: destination)
        try await db.dbQueue.write { [cats] db in
            for (index, cat) in cats.enumerated() {
                try Category
                    .filter(Column("id") == cat.id)
                    .updateAll(db, [Column("sortOrder").set(to: index)])
            }
        }
        try await load()
    }
}
