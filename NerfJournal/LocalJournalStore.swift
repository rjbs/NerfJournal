import Foundation
import GRDB

@MainActor
final class LocalJournalStore: ObservableObject {
    private let db: AppDatabase

    @Published var page: JournalPage?
    @Published var todos: [Todo] = []
    @Published var notes: [Note] = []

    init(database: AppDatabase = .shared) {
        self.db = database
    }

    // Load the most recent journal page, without creating one if none exists.
    func load() async throws {
        page = try await db.dbQueue.read { db in
            try JournalPage
                .order(Column("date").desc)
                .fetchOne(db)
        }
        try await refreshContents()
    }

    // Create today's page. Pending non-migratable todos from before today are
    // abandoned; migratable ones carry forward naturally (no action needed).
    func startToday() async throws {
        let today = Self.startOfToday
        let now = Date()

        let newPage: JournalPage = try await db.dbQueue.write { db in
            var p = JournalPage(id: nil, date: today)
            try p.insert(db)

            let abandonment = TodoEnding(date: now, kind: .abandoned)
            try Todo
                .filter(Column("added") < today)
                .filter(Column("shouldMigrate") == false)
                .filter(Column("ending") == nil)
                .updateAll(db, [Column("ending").set(to: abandonment)])

            return p
        }

        page = newPage
        try await refreshContents()
    }

    func completeTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        let ending = TodoEnding(date: Date(), kind: .done)
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: ending)])
            return
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.uncompleteTodo(todo, undoManager: undoManager) }
        }
        try await refreshContents()
    }

    func uncompleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: nil as TodoEnding?)])
            return
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.completeTodo(todo, undoManager: undoManager) }
        }
        try await refreshContents()
    }

    func abandonTodo(_ todo: Todo) async throws {
        let ending = TodoEnding(date: Date(), kind: .abandoned)
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: ending)])
            return
        }
        try await refreshContents()
    }

    // Mark any non-pending todo as pending. Used by the context menu.
    func markPending(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldEnding = todo.ending
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: nil as TodoEnding?)])
            return
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in
                if oldEnding?.kind == .done {
                    try? await store.completeTodo(todo, undoManager: undoManager)
                } else if oldEnding?.kind == .abandoned {
                    try? await store.abandonTodo(todo)
                }
            }
        }
        try await refreshContents()
    }

    func addTodo(title: String, shouldMigrate: Bool, categoryID: Int64? = nil) async throws {
        guard page != nil else { return }
        let today = Self.startOfToday
        try await db.dbQueue.write { db in
            var todo = Todo(
                id: nil,
                title: title,
                shouldMigrate: shouldMigrate,
                added: today,
                ending: nil,
                categoryID: categoryID,
                externalURL: nil
            )
            try todo.insert(db)
        }
        try await refreshContents()
    }

    func addNote(text: String, relatedTodo: Todo? = nil) async throws {
        guard let pageID = page?.id else { return }
        try await db.dbQueue.write { db in
            var note = Note(
                id: nil,
                pageID: pageID,
                timestamp: Date(),
                text: text,
                relatedTodoID: relatedTodo?.id
            )
            try note.insert(db)
        }
        try await refreshContents()
    }

    func setTitle(_ title: String, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldTitle = todo.title
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("title").set(to: title)])
            return
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.setTitle(oldTitle, for: todo, undoManager: undoManager) }
        }
        try await refreshContents()
    }

    func deleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await db.dbQueue.write { db in
            try Todo.filter(Column("id") == todo.id).deleteAll(db)
            return
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.restoreTodo(todo) }
        }
        try await refreshContents()
    }

    func setCategory(_ categoryID: Int64?, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldCategoryID = todo.categoryID
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("categoryID").set(to: categoryID)])
            return
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.setCategory(oldCategoryID, for: todo, undoManager: undoManager) }
        }
        try await refreshContents()
    }

    func setURL(_ url: String?, for todo: Todo) async throws {
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("externalURL").set(to: url)])
            return
        }
        try await refreshContents()
    }

    private func restoreTodo(_ todo: Todo) async throws {
        guard page != nil else { return }
        try await db.dbQueue.write { db in
            var restored = todo
            try restored.insert(db)
        }
        try await refreshContents()
    }

    func applyBundle(_ bundle: TaskBundle) async throws {
        guard page != nil, let bundleID = bundle.id else { return }
        let bundleTodos = try await db.dbQueue.read { db in
            try BundleTodo
                .filter(Column("bundleID") == bundleID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
        let today = Self.startOfToday
        try await db.dbQueue.write { [bundleTodos] db in
            for bundleTodo in bundleTodos {
                var todo = Todo(
                    id: nil,
                    title: bundleTodo.title,
                    shouldMigrate: bundle.todosShouldMigrate,
                    added: today,
                    ending: nil,
                    categoryID: bundleTodo.categoryID,
                    externalURL: bundleTodo.externalURL
                )
                try todo.insert(db)
            }
        }
        try await refreshContents()
    }

    func exportData() async throws -> Data {
        try await db.exportData()
    }

    func importDatabase(_ data: Data) async throws {
        try await db.importData(data)
        try await load()
        NotificationCenter.default.post(name: .nerfJournalDatabaseDidChange, object: nil)
    }

    func factoryReset() async throws {
        try await db.factoryReset()
        try await load()
        NotificationCenter.default.post(name: .nerfJournalDatabaseDidChange, object: nil)
    }

    private func refreshContents() async throws {
        guard page != nil, let pageID = page?.id else {
            todos = []
            notes = []
            return
        }
        let today = Self.startOfToday
        let (allTodos, fetchedNotes) = try await db.dbQueue.read { db in
            let t = try Todo
                .filter(Column("added") <= today)
                .fetchAll(db)
            let n = try Note
                .filter(Column("pageID") == pageID)
                .order(Column("timestamp"))
                .fetchAll(db)
            return (t, n)
        }
        todos = allTodos
            .filter { todo in
                guard let ending = todo.ending else { return true }
                return ending.date >= today
            }
            .sortedForDisplay()
        notes = fetchedNotes
    }

    private static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }
}
