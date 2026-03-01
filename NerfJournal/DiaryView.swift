import AppKit
import SwiftUI

// MARK: - DiaryView

struct DiaryView: View {
    @EnvironmentObject private var diaryStore: DiaryStore
    @EnvironmentObject private var journalStore: LocalJournalStore
    @EnvironmentObject private var bundleStore: BundleStore
    @EnvironmentObject private var categoryStore: CategoryStore

    @AppStorage("sidebarVisible") private var sidebarVisible = true

    // Nominal sidebar width used when expanding the window on show.
    private let sidebarIdealWidth: CGFloat = 230
    // Minimum usable width for the diary content pane.
    private let contentMinWidth: CGFloat = 300

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
                    toggleSidebar()
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
            try? await categoryStore.load()
        }
    }

    private func toggleSidebar() {
        if sidebarVisible {
            sidebarVisible = false
        } else {
            // The clicked button's window is always the key window.
            if let window = NSApplication.shared.keyWindow,
               window.frame.width < sidebarIdealWidth + contentMinWidth {
                var frame = window.frame
                // Expand left, anchoring the right edge, clamped to the screen.
                let expansion = min(sidebarIdealWidth,
                                    frame.minX - (window.screen?.visibleFrame.minX ?? 0))
                frame.origin.x -= expansion
                frame.size.width += expansion
                window.setFrame(frame, display: true, animate: true)
            }
            sidebarVisible = true
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
            try? await categoryStore.load()
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
            Text("\(Calendar.current.component(.day, from: date))")
                .font(.system(.callout))
                .fontWeight(isToday ? .semibold : .regular)
                .frame(width: 26, height: 26)
                .background(Circle().fill(circleColor))
                .foregroundStyle(isSelected ? Color.white : .primary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1)
    }

    private var circleColor: Color {
        if isSelected  { return Color.accentColor }
        if hasEntry    { return Color.accentColor.opacity(0.15) }
        return Color.clear
    }
}

// MARK: - DiaryPageDetailView

