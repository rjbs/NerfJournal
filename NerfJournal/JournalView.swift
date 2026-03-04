import AppKit
import SwiftUI

// The width of the timestamp column in the Activity section. Probed once at
// launch using the reference time 10:00, which is the widest two-digit hour
// in any locale and clock format ("10:00" in 24h, "10:00 AM" in 12h).
// -- claude, 2026-03-02
private let activityTimeColumnWidth: CGFloat = {
    var comps = DateComponents()
    comps.hour = 10
    comps.minute = 0
    let ref = Calendar.current.date(from: comps) ?? Date()
    let sample = ref.formatted(date: .omitted, time: .shortened)
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.preferredFont(forTextStyle: .caption1)]
    return ceil((sample as NSString).size(withAttributes: attrs).width) + 2
}()

// MARK: - JournalView

struct JournalView: View {
    @EnvironmentObject private var journalStore: JournalStore
    @EnvironmentObject private var pageStore: PageStore
    @EnvironmentObject private var bundleStore: BundleStore
    @EnvironmentObject private var categoryStore: CategoryStore

    @State private var calendarPopoverVisible = false

    var body: some View {
        pageDetail
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    Button {
                        calendarPopoverVisible.toggle()
                    } label: {
                        Image(systemName: "calendar")
                    }
                    .popover(isPresented: $calendarPopoverVisible) {
                        MonthCalendarView(
                            selectedDate: journalStore.selectedDate,
                            highlightedDates: journalStore.pageDates,
                            futureDates: Set(pageStore.futureTodos.map {
                                Calendar.current.startOfDay(for: $0.start)
                            }),
                            onSelect: { date in Task { try? await journalStore.selectDate(date) } }
                        )
                        .padding()
                    }
                }
            }
            .task {
                try? await journalStore.loadIndex()
                if let latest = journalStore.pageDates.max() {
                    try? await journalStore.selectDate(latest)
                }
                try? await pageStore.load()
                try? await bundleStore.load()
                try? await categoryStore.load()
            }
    }

    private var pageDetail: some View {
        Group {
            if journalStore.selectedDate == nil {
                Text("Select a date to view its journal page.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if journalStore.isSelectedPageLast {
                // Most recent page: mutable if pageStore has loaded it; noPageDetail fallback otherwise.
                if let page = pageStore.page {
                    JournalPageDetailView(
                        date: page.date,
                        todos: pageStore.todos,
                        notes: pageStore.notes,
                        readOnly: false
                    )
                } else {
                    noPageDetail
                }
            } else if journalStore.selectedPage != nil {
                JournalPageDetailView(
                    date: journalStore.selectedDate!,
                    todos: journalStore.selectedTodos,
                    notes: journalStore.selectedNotes,
                    readOnly: true
                )
            } else {
                noPageDetail
            }
        }
    }

    @ViewBuilder
    private var noPageDetail: some View {
        let selectedDate = journalStore.selectedDate!
        let isToday = Calendar.current.isDateInToday(selectedDate)
        let futureForDate = pageStore.futureTodos.filter {
            Calendar.current.isDate($0.start, inSameDayAs: selectedDate)
        }

        VStack(alignment: .leading, spacing: 0) {
            Text(selectedDate.formatted(date: .long, time: .omitted))
                .font(.title2).bold()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            if futureForDate.isEmpty {
                VStack(spacing: 16) {
                    Text(isToday ? "No journal page for today." : "No journal page for this date.")
                        .foregroundStyle(.secondary)
                    if isToday {
                        Button("Start Today") { startToday() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if isToday {
                    HStack(spacing: 12) {
                        Text("No journal page for today.")
                            .foregroundStyle(.secondary)
                        Button("Start Today") { startToday() }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    Divider()
                }
                FutureLogForDateView(date: selectedDate)
            }
        }
    }

    private func startToday() {
        Task {
            try? await pageStore.startToday()
            try? await categoryStore.load()
            try? await journalStore.loadIndex()
            let today = Calendar.current.startOfDay(for: Date())
            try? await journalStore.selectDate(today)
        }
    }
}

// MARK: - MonthCalendarView

struct MonthCalendarView: View {
    let selectedDate: Date?
    let highlightedDates: Set<Date>
    var futureDates: Set<Date> = []
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
                    hasFutureItems: futureDates.contains(calendar.startOfDay(for: date)),
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
    var hasFutureItems: Bool = false
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
                .overlay(alignment: .bottom) {
                    if hasFutureItems {
                        Circle()
                            .fill(isSelected ? Color.white.opacity(0.8) : Color.orange.opacity(0.8))
                            .frame(width: 4, height: 4)
                            .offset(y: 3)
                    }
                }
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

// MARK: - JournalPageDetailView

struct JournalPageDetailView: View {
    @EnvironmentObject private var pageStore: PageStore
    @EnvironmentObject private var bundleStore: BundleStore
    @EnvironmentObject private var categoryStore: CategoryStore
    @Environment(\.openWindow) private var openWindow

    let date: Date
    let todos: [Todo]
    let notes: [Note]
    var readOnly: Bool = true

    @State private var newEntryText = ""
    @State private var showAddField = false
    @State private var scrollToFieldRequest = 0
    @FocusState private var addFieldFocused: Bool
    @State private var selectedTodoIDs: Set<Int64> = []
    @State private var editingTodoID: Int64? = nil
    @State private var entryIsNote = false
    @State private var selectedCategoryID: Int64? = nil
    @State private var categoryPickerActive = false
    @State private var categoryPickerQuery = ""
    @State private var editingNoteID: Int64? = nil
    @State private var selectedNoteID: Int64? = nil

    @AppStorage("resolvedWithNotes") private var resolvedWithNotes = false

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(date.formatted(date: .long, time: .omitted))
                .font(.title2).bold()
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)

            Divider()

            ScrollViewReader { scrollProxy in
                List(selection: $selectedTodoIDs) {
                    // On past pages with resolvedWithNotes, the Activity section
                    // leads so you see "what happened" before the leftovers.
                    if resolvedWithNotes && readOnly && !activityItems.isEmpty {
                        activitySection
                    }

                    if todos.isEmpty && readOnly {
                        Text("No tasks recorded for this day.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(todoGroups(for: resolvedWithNotes ? openTodos : todos), id: \.id) { group in
                            Section {
                                ForEach(group.items) { todo in
                                    TodoRow(
                                        todo: todo,
                                        pageDate: date,
                                        readOnly: readOnly,
                                        isEditing: editingTodoID == todo.id,
                                        selectedIDs: selectedTodoIDs,
                                        onCommitEdit: { newTitle in
                                            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                                            editingTodoID = nil
                                            guard !trimmed.isEmpty else { return }
                                            Task { try? await pageStore.setTitle(trimmed, for: todo, undoManager: undoManager) }
                                        },
                                        onCancelEdit: { editingTodoID = nil }
                                    )
                                    .tag(todo.id!)
                                }
                            } header: {
                                CategoryLabel(category: group.category)
                            }
                        }
                        if !readOnly && showAddField {
                            Section {
                                HStack(spacing: 8) {
                                    Button {
                                        entryIsNote.toggle()
                                        if entryIsNote { selectedCategoryID = nil; categoryPickerActive = false }
                                        addFieldFocused = true
                                    } label: {
                                        Image(systemName: entryIsNote ? "bubble.left" : "circle")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                    }
                                    .buttonStyle(.plain)
                                    .help(entryIsNote ? "Switch to todo" : "Switch to note")

                                    TextField(entryIsNote ? "Add note\u{2026}" : "Add todo\u{2026}", text: $newEntryText)
                                        .focused($addFieldFocused)
                                        .onSubmit { submitEntry() }
                                        .onKeyPress(.escape) {
                                            if categoryPickerActive { cancelCategoryPicker(); return .handled }
                                            addFieldFocused = false
                                            return .handled
                                        }
                                        .onKeyPress("\t") { .handled }
                                        .onChange(of: newEntryText) { _, text in updateCategoryPicker(for: text) }

                                    if !entryIsNote, let catID = selectedCategoryID,
                                       let cat = categoryStore.categories.first(where: { $0.id == catID }) {
                                        HStack(spacing: 4) {
                                            Circle()
                                                .fill(cat.color.swatch)
                                                .frame(width: 8, height: 8)
                                            Text(cat.name)
                                                .font(.caption)
                                            Button { selectedCategoryID = nil } label: {
                                                Image(systemName: "xmark").font(.caption2)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 3)
                                        .background(
                                            Capsule()
                                                .fill(cat.color.swatch.opacity(0.15))
                                                .overlay(Capsule().stroke(cat.color.swatch.opacity(0.4), lineWidth: 1))
                                        )
                                        .foregroundStyle(cat.color.swatch)
                                    }
                                }
                                .id("addEntryField")

                                if !entryIsNote && categoryPickerActive && !filteredCategories.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(filteredCategories) { cat in
                                            Button { selectCategory(cat) } label: {
                                                HStack(spacing: 4) {
                                                    Circle()
                                                        .fill(cat.color.swatch)
                                                        .frame(width: 8, height: 8)
                                                    Text(cat.name).font(.caption)
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Capsule().fill(cat.color.swatch.opacity(0.15)))
                                                .foregroundStyle(cat.color.swatch)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(.leading, 24)
                                }
                            }
                        }
                    }

                    // On today's mutable page with resolvedWithNotes, the Activity
                    // section trails so open work stays front and centre.
                    if resolvedWithNotes && !readOnly && !activityItems.isEmpty {
                        activitySection
                    }

                    if !resolvedWithNotes && !textNotes.isEmpty {
                        Section("Notes") {
                            ForEach(textNotes) { note in
                                NoteRow(
                                    note: note,
                                    readOnly: readOnly,
                                    isEditing: editingNoteID == note.id,
                                    isSelected: selectedNoteID == note.id,
                                    onCommitEdit: { newText in
                                        let trimmed = newText.trimmingCharacters(in: .whitespaces)
                                        editingNoteID = nil
                                        guard !trimmed.isEmpty else { return }
                                        Task { try? await pageStore.setNoteText(trimmed, for: note, undoManager: undoManager) }
                                    },
                                    onCancelEdit: { editingNoteID = nil }
                                )
                                .onTapGesture {
                                    guard !readOnly else { return }
                                    selectedNoteID = note.id
                                    selectedTodoIDs = []
                                }
                            }
                        }
                    }
                }
                .onKeyPress(phases: .down) { keyPress in
                    if keyPress.key == .escape {
                        if !selectedTodoIDs.isEmpty { selectedTodoIDs = []; return .handled }
                        if selectedNoteID != nil { selectedNoteID = nil; return .handled }
                        return .ignored
                    }
                    // Notes are untagged and invisible to the List's built-in
                    // arrow navigation. When the selection is inside the Activity
                    // section, handle up/down manually using activityItems order.
                    // -- claude, 2026-03-02
                    if (keyPress.key == .upArrow || keyPress.key == .downArrow),
                       resolvedWithNotes, !activityItems.isEmpty,
                       editingTodoID == nil, editingNoteID == nil {
                        let delta = keyPress.key == .downArrow ? 1 : -1
                        let currentIndex: Int? = {
                            if let noteID = selectedNoteID {
                                return activityItems.firstIndex {
                                    guard case .note(let n) = $0 else { return false }
                                    return n.id == noteID
                                }
                            }
                            if selectedTodoIDs.count == 1, let id = selectedTodoIDs.first {
                                return activityItems.firstIndex {
                                    guard case .todo(let t) = $0 else { return false }
                                    return t.id == id
                                }
                            }
                            return nil
                        }()
                        if let idx = currentIndex {
                            let next = idx + delta
                            if next >= 0, next < activityItems.count {
                                switch activityItems[next] {
                                case .todo(let t): selectedTodoIDs = [t.id!]; selectedNoteID = nil
                                case .note(let n): selectedNoteID = n.id; selectedTodoIDs = []
                                }
                            }
                            return .handled
                        }
                    }
                    guard !readOnly, editingTodoID == nil, editingNoteID == nil, !addFieldFocused else { return .ignored }
                    guard keyPress.key == .return else { return .ignored }
                    if let noteID = selectedNoteID {
                        editingNoteID = noteID
                        return .handled
                    }
                    guard !selectedTodoIDs.isEmpty else { return .ignored }
                    if keyPress.modifiers.contains(.command) {
                        let selectedTodos = todos.filter { selectedTodoIDs.contains($0.id!) }
                        for todo in selectedTodos {
                            if todo.isPending {
                                Task { try? await pageStore.completeTodo(todo, undoManager: undoManager) }
                            } else if todo.isDone {
                                Task { try? await pageStore.uncompleteTodo(todo, undoManager: undoManager) }
                            }
                        }
                        if !selectedTodos.isEmpty { return .handled }
                    } else if selectedTodoIDs.count == 1, let id = selectedTodoIDs.first {
                        editingTodoID = id
                        return .handled
                    }
                    return .ignored
                }
                .onChange(of: selectedTodoIDs) { _, newIDs in
                    editingTodoID = nil
                    if !newIDs.isEmpty { selectedNoteID = nil }
                }
                .onChange(of: scrollToFieldRequest) { _, _ in
                    // Double-defer: first Task lets SwiftUI finish inserting the row
                    // (if showAddField just became true); second lets NSTableView
                    // complete its layout pass before scrollTo searches for the target.
                    // Triggered by a counter so it fires even when addFieldFocused or
                    // showAddField don't change (e.g. field already focused but scrolled
                    // out of view). -- claude, 2026-03-03
                    Task { @MainActor in
                        Task { @MainActor in
                            scrollProxy.scrollTo("addEntryField", anchor: .bottom)
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    resolvedWithNotes.toggle()
                } label: {
                    Image(systemName: resolvedWithNotes ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .help(resolvedWithNotes ? "Show resolved items in place" : "Show Activity section")
            }
            ToolbarItem {
                Menu {
                    ForEach(bundleStore.bundles) { bundle in
                        Button("Apply \u{201c}\(bundle.name)\u{201d}") {
                            Task { try? await pageStore.applyBundle(bundle, undoManager: undoManager) }
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
        .onChange(of: addFieldFocused) { _, focused in
            if !focused {
                showAddField = false
                newEntryText = ""
                selectedCategoryID = nil
                categoryPickerActive = false
                categoryPickerQuery = ""
            }
        }
        .onChange(of: selectedNoteID) { _, _ in editingNoteID = nil }
        .focusedValue(\.focusAddTodo, readOnly ? nil : Binding<Bool>(
            get: { addFieldFocused && !entryIsNote },
            set: { newValue in
                if newValue {
                    entryIsNote = false; showAddField = true; selectedTodoIDs = []
                    scrollToFieldRequest += 1
                }
                addFieldFocused = newValue
            }
        ))
        .focusedValue(\.focusAddNote, readOnly ? nil : Binding<Bool>(
            get: { addFieldFocused && entryIsNote },
            set: { newValue in
                if newValue {
                    entryIsNote = true; showAddField = true; selectedTodoIDs = []; selectedNoteID = nil
                    scrollToFieldRequest += 1
                }
                addFieldFocused = newValue
            }
        ))
    }

    // Todos whose ending falls on pageDate — shown in the Activity section when
    // resolvedWithNotes is on. Ordered by ending time, tiebroken by id.
    private var activityTodos: [Todo] {
        todos
            .filter { todo in
                guard let ending = todo.ending else { return false }
                return Calendar.current.isDate(ending.date, inSameDayAs: date)
            }
            .sorted {
                let d0 = $0.ending!.date, d1 = $1.ending!.date
                return d0 == d1 ? $0.id! < $1.id! : d0 < d1
            }
    }

    // Todos not in the Activity section: still open, or ended on a different day.
    private var openTodos: [Todo] {
        todos.filter { todo in
            guard let ending = todo.ending else { return true }
            return !Calendar.current.isDate(ending.date, inSameDayAs: date)
        }
    }

    // A single item in the Activity section: either a resolved todo or a note.
    private enum ActivityItem: Identifiable {
        case todo(Todo)
        case note(Note)

        var id: String {
            switch self {
            case .todo(let t): return "todo-\(t.id!)"
            case .note(let n): return "note-\(n.id!)"
            }
        }

        var timestamp: Date {
            switch self {
            case .todo(let t): return t.ending!.date
            case .note(let n): return n.timestamp
            }
        }
    }

    // Resolved todos and notes merged into a single chronological sequence.
    // On timestamp ties, todos sort before notes; within each kind, by id.
    private var activityItems: [ActivityItem] {
        let items = activityTodos.map(ActivityItem.todo) + textNotes.map(ActivityItem.note)
        return items.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            switch ($0, $1) {
            case (.todo(let a), .todo(let b)): return a.id! < b.id!
            case (.note(let a), .note(let b)): return a.id! < b.id!
            case (.todo, .note):               return true
            case (.note, .todo):               return false
            }
        }
    }

    private func todoGroups(for sourceTodos: [Todo]) -> [(id: String, category: Category?, items: [Todo])] {
        groupedByCategory(sourceTodos, categoryID: \.categoryID, categories: categoryStore.categories)
    }

    @ViewBuilder
    private var activitySection: some View {
        Section("Activity") {
            ForEach(activityItems) { item in
                switch item {
                case .todo(let todo):
                    TodoRow(
                        todo: todo,
                        pageDate: date,
                        readOnly: readOnly,
                        isEditing: editingTodoID == todo.id,
                        selectedIDs: selectedTodoIDs,
                        showCategoryDot: true,
                        activityTimestamp: todo.ending?.date,
                        onCommitEdit: { newTitle in
                            let trimmed = newTitle.trimmingCharacters(in: .whitespaces)
                            editingTodoID = nil
                            guard !trimmed.isEmpty else { return }
                            Task { try? await pageStore.setTitle(trimmed, for: todo, undoManager: undoManager) }
                        },
                        onCancelEdit: { editingTodoID = nil }
                    )
                    .tag(todo.id!)
                case .note(let note):
                    NoteRow(
                        note: note,
                        readOnly: readOnly,
                        isEditing: editingNoteID == note.id,
                        isSelected: selectedNoteID == note.id,
                        activityTimestamp: note.timestamp,
                        onCommitEdit: { newText in
                            let trimmed = newText.trimmingCharacters(in: .whitespaces)
                            editingNoteID = nil
                            guard !trimmed.isEmpty else { return }
                            Task { try? await pageStore.setNoteText(trimmed, for: note, undoManager: undoManager) }
                        },
                        onCancelEdit: { editingNoteID = nil }
                    )
                    .onTapGesture {
                        guard !readOnly else { return }
                        selectedNoteID = note.id
                        selectedTodoIDs = []
                    }
                }
            }
        }
    }

    private var textNotes: [Note] {
        notes.filter { $0.text != nil }
    }

    private func submitEntry() {
        if categoryPickerActive && !filteredCategories.isEmpty {
            selectCategory(filteredCategories[0])
            return
        }
        let text = newEntryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { addFieldFocused = false; return }
        if entryIsNote {
            Task {
                try? await pageStore.addNote(text: text)
                newEntryText = ""
                showAddField = true
                addFieldFocused = true
            }
        } else {
            let catID = selectedCategoryID
            Task {
                try? await pageStore.addTodo(title: text, shouldMigrate: true, categoryID: catID)
                newEntryText = ""
                selectedCategoryID = nil
                showAddField = true
                addFieldFocused = true
            }
        }
    }

    private func updateCategoryPicker(for text: String) {
        guard !entryIsNote else { categoryPickerActive = false; return }
        let words = text.components(separatedBy: " ")
        if let last = words.last, last.hasPrefix("#") {
            categoryPickerActive = true
            categoryPickerQuery = String(last.dropFirst())
        } else {
            categoryPickerActive = false
            categoryPickerQuery = ""
        }
    }

    private func selectCategory(_ category: Category) {
        var words = newEntryText.components(separatedBy: " ")
        if words.last?.hasPrefix("#") == true { words.removeLast() }
        newEntryText = words.joined(separator: " ")
        if !newEntryText.isEmpty { newEntryText += " " }
        selectedCategoryID = category.id
        categoryPickerActive = false
        categoryPickerQuery = ""
        addFieldFocused = true
    }

    private func cancelCategoryPicker() {
        var words = newEntryText.components(separatedBy: " ")
        if words.last?.hasPrefix("#") == true { words.removeLast() }
        newEntryText = words.joined(separator: " ")
        categoryPickerActive = false
        categoryPickerQuery = ""
    }

    private var filteredCategories: [Category] {
        guard categoryPickerActive else { return [] }
        let all = categoryStore.categories
        return categoryPickerQuery.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(categoryPickerQuery) }
    }
}

// MARK: - TodoRow

struct TodoRow: View {
    @EnvironmentObject private var store: PageStore
    @EnvironmentObject private var categoryStore: CategoryStore
    @Environment(\.undoManager) private var undoManager
    let todo: Todo
    var pageDate: Date = Calendar.current.startOfDay(for: Date())
    var readOnly: Bool = false
    var isEditing: Bool = false
    var selectedIDs: Set<Int64> = []
    var showCategoryDot: Bool = false
    var activityTimestamp: Date? = nil
    var onCommitEdit: (String) -> Void = { _ in }
    var onCancelEdit: () -> Void = {}

    @State private var editTitle = ""
    @FocusState private var titleFieldFocused: Bool

    @State private var showingSetURLAlert = false
    @State private var urlText = ""
    @State private var showingInvalidURLAlert = false
    @State private var showingAdjustEndingTime = false
    @State private var pendingEndingTime: Date = .now
    @State private var todoToSendToFuture: Todo? = nil
    @State private var sendToFutureDate: Date = Calendar.current.startOfDay(
        for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
    )

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
            if showCategoryDot {
                Circle()
                    .fill(categoryStore.categories.first(where: { $0.id == todo.categoryID })?.color.swatch ?? Color.gray)
                    .frame(width: 8, height: 8)
            } else if readOnly {
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

            if let ts = activityTimestamp {
                Text(ts.formatted(date: .omitted, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: activityTimeColumnWidth, alignment: .trailing)
                Text(activityIndicator)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 14, alignment: .center)
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

            Spacer()

            if let urlString = todo.externalURL,
               let url = URL(string: urlString) {
                Link(destination: url) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                }
                .help(urlString)
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if !readOnly {
                let affectedIDs: Set<Int64> = selectedIDs.contains(todo.id!) && selectedIDs.count > 1
                    ? selectedIDs : [todo.id!]
                let affectedTodos = store.todos.filter { affectedIDs.contains($0.id!) }

                if affectedTodos.count > 1 {
                    Menu("Mark") {
                        Button("Pending") {
                            Task { try? await store.bulkMarkPending(affectedTodos, undoManager: undoManager) }
                        }
                        Button("Complete") {
                            Task { try? await store.bulkComplete(affectedTodos, undoManager: undoManager) }
                        }
                        Button("Abandoned") {
                            Task { try? await store.bulkAbandon(affectedTodos) }
                        }
                    }

                    Menu("Set Category") {
                        Button("None") {
                            Task { try? await store.setBulkCategory(nil, forTodoIDs: affectedIDs, undoManager: undoManager) }
                        }
                        Divider()
                        ForEach(categoryStore.categories) { category in
                            Button(category.name) {
                                Task { try? await store.setBulkCategory(category.id, forTodoIDs: affectedIDs, undoManager: undoManager) }
                            }
                        }
                    }

                    Divider()

                    Button("Delete", role: .destructive) {
                        Task { try? await store.bulkDelete(affectedTodos, undoManager: undoManager) }
                    }
                } else {
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

                    Button("Set URL\u{2026}") {
                        urlText = todo.externalURL ?? ""
                        showingSetURLAlert = true
                    }

                    if let endingDate = todo.ending?.date {
                        Button("Adjust time\u{2026}") {
                            pendingEndingTime = endingDate
                            showingAdjustEndingTime = true
                        }
                    }

                    if todo.isPending {
                        Divider()
                        Button("Send to tomorrow") {
                            let tomorrow = Calendar.current.startOfDay(
                                for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                            )
                            Task { try? await store.sendToDate(affectedTodos, date: tomorrow, undoManager: undoManager) }
                        }
                        Button("Send to future\u{2026}") {
                            todoToSendToFuture = todo
                            sendToFutureDate = Calendar.current.startOfDay(
                                for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                            )
                        }
                    }

                    Divider()

                    Button("Delete", role: .destructive) {
                        Task { try? await store.deleteTodo(todo, undoManager: undoManager) }
                    }
                }
            }

            Divider()

            Button("Copy section as mrkdwn") {
                copyGroupAsMrkdwn()
            }
        }
        .alert("Set URL", isPresented: $showingSetURLAlert) {
            TextField("URL", text: $urlText)
            Button("Set") { commitURL() }
            Button("Cancel", role: .cancel) { urlText = "" }
        }
        .alert("Invalid URL", isPresented: $showingInvalidURLAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Please enter a valid URL (e.g. https://example.com) or clear the field to remove the URL.")
        }
        .sheet(isPresented: $showingAdjustEndingTime) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Adjust Ending Time")
                    .font(.headline)
                DatePicker(
                    "",
                    selection: $pendingEndingTime,
                    in: adjustEndingTimeDayRange,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                HStack {
                    Spacer()
                    Button("Cancel") { showingAdjustEndingTime = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Set") {
                        Task { try? await store.setEndingTime(pendingEndingTime, for: todo, undoManager: undoManager) }
                        showingAdjustEndingTime = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 220)
        }
        .sheet(item: $todoToSendToFuture) { futureTodo in
            VStack(spacing: 16) {
                Text("Send \u{201c}\(futureTodo.title)\u{201d} to\u{2026}")
                    .font(.headline)
                DatePicker(
                    "Date",
                    selection: $sendToFutureDate,
                    in: Calendar.current.startOfDay(
                        for: Calendar.current.date(byAdding: .day, value: 1, to: Date())!
                    )...,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                HStack {
                    Button("Cancel") { todoToSendToFuture = nil }
                    Button("Send") {
                        Task { try? await store.sendToDate([futureTodo], date: sendToFutureDate, undoManager: undoManager) }
                        todoToSendToFuture = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(minWidth: 300)
        }
    }

    private var adjustEndingTimeDayRange: ClosedRange<Date> {
        guard let endingDate = todo.ending?.date else { return Date()...Date() }
        let cal = Calendar.current
        let start = cal.startOfDay(for: endingDate)
        let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: endingDate)!
        return start...end
    }

    private func commitURL() {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Task { try? await store.setURL(nil, for: todo) }
        } else if URL(string: trimmed)?.scheme != nil {
            Task { try? await store.setURL(trimmed, for: todo) }
        } else {
            showingInvalidURLAlert = true
            return
        }
        urlText = ""
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
        if activityTimestamp != nil {
            // Activity log: abandoned is struck; done gets the ✔ indicator instead.
            switch rowState {
            case .abandonedToday, .migratedResolved(.abandoned, _): return true
            default: return false
            }
        } else {
            // Grouped view: both done and abandoned are struck through.
            switch rowState {
            case .doneToday, .abandonedToday,
                 .migratedResolved(.done, _), .migratedResolved(.abandoned, _): return true
            default: return false
            }
        }
    }

    // Fixed-width indicator shown in the activity log between the timestamp
    // and the title: ✔ (U+2714) for done, ✗ (U+2717) for abandoned, empty
    // otherwise.  Always occupies the same width so titles stay aligned.
    private var activityIndicator: String {
        guard activityTimestamp != nil else { return "" }
        switch rowState {
        case .doneToday, .migratedResolved(.done, _):            return "\u{2714}"
        case .abandonedToday, .migratedResolved(.abandoned, _):  return "\u{2717}"
        default: return ""
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
            let addedDay = cal.startOfDay(for: todo.start)
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

// MARK: - NoteRow

struct NoteRow: View {
    @EnvironmentObject private var store: PageStore
    @Environment(\.undoManager) private var undoManager

    let note: Note
    var readOnly: Bool = false
    var isEditing: Bool = false
    var isSelected: Bool = false
    var activityTimestamp: Date? = nil
    var onCommitEdit: (String) -> Void = { _ in }
    var onCancelEdit: () -> Void = {}

    @State private var editText = ""
    @FocusState private var editFieldFocused: Bool
    @State private var showingAdjustTime = false
    @State private var pendingTime: Date = .now

    // The closed range of times the note may be moved to: midnight…23:59:59
    // on whichever calendar day the note currently lives on.
    private var adjustTimeDayRange: ClosedRange<Date> {
        let cal = Calendar.current
        let start = cal.startOfDay(for: note.timestamp)
        let end = cal.date(bySettingHour: 23, minute: 59, second: 59, of: note.timestamp)!
        return start...end
    }

    var body: some View {
        Group {
            if let ts = activityTimestamp {
                // Activity layout: [pip spacer] [fixed-width time] [indicator slot] [text]
                HStack(spacing: 8) {
                    Color.clear.frame(width: 8, height: 8)
                    Text(ts.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: activityTimeColumnWidth, alignment: .trailing)
                    Color.clear.frame(width: 14)
                    noteTextContent
                    Spacer()
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    noteTextContent
                    Text(note.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .onChange(of: isEditing) { _, editing in
            if editing {
                editText = note.text ?? ""
                editFieldFocused = true
            }
        }
        .contextMenu {
            if !readOnly {
                Button("Adjust time\u{2026}") {
                    pendingTime = note.timestamp
                    showingAdjustTime = true
                }
                Button("Delete", role: .destructive) {
                    Task { try? await store.deleteNote(note, undoManager: undoManager) }
                }
            }
        }
        .sheet(isPresented: $showingAdjustTime) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Adjust Note Time")
                    .font(.headline)
                DatePicker(
                    "",
                    selection: $pendingTime,
                    in: adjustTimeDayRange,
                    displayedComponents: .hourAndMinute
                )
                .labelsHidden()
                HStack {
                    Spacer()
                    Button("Cancel") { showingAdjustTime = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Set") {
                        Task { try? await store.setNoteTimestamp(pendingTime, for: note, undoManager: undoManager) }
                        showingAdjustTime = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .frame(width: 220)
        }
    }

    @ViewBuilder
    private var noteTextContent: some View {
        if isEditing {
            TextField("", text: $editText)
                .focused($editFieldFocused)
                .onSubmit { onCommitEdit(editText) }
                .onKeyPress(.escape) { onCancelEdit(); return .handled }
        } else {
            Text(note.text!)
        }
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

// MARK: - FocusAddNote

struct FocusAddNoteKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var focusAddNote: Binding<Bool>? {
        get { self[FocusAddNoteKey.self] }
        set { self[FocusAddNoteKey.self] = newValue }
    }
}
