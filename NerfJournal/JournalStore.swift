import Foundation
import GRDB

@MainActor
final class JournalStore: ObservableObject {
    private let db: AppDatabase

    @Published var pageDates: Set<CivilDate> = []
    @Published var selectedDate: CivilDate? = nil
    @Published var selectedPage: JournalPage? = nil
    @Published var selectedTodos: [Todo] = []

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
        return page.date == lastDate
    }

    func loadIndex() async throws {
        let dates = try await db.dbQueue.read { db in
            try JournalPage.order(Column("date")).fetchAll(db).map(\.date)
        }
        pageDates = Set(dates)
    }

    func selectDate(_ date: CivilDate) async throws {
        // Match by civil day: page and todo dates are civil dates, so exact and
        // `<=` comparisons work directly and are time-zone-proof. Fetch everything
        // in one read so all published properties can be updated synchronously
        // below — SwiftUI then coalesces them into a single view pass instead of
        // animating through intermediate states.
        let (foundPage, allTodos) = try await db.dbQueue.read { db in
            let page = try JournalPage
                .filter(Column("date") == date)
                .fetchOne(db)
            guard page?.id != nil else {
                return (page, [Todo]())
            }
            let t = try Todo
                .filter(Column("start") <= date)
                .fetchAll(db)
            return (page, t)
        }

        selectedDate = date
        selectedPage = foundPage
        // Visible on this day: added on or before it, and ended on or after it
        // (or not yet ended).
        selectedTodos = allTodos
            .filter { todo in
                guard let ending = todo.ending else { return true }
                return ending.day >= date
            }
            .sortedForDisplay()
    }
}