struct DiaryPageDetailView: View {
    @EnvironmentObject private var journalStore: LocalJournalStore
    @EnvironmentObject private var bundleStore: BundleStore
    @EnvironmentObject private var categoryStore: CategoryStore
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
                    ForEach(todoGroups, id: \.id) { group in
                        Section {
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
                        } header: {
                            categoryHeader(group.category)
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
                        if todo.isPending {
                            Task { try? await journalStore.completeTodo(todo, undoManager: undoManager) }
                        } else if todo.isDone {
                            Task { try? await journalStore.uncompleteTodo(todo, undoManager: undoManager) }
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
            ToolbarItem {
                Menu {
                    ForEach(bundleStore.bundles) { bundle in
                        Button("Apply \u{201c}\(bundle.name)\u{201d}") {
                            Task { try? await journalStore.applyBundle(bundle) }
                        }
                        .disabled(readOnly)
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
        .focusedValue(\.focusAddTodo, Binding(
            get: { addFieldFocused },
            set: { addFieldFocused = $0 }
        ))
    }

    @ViewBuilder
    private func categoryHeader(_ category: Category?) -> some View {
        if let category {
            HStack(spacing: 6) {
                Circle()
                    .fill(category.color.swatch)
                    .frame(width: 8, height: 8)
                Text(category.name)
            }
        } else {
            Text("Other")
                .foregroundStyle(.secondary)
        }
    }

    // Groups todos by categoryID, sorted by category.sortOrder (uncategorized last).
    // Todos with a categoryID that no longer has a matching category are folded into
    // the "Other" bucket along with nil-categoryID todos.
    private var todoGroups: [(id: String, category: Category?, todos: [Todo])] {
        let grouped = Dictionary(grouping: todos, by: \.categoryID)
        var named: [(id: String, category: Category?, todos: [Todo])] = []
        var other: [Todo] = grouped[nil] ?? []

        for (categoryID, groupTodos) in grouped {
            guard let categoryID else { continue }
            if let cat = categoryStore.categories.first(where: { $0.id == categoryID }) {
                named.append((id: "\(categoryID)", category: cat, todos: groupTodos))
            } else {
                other.append(contentsOf: groupTodos)
            }
        }
        named.sort { $0.category!.sortOrder < $1.category!.sortOrder }
        if !other.isEmpty {
            named.append((id: "other", category: nil, todos: other))
        }
        return named
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
    @EnvironmentObject private var categoryStore: CategoryStore
    @Environment(\.undoManager) private var undoManager
    let todo: Todo
    var pageDate: Date = Calendar.current.startOfDay(for: Date())
    var readOnly: Bool = false
    var isEditing: Bool = false
    var onCommitEdit: (String) -> Void = { _ in }
    var onCancelEdit: () -> Void = {}

    @State private var editTitle = ""
    @FocusState private var titleFieldFocused: Bool

    // The display state of this todo relative to the page it is shown on.
    private enum RowState {
        case pending                                 // open on today's page
        case doneToday                               // completed on pageDate
        case abandonedToday                          // abandoned on pageDate
        case migratedOpen                            // still pending today (past page)
        case migratedResolved(TodoEnding.Kind, Date) // ended after pageDate (past page)
    }

    private var rowState: RowState {
        if let ending = todo.ending {
            if Calendar.current.isDate(ending.date, inSameDayAs: pageDate) {
                return ending.kind == .done ? .doneToday : .abandonedToday
            } else {
                return .migratedResolved(ending.kind, ending.date)
            }
        } else {
            return Calendar.current.isDateInToday(pageDate) ? .pending : .migratedOpen
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            if readOnly {
                statusIcon
            } else {
                Button {
                    Task {
                        if todo.isPending {
                            try? await store.completeTodo(todo, undoManager: undoManager)
                        } else if todo.isDone {
                            try? await store.uncompleteTodo(todo, undoManager: undoManager)
                        }
                    }
                } label: {
                    statusIcon
                }
                .buttonStyle(.plain)
                .disabled(todo.isAbandoned)
            }

            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("", text: $editTitle)
                        .focused($titleFieldFocused)
                        .onSubmit { onCommitEdit(editTitle) }
                        .onKeyPress(.escape) { onCancelEdit(); return .handled }
                } else {
                    Text(todo.title)
                        .strikethrough(shouldStrikethrough)
                        .foregroundStyle(isDimmed ? Color.secondary : Color.primary)
                }
                if let caption = captionText {
                    Text(caption)
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
                    if !todo.isPending {
                        Button("Pending") {
                            Task { try? await store.markPending(todo, undoManager: undoManager) }
                        }
                    }
                    if !todo.isDone {
                        Button("Complete") {
                            Task { try? await store.completeTodo(todo, undoManager: undoManager) }
                        }
                    }
                    if !todo.isAbandoned {
                        Button("Abandoned") {
                            Task { try? await store.abandonTodo(todo) }
                        }
                    }
                }

                Picker("Category", selection: Binding(
                    get: { todo.categoryID },
                    set: { newID in
                        Task { try? await store.setCategory(newID, for: todo, undoManager: undoManager) }
                    }
                )) {
                    Text("None").tag(nil as Int64?)
                    ForEach(categoryStore.categories) { category in
                        Text(category.name).tag(category.id as Int64?)
                    }
                }
                .pickerStyle(.inline)

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
    }

    @ViewBuilder
    private var statusIcon: some View {
        let shape = todo.shouldMigrate ? "circle" : "square"
        switch rowState {
        case .doneToday:
            Image(systemName: "checkmark.\(shape).fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.green)
        case .abandonedToday:
            Image(systemName: "xmark.\(shape).fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color(white: 0.4))
        case .migratedOpen, .migratedResolved:
            // On this past page the task was still open, regardless of how it
            // eventually resolved; the arrow conveys "carried forward".
            Image(systemName: "arrow.right.\(shape).fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.orange)
        case .pending:
            Image(systemName: shape)
                .foregroundStyle(Color.secondary)
        }
    }

    private var shouldStrikethrough: Bool {
        switch rowState {
        case .doneToday, .migratedResolved(.done, _): return true
        default: return false
        }
    }

    private var isDimmed: Bool {
        switch rowState {
        case .abandonedToday, .migratedResolved(.abandoned, _), .migratedOpen: return true
        default: return false
        }
    }

    private var captionText: String? {
        let cal = Calendar.current
        func daysCarried() -> Int {
            let addedDay = cal.startOfDay(for: todo.added)
            let pageDay  = cal.startOfDay(for: pageDate)
            return cal.dateComponents([.day], from: addedDay, to: pageDay).day ?? 0
        }
        switch rowState {
        case .pending, .doneToday:
            let days = daysCarried()
            return days > 0 ? "Carried over \u{b7} \(days) day\(days == 1 ? "" : "s") ago" : nil
        case .migratedOpen:
            return "Still open"
        case .migratedResolved(let kind, let date):
            let pageDay  = cal.startOfDay(for: pageDate)
            let endedDay = cal.startOfDay(for: date)
            let days = cal.dateComponents([.day], from: pageDay, to: endedDay).day ?? 0
            let action = kind == .done ? "Done" : "Abandoned"
            return "\(action) \(days) day\(days == 1 ? "" : "s") later"
        default:
            return nil
        }
    }

    private func copyGroupAsMrkdwn() {
        let lines = store.todos
            .filter { $0.categoryID == todo.categoryID }
            .compactMap { t -> String? in
                if t.isPending { return "* \(t.title)" }
                if t.isDone    { return "* :white_check_mark: \(t.title)" }
                return nil
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
