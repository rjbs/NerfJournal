import Foundation
import GRDB

@MainActor
final class BundleStore: ObservableObject {
    private let db: AppDatabase

    @Published var bundles: [TaskBundle] = []
    @Published var selectedBundle: TaskBundle? = nil
    @Published var selectedBundleTodos: [BundleTodo] = []

    init(database: AppDatabase = .shared) {
        self.db = database
    }

    func load() async throws {
        bundles = try await db.dbQueue.read { db in
            try TaskBundle
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db)
        }
    }

    func selectBundle(_ bundle: TaskBundle?) async throws {
        selectedBundle = bundle
        guard let bundleID = bundle?.id else {
            selectedBundleTodos = []
            return
        }
        selectedBundleTodos = try await db.dbQueue.read { db in
            try BundleTodo
                .filter(Column("bundleID") == bundleID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }

    func addBundle(name: String) async throws {
        let nextOrder = (bundles.map(\.sortOrder).max() ?? -1) + 1
        try await db.dbQueue.write { db in
            var bundle = TaskBundle(id: nil, name: name, sortOrder: nextOrder, todosShouldMigrate: true)
            try bundle.insert(db)
        }
        try await load()
    }

    func deleteBundle(_ bundle: TaskBundle) async throws {
        try await db.dbQueue.write { db in
            try TaskBundle.filter(Column("id") == bundle.id).deleteAll(db)
            return
        }
        if selectedBundle?.id == bundle.id {
            selectedBundle = nil
            selectedBundleTodos = []
        }
        try await load()
    }

    func renameBundle(_ bundle: TaskBundle, to name: String) async throws {
        try await db.dbQueue.write { db in
            try TaskBundle
                .filter(Column("id") == bundle.id)
                .updateAll(db, [Column("name").set(to: name)])
            return
        }
        try await load()
        if selectedBundle?.id == bundle.id {
            selectedBundle = bundles.first { $0.id == bundle.id }
        }
    }

    func setTodosShouldMigrate(_ value: Bool, for bundle: TaskBundle) async throws {
        try await db.dbQueue.write { db in
            try TaskBundle
                .filter(Column("id") == bundle.id)
                .updateAll(db, [Column("todosShouldMigrate").set(to: value)])
            return
        }
        try await load()
        if selectedBundle?.id == bundle.id {
            selectedBundle = bundles.first { $0.id == bundle.id }
        }
    }

    func addTodo(title: String) async throws {
        guard let bundleID = selectedBundle?.id else { return }
        let nextOrder = (selectedBundleTodos.map(\.sortOrder).max() ?? -1) + 1
        try await db.dbQueue.write { db in
            var todo = BundleTodo(id: nil, bundleID: bundleID, title: title, sortOrder: nextOrder, externalURL: nil)
            try todo.insert(db)
        }
        try await refreshTodos()
    }

    func deleteTodo(_ todo: BundleTodo) async throws {
        try await db.dbQueue.write { db in
            try BundleTodo.filter(Column("id") == todo.id).deleteAll(db)
            return
        }
        try await refreshTodos()
    }

    func moveTodos(from offsets: IndexSet, to destination: Int) async throws {
        var todos = selectedBundleTodos
        todos.move(fromOffsets: offsets, toOffset: destination)
        try await db.dbQueue.write { [todos] db in
            for (index, todo) in todos.enumerated() {
                try BundleTodo
                    .filter(Column("id") == todo.id)
                    .updateAll(db, [Column("sortOrder").set(to: index)])
            }
        }
        try await refreshTodos()
    }

    private func refreshTodos() async throws {
        guard let bundleID = selectedBundle?.id else { return }
        selectedBundleTodos = try await db.dbQueue.read { db in
            try BundleTodo
                .filter(Column("bundleID") == bundleID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
    }
}
