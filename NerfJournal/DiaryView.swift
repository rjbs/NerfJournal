import AppKit
import SwiftUI

// MARK: - DiaryView

struct DiaryView: View {
    @EnvironmentObject private var diaryStore: DiaryStore
    @EnvironmentObject private var journalStore: LocalJournalStore
    @EnvironmentObject private var bundleStore: BundleStore

    @State private var sidebarVisible = true

    var body: some View {
        Group {
            if sidebarVisible {
                HSplitView {
                    calendarSidebar
                    pageDetail
                }
            } else {
                pageDetail
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
            }
        }
        .task {
            try? await diaryStore.loadIndex()
            if let latest = diaryStore.pageDates.max() {
                try? await diaryStore.selectDate(latest)
            }
            try? await journalStore.load()
            try? await bundleStore.load()
        }
    }

    private var calendarSidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthCalendarView(
                selectedDate: diaryStore.selectedDate,
                highlightedDates: diaryStore.pageDates,
                onSelect: { date in Task { try? await diaryStore.selectDate(date) } }
            )
            .padding()
            Spacer()
        }
        .frame(minWidth: 210, idealWidth: 230, maxWidth: 260)
    }

    private var pageDetail: some View {
        Group {
            if diaryStore.selectedDate == nil {
                Text("Select a date to view its journal page.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if diaryStore.isSelectedPageLast {
                lastPageDetail
            } else if diaryStore.selectedPage == nil {
                noPageDetail
            } else {
                DiaryPageDetailView(
                    date: diaryStore.selectedDate!,
                    todos: diaryStore.selectedTodos,
                    notes: diaryStore.selectedNotes,
                    readOnly: true
                )
            }
        }
    }

    // The most recent diary page may be mutable if journalStore has it loaded.
    private var lastPageDetail: some View {
        Group {
            if journalStore.page == nil {
                startTodayPrompt
            } else {
                DiaryPageDetailView(
                    date: journalStore.page!.date,
                    todos: journalStore.todos,
                    notes: journalStore.notes,
                    readOnly: false
                )
            }
        }
    }

    private var noPageDetail: some View {
        VStack(spacing: 8) {
            Text(diaryStore.selectedDate!.formatted(date: .long, time: .omitted))
                .font(.title2).bold()
            Text("No journal page for this date.")
                .foregroundStyle(.secondary)
            if Calendar.current.isDateInToday(diaryStore.selectedDate!) {
                Button("Start Today") { startToday() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var startTodayPrompt: some View {
        VStack(spacing: 16) {
            Text("No journal page for today.")
                .foregroundStyle(.secondary)
            Button("Start Today") { startToday() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func startToday() {
        Task {
            try? await journalStore.startToday()
            try? await diaryStore.loadIndex()
            let today = Calendar.current.startOfDay(for: Date())
            try? await diaryStore.selectDate(today)
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
    @EnvironmentObject private var journalStore: LocalJournalStore
    @EnvironmentObject private var bundleStore: BundleStore
    @Environment(\.openWindow) private var openWindow

    let date: Date
    let todos: [Todo]
    let notes: [Note]
    var readOnly: Bool = true

    @State private var newTodoTitle = ""
    @FocusState private var addFieldFocused: Bool
    @State private var selectedTodoID: Int64? = nil
    @State private var editingTodoID: Int64? = nil

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(date: .long, time: .omitted))
                .font(.title2).bold()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            List(selection: $selectedTodoID) {
                if todos.isEmpty && readOnly {
                    Text("No tasks recorded for this day.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(todoGroups, id: \.name) { group in
                        Section(group.name ?? "Tasks") {
                            ForEach(group.todos) { todo in
                                TodoRow(
                                    todo: todo,
                                    pageDate: date,
                                    readOnly: readOnly,
                                    isEditing: editingTodoID == todo.id,
                                    onCommitEdit: { newTitle in
                                        let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                                        editingTodoID = nil
                                        guard !trimmed.isEmpty else { return }
                                        Task { try? await journalStore.setTitle(trimmed, for: todo, undoManager: undoManager) }
                                    },
                                    onCancelEdit: { editingTodoID = nil }
                                )
                                .tag(todo.id!)
                            }
                            .onMove(perform: readOnly ? nil : { offsets, destination in
                                Task {
                                    try? await journalStore.moveTodos(
                                        in: group.name,
                                        from: offsets,
                                        to: destination
                                    )
                                }
                            })
                        }
                    }
                    if !readOnly {
                        Section {
                            TextField("Add todo\u{2026}", text: $newTodoTitle)
                                .focused($addFieldFocused)
                                .onSubmit { submitNewTodo() }
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
            .onKeyPress(phases: .down) { keyPress in
                guard !readOnly, editingTodoID == nil, !addFieldFocused else { return .ignored }
                guard keyPress.key == .return else { return .ignored }
                guard let id = selectedTodoID else { return .ignored }
                if keyPress.modifiers.contains(.command) {
                    if let todo = todos.first(where: { $0.id == id }) {
                        switch todo.status {
                        case .pending:
                            Task { try? await journalStore.completeTodo(todo, undoManager: undoManager) }
                        case .done:
                            Task { try? await journalStore.uncompleteTodo(todo, undoManager: undoManager) }
                        default:
                            break
                        }
                    }
                } else {
                    editingTodoID = id
                }
                return .handled
            }
            .onChange(of: selectedTodoID) { _, _ in editingTodoID = nil }
        }
        .toolbar {
            if !readOnly {
                ToolbarItem {
                    Menu {
                        ForEach(bundleStore.bundles) { bundle in
                            Button("Apply \u{201c}\(bundle.name)\u{201d}") {
                                Task { try? await journalStore.applyBundle(bundle) }
                            }
                        }
                        Divider()
                        Button("Show Bundle Manager") {
                            openWindow(id: "bundle-manager")
                        }
                    } label: {
                        Image(systemName: "square.stack")
                    }
                }
            }
        }
        .focusedValue(\.focusAddTodo, Binding(
            get: { addFieldFocused },
            set: { addFieldFocused = $0 }
        ))
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

    private func submitNewTodo() {
        let title = newTodoTitle.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        Task {
            try? await journalStore.addTodo(title: title, shouldMigrate: true)
            newTodoTitle = ""
            addFieldFocused = true
        }
    }
}

// MARK: - TodoRow

struct TodoRow: View {
    @EnvironmentObject private var store: LocalJournalStore
    @Environment(\.undoManager) private var undoManager
    @State private var showingNewGroupAlert = false
    @State private var newGroupName = ""
    let todo: Todo
    var pageDate: Date = Calendar.current.startOfDay(for: Date())
    var readOnly: Bool = false
    var isEditing: Bool = false
    var onCommitEdit: (String) -> Void = { _ in }
    var onCancelEdit: () -> Void = {}

    @State private var editTitle = ""
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            if readOnly {
                statusIcon
            } else {
                Button {
                    Task {
                        if todo.status == .pending {
                            try? await store.completeTodo(todo, undoManager: undoManager)
                        } else if todo.status == .done {
                            try? await store.uncompleteTodo(todo, undoManager: undoManager)
                        }
                    }
                } label: {
                    statusIcon
                }
                .buttonStyle(.plain)
                .disabled(todo.status == .abandoned)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("", text: $editTitle)
                        .focused($titleFieldFocused)
                        .onSubmit { onCommitEdit(editTitle) }
                        .onKeyPress(.escape) { onCancelEdit(); return .handled }
                } else {
                    Text(todo.title)
                        .strikethrough(todo.status == .done || (readOnly && todo.status == .migrated))
                        .foregroundStyle(
                            (todo.status == .abandoned || (readOnly && todo.status == .migrated)) ? .secondary : .primary
                        )
                }
                if daysCarried > 0 {
                    Text("Carried over \u{b7} \(daysCarried) day\(daysCarried == 1 ? "" : "s") ago")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .onChange(of: isEditing) { _, editing in
                if editing {
                    editTitle = todo.title
                    titleFieldFocused = true
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !readOnly {
                Menu("Mark") {
                    if todo.status != .pending {
                        Button("Pending") {
                            Task { try? await store.setStatus(.pending, for: todo, undoManager: undoManager) }
                        }
                    }
                    if todo.status != .done {
                        Button("Complete") {
                            Task { try? await store.setStatus(.done, for: todo, undoManager: undoManager) }
                        }
                    }
                    if todo.status != .abandoned {
                        Button("Abandoned") {
                            Task { try? await store.setStatus(.abandoned, for: todo, undoManager: undoManager) }
                        }
                    }
                }

                Menu("Add to group") {
                    ForEach(existingGroups, id: \.self) { group in
                        Button(group) {
                            Task { try? await store.setGroup(group, for: todo, undoManager: undoManager) }
                        }
                    }
                    if !existingGroups.isEmpty {
                        Divider()
                    }
                    Button("New group\u{2026}") {
                        showingNewGroupAlert = true
                    }
                }

                Divider()

                Button("Delete", role: .destructive) {
                    Task { try? await store.deleteTodo(todo, undoManager: undoManager) }
                }
            }

            Divider()

            Button("Copy section as mrkdwn") {
                copyGroupAsMrkdwn()
            }
        }
        .alert("New Group Name", isPresented: $showingNewGroupAlert) {
            TextField("Group name", text: $newGroupName)
            Button("Add") {
                let name = newGroupName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    Task { try? await store.setGroup(name, for: todo, undoManager: undoManager) }
                }
                newGroupName = ""
            }
            Button("Cancel", role: .cancel) { newGroupName = "" }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        let shape = todo.shouldMigrate ? "circle" : "square"
        switch todo.status {
        case .done:
            Image(systemName: "checkmark.\(shape).fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)
        case .abandoned:
            Image(systemName: "xmark.\(shape).fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(white: 0.4))
        case .migrated:
            Image(systemName: "arrow.right.\(shape).fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.orange)
        default:
            Image(systemName: shape)
                .foregroundStyle(Color.secondary)
        }
    }

    private var daysCarried: Int {
        let added = Calendar.current.startOfDay(for: todo.firstAddedDate)
        return Calendar.current.dateComponents([.day], from: added, to: pageDate).day ?? 0
    }

    private var existingGroups: [String] {
        Array(Set(store.todos.compactMap(\.groupName))).sorted()
    }

    private func copyGroupAsMrkdwn() {
        let lines = store.todos
            .filter { $0.groupName == todo.groupName }
            .sorted { $0.sortOrder < $1.sortOrder }
            .compactMap { t -> String? in
                switch t.status {
                case .pending:  return "* \(t.title)"
                case .done:     return "* :white_check_mark: \(t.title)"
                case .abandoned, .migrated: return nil
                }
            }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n") + "\n", forType: .string)
    }
}

// MARK: - FocusAddTodo

struct FocusAddTodoKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var focusAddTodo: Binding<Bool>? {
        get { self[FocusAddTodoKey.self] }
        set { self[FocusAddTodoKey.self] = newValue }
    }
}
