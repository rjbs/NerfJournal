import Foundation
import GRDB
import JinxStore
import NerfCore

@MainActor
final class PageStore: ObservableObject {
    private let db: AppDatabase

    @Published var page: JournalPage?
    @Published var todos: [Todo] = []
    @Published var futureTodos: [Todo] = []

    // Todos live in the sync engine now; only pages stay in the journal's
    // own tables. Every mutation below is one engine write, and the change
    // stream below reloads the page afterward. -- claude, 2026-10-28
    private let reader: TaskReader
    private let writer: TaskWriter
    private var changeTask: Task<Void, Never>?

    init(database: AppDatabase = .shared) {
        self.db = database
        self.reader = TaskReader(sync: database.sync)
        self.writer = TaskWriter(sync: database.sync)
        // Every committed change to a Task, whether made here, synced in from
        // the server, or written by another process on this database (the
        // engine tails their journal), reloads the page. This replaces the
        // distributed notification the CLI used to post. -- claude, 2026-10-28
        changeTask = Task { [weak self] in
            let changes = await database.sync.engine.changes()
            for await change in changes {
                guard change.types[JournalSync.taskType.name] != nil else { continue }
                try? await self?.refreshContents()
            }
        }
    }

    isolated deinit {
        changeTask?.cancel()
    }

    // The engine's key for a todo the reader handed out.
    private func key(_ todo: Todo) -> LocalKey { LocalKey(todo.id!) }

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
    // abandoned as of their start day; migratable ones carry forward naturally.
    func startToday() async throws {
        let today = CivilDate.today

        let newPage: JournalPage = try await db.dbQueue.write { db in
            var p = JournalPage(id: nil, date: today)
            try p.insert(db)
            return p
        }
        try await writer.sweep(asOf: today)

        page = newPage
        try await refreshContents()
    }

    // The default ending for a resolution on the loaded page. On today's page the
    // moment is real (now); on any earlier page we only know the day, so it's a
    // day-only ending — the user can add a time via "Adjust time".
    // -- claude, 2026-07-25
    private func defaultEnding(kind: TodoEnding.Kind) -> TodoEnding {
        if let page, page.date != CivilDate.today {
            return TodoEnding(day: page.date, kind: kind)
        }
        return TodoEnding(moment: .now(), kind: kind)
    }

