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

    // Load today's page if one already exists, without creating it.
    func load() async throws {
        let today = Self.startOfToday
        page = try await db.dbQueue.read { db in
            try JournalPage
                .filter(Column("date") == today)
                .fetchOne(db)
        }
        try await refreshContents()
    }

    // Create today's page and carry over any migratable todos from the most
    // recent previous page. All pending todos on that previous page are closed
    // out: shouldMigrate=true ones become .migrated; others become .abandoned.
    func startToday() async throws {
        let today = Self.startOfToday

        let newPage: JournalPage = try await db.dbQueue.write { db in
            let previous = try JournalPage
                .filter(Column("date") < today)
                .order(Column("date").desc)
                .fetchOne(db)

            var page = JournalPage(id: nil, date: today)
            try page.insert(db)

            if let prevID = previous?.id, let pageID = page.id {
                let toCarry = try Todo
                    .filter(Column("pageID") == prevID)
                    .filter(Column("status") == TodoStatus.pending)
                    .filter(Column("shouldMigrate") == true)
                    .order(Column("sortOrder"))
                    .fetchAll(db)

                try Todo
                    .filter(Column("pageID") == prevID)
                    .filter(Column("status") == TodoStatus.pending)
                    .filter(Column("shouldMigrate") == true)
                    .updateAll(db, [Column("status").set(to: TodoStatus.migrated)])

                try Todo
                    .filter(Column("pageID") == prevID)
                    .filter(Column("status") == TodoStatus.pending)
                    .filter(Column("shouldMigrate") == false)
                    .updateAll(db, [Column("status").set(to: TodoStatus.abandoned)])

                for (index, old) in toCarry.enumerated() {
                    var todo = Todo(
                        id: nil,
                        pageID: pageID,
                        title: old.title,
                        shouldMigrate: old.shouldMigrate,
                        status: .pending,
                        sortOrder: index,
                        groupName: old.groupName,
                        externalURL: old.externalURL,
                        firstAddedDate: old.firstAddedDate
                    )
                    try todo.insert(db)
                }
            }

            return page
        }

        page = newPage
        try await refreshContents()
    }

    func completeTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        guard let pageID = page?.id else { return }
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("status").set(to: TodoStatus.done)])
            var note = Note(
                id: nil,
                pageID: pageID,
                timestamp: Date(),
                text: nil,
                relatedTodoID: todo.id
            )
            try note.insert(db)
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.uncompleteTodo(todo) }
        }
        try await refreshContents()
    }

    func uncompleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("status").set(to: TodoStatus.pending)])
            try Note
                .filter(Column("relatedTodoID") == todo.id)
                .deleteAll(db)
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.completeTodo(todo) }
        }
        try await refreshContents()
    }

    func abandonTodo(_ todo: Todo) async throws {
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("status").set(to: TodoStatus.abandoned)])
        }
        try await refreshContents()
    }

    func addTodo(title: String, shouldMigrate: Bool, groupName: String? = nil) async throws {
        guard let pageID = page?.id else { return }
        let nextOrder = (todos.map(\.sortOrder).max() ?? -1) + 1
        let today = Self.startOfToday
        try await db.dbQueue.write { db in
            var todo = Todo(
                id: nil,
                pageID: pageID,
                title: title,
                shouldMigrate: shouldMigrate,
                status: .pending,
                sortOrder: nextOrder,
                groupName: groupName,
                externalURL: nil,
                firstAddedDate: today
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

    func setStatus(_ status: TodoStatus, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldStatus = todo.status
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("status").set(to: status)])
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.setStatus(oldStatus, for: todo) }
        }
        try await refreshContents()
    }

    func deleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await db.dbQueue.write { db in
            try Todo.filter(Column("id") == todo.id).deleteAll(db)
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.restoreTodo(todo) }
        }
        try await refreshContents()
    }

    func setGroup(_ groupName: String?, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldGroupName = todo.groupName
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("groupName").set(to: groupName)])
        }
        undoManager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await store.setGroup(oldGroupName, for: todo) }
        }
        try await refreshContents()
    }

    private func restoreTodo(_ todo: Todo) async throws {
        guard let pageID = page?.id else { return }
        try await db.dbQueue.write { db in
            var restored = Todo(
                id: nil,
                pageID: pageID,
                title: todo.title,
                shouldMigrate: todo.shouldMigrate,
                status: todo.status,
                sortOrder: todo.sortOrder,
                groupName: todo.groupName,
                externalURL: todo.externalURL,
                firstAddedDate: todo.firstAddedDate
            )
            try restored.insert(db)
        }
        try await refreshContents()
    }

    // Re-orders todos within a single group by updating their sortOrder values.
    func moveTodos(in groupName: String?, from offsets: IndexSet, to destination: Int) async throws {
        var groupTodos = todos
            .filter { $0.groupName == groupName }
            .sorted { $0.sortOrder < $1.sortOrder }
        groupTodos.move(fromOffsets: offsets, toOffset: destination)
        try await db.dbQueue.write { db in
            for (index, todo) in groupTodos.enumerated() {
                try Todo
                    .filter(Column("id") == todo.id)
                    .updateAll(db, [Column("sortOrder").set(to: index)])
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
        guard let pageID = page?.id else {
            todos = []
            notes = []
            return
        }
        let (fetchedTodos, fetchedNotes) = try await db.dbQueue.read { db in
            let todos = try Todo
                .filter(Column("pageID") == pageID)
                .order(Column("sortOrder"))
                .fetchAll(db)
            let notes = try Note
                .filter(Column("pageID") == pageID)
                .order(Column("timestamp"))
                .fetchAll(db)
            return (todos, notes)
        }
        todos = fetchedTodos
        notes = fetchedNotes
    }

    private static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }
}
