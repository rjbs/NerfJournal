import Foundation
import GRDB

@MainActor
final class JournalStore: ObservableObject {
    private let db: AppDatabase

    @Published var pageDates: Set<Date> = []
    @Published var selectedDate: Date? = nil
    @Published var selectedPage: JournalPage? = nil
    @Published var selectedTodos: [Todo] = []
    @Published var selectedNotes: [Note] = []

    init(database: AppDatabase = .shared) {
        self.db = database
        NotificationCenter.default.addObserver(
            forName: .nerfJournalDatabaseDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await self.loadIndex()
                self.selectedDate = nil
                self.selectedPage = nil
                self.selectedTodos = []
                self.selectedNotes = []
            }
        }
        NotificationCenter.default.addObserver(
            forName: .nerfJournalTodosDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let date = self.selectedDate else { return }
                try? await self.selectDate(date)
            }
        }
    }

    var isSelectedPageLast: Bool {
        guard let page = selectedPage, let lastDate = pageDates.max() else { return false }
        return Calendar.current.startOfDay(for: page.date) == lastDate
    }

    func loadIndex() async throws {
        let dates = try await db.dbQueue.read { db in
            try JournalPage.order(Column("date")).fetchAll(db).map(\.date)
        }
        pageDates = Set(dates)
    }

    func selectDate(_ date: Date) async throws {
        let start = Calendar.current.startOfDay(for: date)

        // Fetch everything in one read so all published properties can be
        // updated synchronously below — SwiftUI then coalesces them into a
        // single view pass instead of animating through intermediate states.
        let (foundPage, allTodos, notes) = try await db.dbQueue.read { db in
            let page = try JournalPage
                .filter(Column("date") == start)
                .fetchOne(db)
            guard let pageID = page?.id else {
                return (page, [Todo](), [Note]())
            }
            let t = try Todo
                .filter(Column("start") <= start)
                .fetchAll(db)
            let n = try Note
                .filter(Column("pageID") == pageID)
                .order(Column("timestamp"))
                .fetchAll(db)
            return (page, t, n)
        }

        selectedDate = start
        selectedPage = foundPage
        // Visible on this day: added on or before it, and ended on or after it
        // (or not yet ended).
        selectedTodos = allTodos
            .filter { todo in
                guard let ending = todo.ending else { return true }
                return ending.date >= start
            }
            .sortedForDisplay()
        selectedNotes = notes
    }
}
