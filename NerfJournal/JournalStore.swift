import Foundation
import GRDB

@MainActor
final class JournalStore: ObservableObject {
    private let db: AppDatabase

    @Published var pageDates: Set<Date> = []
    @Published var selectedDate: Date? = nil
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
        return Calendar.current.isDate(page.date, inSameDayAs: lastDate)
    }

    func loadIndex() async throws {
        let dates = try await db.dbQueue.read { db in
            try JournalPage.order(Column("date")).fetchAll(db).map(\.date)
        }
        pageDates = Set(dates)
    }

    func selectDate(_ date: Date) async throws {
        let cal = Calendar.current
        let start = cal.startOfDay(for: date)
        let nextDay = cal.date(byAdding: .day, value: 1, to: start)!

        // Match by calendar day, not by instant. Page and todo dates are day
        // anchors stored as instants at the writing zone's midnight, so a bare
        // equality/`<=` against the current zone's midnight silently misses once
        // you view the data from another time zone. A half-open [start, nextDay)
        // range keeps day matching correct for the common case of travelling east
        // of where the data was written. -- claude, 2026-07-24
        //
        // Fetch everything in one read so all published properties can be
        // updated synchronously below — SwiftUI then coalesces them into a
        // single view pass instead of animating through intermediate states.
        let (foundPage, allTodos) = try await db.dbQueue.read { db in
            let page = try JournalPage
                .filter(Column("date") >= start && Column("date") < nextDay)
                .fetchOne(db)
            guard page?.id != nil else {
                return (page, [Todo]())
            }
            let t = try Todo
                .filter(Column("start") < nextDay)
                .fetchAll(db)
            return (page, t)
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
    }
}
