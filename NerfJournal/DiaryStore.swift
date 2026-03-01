import Foundation
import GRDB

@MainActor
final class DiaryStore: ObservableObject {
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
        selectedDate = start

        let page = try await db.dbQueue.read { db in
            try JournalPage
                .filter(Column("date") == start)
                .fetchOne(db)
        }
        selectedPage = page

        guard let pageID = page?.id else {
            selectedTodos = []
            selectedNotes = []
            return
        }

        let (todos, notes) = try await db.dbQueue.read { db in
            let t = try Todo
                .filter(Column("pageID") == pageID)
                .order(Column("sortOrder"))
                .fetchAll(db)
            let n = try Note
                .filter(Column("pageID") == pageID)
                .order(Column("timestamp"))
                .fetchAll(db)
            return (t, n)
        }
        selectedTodos = todos
        selectedNotes = notes
    }
}
