import SwiftUI

// MARK: - DiaryView

struct DiaryView: View {
    @EnvironmentObject private var store: DiaryStore

    var body: some View {
        HSplitView {
            calendarSidebar
            pageDetail
        }
        .task {
            try? await store.loadIndex()
        }
    }

    private var calendarSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthCalendarView(
                selectedDate: store.selectedDate,
                highlightedDates: store.pageDates,
                onSelect: { date in Task { try? await store.selectDate(date) } }
            )
            .padding()
            Spacer()
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
    }

    private var pageDetail: some View {
        Group {
            if store.selectedDate == nil {
                Text("Select a date to view its journal page.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.selectedPage == nil {
                VStack(spacing: 8) {
                    Text(store.selectedDate!.formatted(date: .long, time: .omitted))
                        .font(.title2).bold()
                    Text("No journal page for this date.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DiaryPageDetailView(
                    date: store.selectedDate!,
                    todos: store.selectedTodos,
                    notes: store.selectedNotes
                )
            }
        }
    }
}

// MARK: - MonthCalendarView

struct MonthCalendarView: View {
    let selectedDate: Date?
    let highlightedDates: Set<Date>
    let onSelect: (Date) -> Void

    @State private var displayMonth: Date = {
        let cal = Calendar.current
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }()

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let weekdayHeaders = ["Su", "Mo", "Tu", "We", "Th", "Fr", "Sa"]

    var body: some View {
        VStack(spacing: 10) {
            monthHeader
            weekdayHeader
            dayGrid
        }
    }

    private var monthHeader: some View {
        HStack {
            Button { shiftMonth(by: -1) } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(displayMonth.formatted(.dateTime.month(.wide).year()))
                .font(.headline)

            Spacer()

            Button { shiftMonth(by: 1) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(weekdayHeaders[i])
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 2)
            }
        }
    }

    private var dayGrid: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(0..<leadingBlanks, id: \.self) { _ in
                Color.clear.frame(height: 34)
            }
            ForEach(daysInMonth, id: \.self) { date in
                DayCell(
                    date: date,
                    isSelected: isSameDay(date, selectedDate),
                    hasEntry: hasEntry(date),
                    isToday: calendar.isDateInToday(date),
                    onTap: { onSelect(date) }
                )
            }
        }
    }

    // Number of blank cells before the first day of the month, assuming
    // a Sunday-first grid layout (weekday 1=Sun .. 7=Sat).
    private var leadingBlanks: Int {
        guard let firstDay = calendar.dateInterval(of: .month, for: displayMonth)?.start else {
            return 0
        }
        return calendar.component(.weekday, from: firstDay) - 1
    }

    private var daysInMonth: [Date] {
        guard let interval = calendar.dateInterval(of: .month, for: displayMonth) else { return [] }
        let count = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 0
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: interval.start) }
    }

    private func isSameDay(_ a: Date, _ b: Date?) -> Bool {
        guard let b else { return false }
        return calendar.isDate(a, inSameDayAs: b)
    }

    private func hasEntry(_ date: Date) -> Bool {
        highlightedDates.contains(calendar.startOfDay(for: date))
    }

    private func shiftMonth(by n: Int) {
        guard let next = calendar.date(byAdding: .month, value: n, to: displayMonth) else { return }
        displayMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: next))!
    }
}

// MARK: - DayCell

struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let hasEntry: Bool
    let isToday: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text("\(Calendar.current.component(.day, from: date))")
                    .font(.system(.callout))
                    .fontWeight(isToday ? .semibold : .regular)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(isSelected ? Color.accentColor : Color.clear))
                    .foregroundStyle(isSelected ? Color.white : .primary)

                Circle()
                    .fill(hasEntry && !isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 4, height: 4)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1)
    }
}

// MARK: - DiaryPageDetailView

struct DiaryPageDetailView: View {
    let date: Date
    let todos: [Todo]
    let notes: [Note]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(date: .long, time: .omitted))
                .font(.title2).bold()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            List {
                if todos.isEmpty {
                    Text("No tasks recorded for this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todoGroups, id: \.name) { group in
                        Section(group.name ?? "Tasks") {
                            ForEach(group.todos) { todo in
                                TodoRow(todo: todo, pageDate: date, readOnly: true)
                            }
                        }
                    }
                }

                if !textNotes.isEmpty {
                    Section("Notes") {
                        ForEach(textNotes) { note in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(note.text!)
                                Text(note.timestamp.formatted(date: .omitted, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
        }
    }

    private var todoGroups: [(name: String?, todos: [Todo])] {
        let grouped = Dictionary(grouping: todos, by: \.groupName)
        let named = grouped
            .compactMap { key, value in key.map { (name: $0, todos: value) } }
            .sorted { $0.name < $1.name }
        let ungrouped = grouped[nil].map { [(name: nil as String?, todos: $0)] } ?? []
        return named + ungrouped
    }

    private var textNotes: [Note] {
        notes.filter { $0.text != nil }
    }
}