    func completeTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        let ending = defaultEnding(kind: .done)
        try await writer.update(key(todo)) { $0.ending = ending }
        scheduleUndo(with: undoManager) { store in
            try await store.uncompleteTodo(todo, undoManager: undoManager)
        }
        try await refreshContents()
    }

    func uncompleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await writer.update(key(todo)) { $0.ending = nil }
        scheduleUndo(with: undoManager) { store in
            try await store.completeTodo(todo, undoManager: undoManager)
        }
        try await refreshContents()
    }

    func abandonTodo(_ todo: Todo) async throws {
        let ending = defaultEnding(kind: .abandoned)
        try await writer.update(key(todo)) { $0.ending = ending }
        try await refreshContents()
    }

    // Mark any non-pending todo as pending. Used by the context menu.
    func markPending(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldEnding = todo.ending
        try await writer.update(key(todo)) { $0.ending = nil }
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
        let ending = defaultEnding(kind: .done)
        try await writer.updateMany(todos.map(key)) { $0.ending = ending }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkEndings(oldEndings)
        }
        try await refreshContents()
    }

    func bulkMarkPending(_ todos: [Todo], undoManager: UndoManager? = nil) async throws {
        let oldEndings: [(Int64, TodoEnding?)] = todos.map { ($0.id!, $0.ending) }
        try await writer.updateMany(todos.map(key)) { $0.ending = nil }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkEndings(oldEndings)
        }
        try await refreshContents()
    }

    // A destroyed Task cannot come back, so undo recreates the todos as new
    // Tasks: same content, new identity. -- claude, 2026-10-28
    func bulkDelete(_ todos: [Todo], undoManager: UndoManager? = nil) async throws {
        let snapshot = todos
        try await writer.destroy(todos.map(key))
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkTodos(snapshot)
        }
        try await refreshContents()
    }

    private func restoreBulkTodos(_ todos: [Todo]) async throws {
        _ = try await writer.createMany(todos)
        try await refreshContents()
    }

    func bulkAbandon(_ todos: [Todo]) async throws {
        let ending = defaultEnding(kind: .abandoned)
        try await writer.updateMany(todos.map(key)) { $0.ending = ending }
        try await refreshContents()
    }

    // When `done` is true the todo is born already complete (an unplanned thing
    // that's already happened): it starts today and ends now. `shouldMigrate` is
    // moot for a done todo, so it's forced false. -- claude, 2026-06-18
    func addTodo(title: String, shouldMigrate: Bool, categoryID: Int64? = nil, done: Bool = false) async throws {
        guard page != nil else { return }
        let today = CivilDate.today
        let todo = Todo(
            id: nil,
            title: title,
            shouldMigrate: done ? false : shouldMigrate,
            start: today,
            ending: done ? TodoEnding(moment: .now(), kind: .done) : nil,
            categoryID: categoryID,
            externalURL: nil
        )
        _ = try await writer.create(todo)
        try await refreshContents()
    }

    func setTitle(_ title: String, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldTitle = todo.title
        try await writer.update(key(todo)) { $0.title = title }
        scheduleUndo(with: undoManager) { store in
            try await store.setTitle(oldTitle, for: todo, undoManager: undoManager)
        }
        try await refreshContents()
    }

    func deleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
        try await writer.destroy([key(todo)])
        scheduleUndo(with: undoManager) { store in
            try await store.restoreTodo(todo)
        }
        try await refreshContents()
    }

    func setCategory(_ categoryID: Int64?, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        let oldCategoryID = todo.categoryID
        try await writer.update(key(todo)) { $0.categoryID = categoryID }
        scheduleUndo(with: undoManager) { store in
            try await store.setCategory(oldCategoryID, for: todo, undoManager: undoManager)
        }
        try await refreshContents()
    }

    // Set the category for a set of todos in one transaction with a single undo step.
    // Undo restores each todo's prior category individually; there is no redo. -- claude, 2026-03-02
    func setBulkCategory(_ categoryID: Int64?, forTodoIDs ids: Set<Int64>, undoManager: UndoManager? = nil) async throws {
        let oldCategories: [(Int64, Int64?)] = (todos + futureTodos)
            .filter { ids.contains($0.id!) }
            .map { ($0.id!, $0.categoryID) }
        try await writer.updateMany(ids.map(LocalKey.init)) { $0.categoryID = categoryID }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkCategories(oldCategories)
        }
        try await refreshContents()
    }

    private func restoreBulkEndings(_ endings: [(Int64, TodoEnding?)]) async throws {
        try await restoreEach(endings) { todo, ending in todo.ending = ending }
        try await refreshContents()
    }

    // Update the start date for a set of todos in one transaction with a single
    // undo step. Restores each todo's prior start individually; no redo.
    // -- claude, 2026-03-03
    func sendToDate(_ todos: [Todo], date: Date, undoManager: UndoManager? = nil) async throws {
        let oldStarts: [(Int64, CivilDate)] = todos.map { ($0.id!, $0.start) }
        let targetDate = CivilDate(instant: date, in: .current)
        try await writer.updateMany(todos.map(key)) { $0.start = targetDate }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkStartDates(oldStarts)
        }
        try await refreshContents()
    }

    private func restoreBulkStartDates(_ dates: [(Int64, CivilDate)]) async throws {
        try await restoreEach(dates) { todo, date in todo.start = date }
        try await refreshContents()
    }

    private func restoreBulkCategories(_ categories: [(Int64, Int64?)]) async throws {
        try await restoreEach(categories) { todo, categoryID in todo.categoryID = categoryID }
        try await refreshContents()
    }

    // Undo for a bulk change restores a per-todo prior value; each todo gets
    // its own transform, in one engine write.
    private func restoreEach<Value: Sendable>(
        _ values: [(Int64, Value)],
        _ apply: @Sendable @escaping (inout Todo, Value) -> Void
    ) async throws {
        let byKey = Dictionary(values.map { (LocalKey($0.0), $0.1) }, uniquingKeysWith: { _, last in last })
        try await writer.updateMany(Array(byKey.keys)) { todo in
            if let value = byKey[LocalKey(todo.id!)] { apply(&todo, value) }
        }
    }

    func setURL(_ url: String?, for todo: Todo) async throws {
        try await writer.update(key(todo)) { $0.externalURL = url }
        try await refreshContents()
    }

    // Give an ending a specific time-of-day on its existing day. The chosen
    // instant carries the current zone's offset, so it renders as the wall clock
    // the user picked. Undo restores the prior ending wholesale, since it may have
    // had no time at all. -- claude, 2026-07-25
    func setEndingTime(_ date: Date, for todo: Todo, undoManager: UndoManager? = nil) async throws {
        guard let oldEnding = todo.ending else { return }
        let moment = Moment(instant: date, offsetSeconds: TimeZone.current.secondsFromGMT(for: date))
        let newEnding = TodoEnding(day: oldEnding.day, time: moment, kind: oldEnding.kind)
        try await writer.update(key(todo)) { $0.ending = newEnding }
        scheduleUndo(with: undoManager) { store in
            try await store.restoreBulkEndings([(todo.id!, oldEnding)])
        }
        try await refreshContents()
    }

    private func restoreTodo(_ todo: Todo) async throws {
        guard page != nil else { return }
        _ = try await writer.create(todo)
        try await refreshContents()
    }

    func applyBundle(_ bundle: TaskBundle, undoManager: UndoManager? = nil) async throws {
        guard page != nil, let bundleID = bundle.id else { return }
        let bundleTodos = try await db.dbQueue.read { db in
            try BundleTodo
                .filter(Column("bundleID") == bundleID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }
        let today = CivilDate.today
        let created = try await writer.createMany(bundleTodos.map { bundleTodo in
            Todo(
                id: nil,
                title: bundleTodo.title,
                shouldMigrate: bundle.todosShouldMigrate,
                start: today,
                ending: nil,
                categoryID: bundleTodo.categoryID,
                externalURL: bundleTodo.externalURL
            )
        })
        scheduleUndo(with: undoManager) { store in
            try await store.writer.destroy(created)
            try await store.refreshContents()
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
        guard page != nil else {
            todos = []
            futureTodos = []
            return
        }
        // Use the last page's date, not today, so that todos completed on the
        // last page day remain visible when you haven't started today yet.
        // -- claude, 2026-03-03
        let pageDate = page!.date
        let allTodos = try await reader.todos()
        todos = allTodos
            .filter { todo in
                guard todo.start <= pageDate else { return false }
                guard let ending = todo.ending else { return true }
                return ending.day >= pageDate
            }
            .sortedForDisplay()
        futureTodos = allTodos
            .filter { $0.start > pageDate && $0.ending == nil }
            .sorted { ($0.start, $0.id ?? 0) < ($1.start, $1.id ?? 0) }
        NotificationCenter.default.post(name: .nerfJournalTodosDidChange, object: nil)
    }

    // Registers an undo action, handling the Task { @MainActor } dance that
    // every async mutation needs. -- claude, 2026-03-02
    private func scheduleUndo(with manager: UndoManager?, _ action: @escaping (PageStore) async throws -> Void) {
        manager?.registerUndo(withTarget: self) { store in
            Task { @MainActor in try? await action(store) }
        }
    }
}
