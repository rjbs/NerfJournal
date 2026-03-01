import Foundation
import GRDB

@MainActor
final class CategoryStore: ObservableObject {
    private let db: AppDatabase

    @Published var categories: [Category] = []

    init(database: AppDatabase = .shared) {
        self.db = database
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

    func deleteCategory(_ category: Category) async throws {
        try await db.dbQueue.write { db in
            try Category.filter(Column("id") == category.id).deleteAll(db)
            return
        }
        try await load()
    }

    func renameCategory(_ category: Category, to name: String) async throws {
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
