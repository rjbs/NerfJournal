import Foundation
import GRDB

@MainActor
final class PageStore: ObservableObject {
    private let db: AppDatabase

    @Published var page: JournalPage?
    @Published var todos: [Todo] = []
    @Published var notes: [Note] = []
    @Published var futureTodos: [Todo] = []

    init(database: AppDatabase = .shared) {
        self.db = database
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in try? await self?.refreshContents() }
        }
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

        let newPage: JournalPage = try await db.dbQueue.write { db in
            var p = JournalPage(id: nil, date: today)
            try p.insert(db)

            // Set the ending to 23:59:59 on the last journal page before today —
            // the last day we considered doing these tasks. -- claude, 2026-03-02
            let lastPageDate = try JournalPage
                .filter(Column("date") < today)
                .order(Column("date").desc)
                .fetchOne(db)?
                .date ?? Calendar.current.date(byAdding: .day, value: -1, to: today)!
            let abandonmentDate = Calendar.current.date(
                bySettingHour: 23, minute: 59, second: 59, of: lastPageDate)!
            let abandonment = TodoEnding(date: abandonmentDate, kind: .abandoned)
            try Todo
                .filter(Column("start") < today)
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
        scheduleUndo(with: undoManager) { store in
            try await store.uncompleteTodo(todo, undoManager: undoManager)
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
        scheduleUndo(with: undoManager) { store in
            try await store.completeTodo(todo, undoManager: undoManager)
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
        scheduleUndo(with: undoManager) { store in
            if oldEnding?.kind == .done {
                try await store.completeTodo(todo, undoManager: undoManager)
            } else if oldEnding?.kind == .abandoned {
                try await store.abandonTodo(todo)
            }
        }
        try await refreshContents()
    }

    func bulkComplete(_ todos: [Todo], undoManager: UndoManager? = nil) async throws {
        let oldEndings: [(Int64, TodoEnding?)] = todos.map { ($0.id!, $0.ending) }
        let ending = TodoEnding(date: Date(), kind: .done)
        try await db.dbQueue.write { db in
            for todo in todos {
                try Todo
                    .filter(Column("id") == todo.id)
                    .updateAll(db, [Column("ending").set(to: ending)])
            }
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkEndings(oldEndings)
        }
        try await refreshContents()
    }

    func bulkMarkPending(_ todos: [Todo], undoManager: UndoManager? = nil) async throws {
        let oldEndings: [(Int64, TodoEnding?)] = todos.map { ($0.id!, $0.ending) }
        try await db.dbQueue.write { db in
            for todo in todos {
                try Todo
                    .filter(Column("id") == todo.id)
                    .updateAll(db, [Column("ending").set(to: nil as TodoEnding?)])
            }
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkEndings(oldEndings)
        }
        try await refreshContents()
    }

    func bulkAbandon(_ todos: [Todo]) async throws {
        let ending = TodoEnding(date: Date(), kind: .abandoned)
        try await db.dbQueue.write { db in
            for todo in todos {
                try Todo
                    .filter(Column("id") == todo.id)
                    .updateAll(db, [Column("ending").set(to: ending)])
            }
            return
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
                start: today,
                ending: nil,
                categoryID: categoryID,
                externalURL: nil
            )
            try todo.insert(db)
        }
        try await refreshContents()
    }

    func addNote(text: String) async throws {
        guard let pageID = page?.id else { return }
        try await db.dbQueue.write { db in
            var note = Note(id: nil, pageID: pageID, timestamp: Date(), text: text)
            try note.insert(db)
        }
        try await refreshContents()
    }

    func deleteNote(_ note: Note, undoManager: UndoManager? = nil) async throws {
        try await db.dbQueue.write { db in
            try Note.filter(Column("id") == note.id).deleteAll(db)
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreNote(note)
        }
        try await refreshContents()
    }

    private func restoreNote(_ note: Note) async throws {
        try await db.dbQueue.write { db in
            var restored = note
            try restored.insert(db)
        }
        try await refreshContents()
    }

    func setNoteTimestamp(_ date: Date, for note: Note, undoManager: UndoManager? = nil) async throws {
        let oldTimestamp = note.timestamp
        try await db.dbQueue.write { db in
            try Note
                .filter(Column("id") == note.id)
                .updateAll(db, [Column("timestamp").set(to: date)])
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.setNoteTimestamp(oldTimestamp, for: note, undoManager: undoManager)
        }
        try await refreshContents()
    }

    func setNoteText(_ text: String, for note: Note, undoManager: UndoManager? = nil) async throws {
        let oldText = note.text
        try await db.dbQueue.write { db in
            try Note
                .filter(Column("id") == note.id)
                .updateAll(db, [Column("text").set(to: text)])
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.setNoteText(oldText ?? "", for: note, undoManager: undoManager)
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
        scheduleUndo(with: undoManager) { store in
            try await store.setTitle(oldTitle, for: todo, undoManager: undoManager)
        }
        try await refreshContents()
    }

    func deleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await db.dbQueue.write { db in
            try Todo.filter(Column("id") == todo.id).deleteAll(db)
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreTodo(todo)
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
        scheduleUndo(with: undoManager) { store in
            try await store.setCategory(oldCategoryID, for: todo, undoManager: undoManager)
        }
        try await refreshContents()
    }

    // Set the category for a set of todos in one transaction with a single undo step.
    // Undo restores each todo's prior category individually; there is no redo. -- claude, 2026-03-02
    func setBulkCategory(_ categoryID: Int64?, forTodoIDs ids: Set<Int64>, undoManager: UndoManager? = nil) async throws {
        let oldCategories: [(Int64, Int64?)] = todos
            .filter { ids.contains($0.id!) }
            .map { ($0.id!, $0.categoryID) }
        try await db.dbQueue.write { db in
            for id in ids {
                try Todo
                    .filter(Column("id") == id)
                    .updateAll(db, [Column("categoryID").set(to: categoryID)])
            }
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkCategories(oldCategories)
        }
        try await refreshContents()
    }

    private func restoreBulkEndings(_ endings: [(Int64, TodoEnding?)]) async throws {
        try await db.dbQueue.write { db in
            for (id, ending) in endings {
                try Todo
                    .filter(Column("id") == id)
                    .updateAll(db, [Column("ending").set(to: ending)])
            }
            return
        }
        try await refreshContents()
    }

    // Update the start date for a set of todos in one transaction with a single
    // undo step. Restores each todo's prior start individually; no redo.
    // -- claude, 2026-03-03
    func sendToDate(_ todos: [Todo], date: Date, undoManager: UndoManager? = nil) async throws {
        let oldStarts: [(Int64, Date)] = todos.map { ($0.id!, $0.start) }
        let targetDate = Calendar.current.startOfDay(for: date)
        try await db.dbQueue.write { db in
            for todo in todos {
                try Todo
                    .filter(Column("id") == todo.id)
                    .updateAll(db, [Column("start").set(to: targetDate)])
            }
        }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkStartDates(oldStarts)
        }
        try await refreshContents()
    }

    private func restoreBulkStartDates(_ dates: [(Int64, Date)]) async throws {
        try await db.dbQueue.write { db in
            for (id, date) in dates {
                try Todo
                    .filter(Column("id") == id)
                    .updateAll(db, [Column("start").set(to: date)])
            }
        }
        try await refreshContents()
    }

    private func restoreBulkCategories(_ categories: [(Int64, Int64?)]) async throws {
        try await db.dbQueue.write { db in
            for (id, categoryID) in categories {
                try Todo
                    .filter(Column("id") == id)
                    .updateAll(db, [Column("categoryID").set(to: categoryID)])
            }
            return
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

    func setEndingTime(_ date: Date, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        guard let oldEnding = todo.ending else { return }
        let newEnding = TodoEnding(date: date, kind: oldEnding.kind)
        try await db.dbQueue.write { db in
            try Todo
                .filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: newEnding)])
            return
        }
        scheduleUndo(with: undoManager) { store in
            try await store.setEndingTime(oldEnding.date, for: todo, undoManager: undoManager)
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
                    start: today,
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
            futureTodos = []
            return
        }
        // Use the last page's date, not today, so that todos completed on the
        // last page day remain visible when you haven't started today yet.
        // -- claude, 2026-03-03
        let pageDate = Calendar.current.startOfDay(for: page!.date)
        let (allTodos, fetchedNotes, ft) = try await db.dbQueue.read { db in
            let t = try Todo
                .filter(Column("start") <= pageDate)
                .fetchAll(db)
            let n = try Note
                .filter(Column("pageID") == pageID)
                .order(Column("timestamp"))
                .fetchAll(db)
            let f = try Todo
                .filter(Column("start") > pageDate)
                .filter(Column("ending") == nil)
                .order(Column("start"), Column("id"))
                .fetchAll(db)
            return (t, n, f)
        }
        todos = allTodos
            .filter { todo in
                guard let ending = todo.ending else { return true }
                return ending.date >= pageDate
            }
            .sortedForDisplay()
        notes = fetchedNotes
        futureTodos = ft
    }

    // Registers an undo action, handling the Task { @MainActor } dance that
    // every async mutation needs. -- claude, 2026-03-02
    private func scheduleUndo(with manager: UndoManager?, _ action: @escaping (PageStore) async throws -> Void) {
        manager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await action(store) }
        }
    }

    private static var startOfToday: Date {
        Calendar.current.startOfDay(for: Date())
    }
}
