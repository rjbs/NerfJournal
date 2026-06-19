import SwiftUI
import GRDB

@MainActor
final class QuickNoteStore: ObservableObject {
    @Published var loaded = false
    @Published var isDone = false
    @Published var categories: [Category] = []

    func load() async {
        let cats = try? await AppDatabase.shared.dbQueue.read { db in
            try Category.order(Column("sortOrder")).fetchAll(db)
        }
        categories = cats ?? []
        loaded = true
    }

    // When `done` is true the todo is born already complete (an unplanned thing
    // that already happened): it starts and ends today, and `start`/`shouldMigrate`
    // are forced accordingly. Logging a done thing also ensures today's page
    // exists, so it's visible right away — pending todos need no page.
    // -- claude, 2026-06-18
    func addTodo(title: String, categoryID: Int64?, start: Date? = nil, done: Bool = false) async {
        let today = Calendar.current.startOfDay(for: Date())
        try? await AppDatabase.shared.dbQueue.write { db in
            if done, try JournalPage.filter(Column("date") == today).fetchOne(db) == nil {
                var page = JournalPage(id: nil, date: today)
                try page.insert(db)
            }
            var todo = Todo(
                id: nil,
                title: title,
                shouldMigrate: done ? false : true,
                start: done ? today : (start ?? today),
                ending: done ? TodoEnding(date: Date(), kind: .done) : nil,
                categoryID: categoryID,
                externalURL: nil
            )
            try todo.insert(db)
        }
        notify()
    }

    private func notify() {
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
            object: nil, deliverImmediately: true
        )
    }
}

struct QuickNoteView: View {
    var dismiss: () -> Void
    @ObservedObject var store: QuickNoteStore

    @State private var text = ""
    @State private var selectedCategoryID: Int64? = nil
    @State private var categoryPickerActive = false
    @State private var categoryPickerQuery = ""
    @State private var categoryHighlight = 0
    @State private var datePickerActive = false
    @State private var datePickerQuery = ""
    @State private var parsedStartDate: Date? = nil
    @State private var selectedStartDate: Date? = nil
    @FocusState private var focused: Bool

    var body: some View {
        // The UI must render fully on the first *synchronous* pass: the panel is
        // ordered front while NerfJournal is a background app, and SwiftUI won't
        // reliably drive a `.task` (the category load) until the app activates.
        // Gating the whole view on `store.loaded` left the panel showing empty
        // until the user Cmd-Tabbed over. The text field needs no DB; categories
        // simply populate the picker once the load lands. -- claude, 2026-06-18
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    store.isDone.toggle()
                    focused = true
                } label: {
                    Image(systemName: store.isDone ? "checkmark.circle" : "circle")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                .buttonStyle(.plain)
                .help(store.isDone ? "Switch to a pending todo" : "Switch to logging a done thing")

                TextField(store.isDone ? "Log a done thing\u{2026}" : "Add todo\u{2026}", text: $text)
                    .font(.system(size: 20))
                    .focused($focused)
                    .onSubmit { submit() }
                    .onKeyPress(.escape) {
                        if categoryPickerActive { cancelCategoryPicker(); return .handled }
                        if datePickerActive { cancelDatePicker(); return .handled }
                        dismiss()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        guard categoryPickerActive else { return .ignored }
                        moveHighlight(-1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        guard categoryPickerActive else { return .ignored }
                        moveHighlight(1)
                        return .handled
                    }
                    .onChange(of: text) { _, newText in
                        updateCategoryPicker(for: newText)
                        updateDatePicker(for: newText)
                    }
            }

            lowerRegion
                .padding(.leading, 28)
        }
        .padding()
        .frame(width: 500)
        .task { await store.load() }
        .onAppear { focused = true }
        .onChange(of: store.isDone) { _, isDone in
            // A done thing is always for today, so drop any chosen/typed start
            // date when switching into done mode. Category carries over.
            if isDone {
                selectedStartDate = nil
                datePickerActive = false
                datePickerQuery = ""
                parsedStartDate = nil
                var words = text.components(separatedBy: " ")
                words.removeAll { $0.hasPrefix("~") }
                text = words.joined(separator: " ")
            }
        }
    }

    // The region below the text field. By default it reports where the todo
    // will land (its start date, plus the category once chosen); while the user
    // is typing a `#` or `~` token it swaps to the matching completion UI.
    // -- claude, 2026-06-17
    @ViewBuilder
    private var lowerRegion: some View {
        if categoryPickerActive {
            categoryList
        } else if datePickerActive {
            datePickerRegion
        } else {
            statusRow
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            if !store.isDone { dateChip }
            if let catID = selectedCategoryID,
               let cat = store.categories.first(where: { $0.id == catID }) {
                categoryChip(cat)
            }
        }
    }

    private var dateChip: some View {
        let date = selectedStartDate ?? Calendar.current.startOfDay(for: Date())
        return HStack(spacing: 4) {
            Image(systemName: "calendar").font(.caption2)
            Text(formatDateBadge(date)).font(.caption)
            if selectedStartDate != nil {
                Button { selectedStartDate = nil } label: {
                    Image(systemName: "xmark").font(.caption2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(Color.accentColor.opacity(0.15))
                .overlay(Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 1))
        )
        .foregroundStyle(Color.accentColor)
    }

    private func categoryChip(_ cat: Category) -> some View {
        HStack(spacing: 4) {
            Circle().fill(cat.color.swatch).frame(width: 8, height: 8)
            Text(cat.name).font(.caption)
            Button { selectedCategoryID = nil } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(cat.color.swatch.opacity(0.15))
                .overlay(Capsule().stroke(cat.color.swatch.opacity(0.4), lineWidth: 1))
        )
        .foregroundStyle(cat.color.swatch)
    }

    @ViewBuilder
    private var categoryList: some View {
        if filteredCategories.isEmpty {
            Text("No matching category")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(filteredCategories.enumerated()), id: \.element.id) { index, cat in
                    Button { selectCategory(cat) } label: {
                        HStack(spacing: 8) {
                            Circle().fill(cat.color.swatch).frame(width: 10, height: 10)
                            Text(cat.name)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(index == clampedHighlight ? Color.accentColor.opacity(0.2) : .clear)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var datePickerRegion: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(parsedStartDate.map { formatDateBadge($0) } ?? "Unrecognized date")
                .font(.caption)
                .foregroundStyle(parsedStartDate != nil ? .primary : .secondary)
            DatePicker(
                "",
                selection: Binding(
                    get: { parsedStartDate ?? Calendar.current.startOfDay(for: Date()) },
                    set: { confirmDate($0) }
                ),
                in: Calendar.current.startOfDay(for: Date())...,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
        }
    }

    private var filteredCategories: [Category] {
        guard categoryPickerActive else { return [] }
        let all = store.categories
        return categoryPickerQuery.isEmpty
            ? all
            : all.filter { $0.name.localizedCaseInsensitiveContains(categoryPickerQuery) }
    }

    private var clampedHighlight: Int {
        guard !filteredCategories.isEmpty else { return 0 }
        return min(max(categoryHighlight, 0), filteredCategories.count - 1)
    }

    private func moveHighlight(_ delta: Int) {
        let count = filteredCategories.count
        guard count > 0 else { return }
        categoryHighlight = (clampedHighlight + delta + count) % count
    }

    private func submit() {
        if categoryPickerActive && !filteredCategories.isEmpty {
            selectCategory(filteredCategories[clampedHighlight])
            return
        }
        if datePickerActive {
            if let date = parsedStartDate { confirmDate(date) }
            return
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { dismiss(); return }
        let catID = selectedCategoryID
        let start = selectedStartDate
        let done = store.isDone
        Task { await store.addTodo(title: trimmed, categoryID: catID, start: start, done: done) }
        dismiss()
    }

    private func updateCategoryPicker(for text: String) {
        let words = text.components(separatedBy: " ")
        if let last = words.last, last.hasPrefix("#") {
            categoryPickerActive = true
            categoryPickerQuery = String(last.dropFirst())
            categoryHighlight = 0
        } else {
            categoryPickerActive = false
            categoryPickerQuery = ""
        }
    }

    private func selectCategory(_ category: Category) {
        var words = text.components(separatedBy: " ")
        if words.last?.hasPrefix("#") == true { words.removeLast() }
        text = words.joined(separator: " ")
        if !text.isEmpty { text += " " }
        selectedCategoryID = category.id
        categoryPickerActive = false
        categoryPickerQuery = ""
        focused = true
    }

    private func cancelCategoryPicker() {
        var words = text.components(separatedBy: " ")
        if words.last?.hasPrefix("#") == true { words.removeLast() }
        text = words.joined(separator: " ")
        categoryPickerActive = false
        categoryPickerQuery = ""
    }

    private func updateDatePicker(for text: String) {
        // A done thing is always for today, so the ~date picker is pending-only.
        guard !store.isDone else { datePickerActive = false; return }
        let words = text.components(separatedBy: " ")
        if let tilde = words.first(where: { $0.hasPrefix("~") }) {
            let query = String(tilde.dropFirst())
            datePickerActive = true
            datePickerQuery = query
            parsedStartDate = DateParser.parse(query)
        } else {
            datePickerActive = false
            datePickerQuery = ""
            parsedStartDate = nil
        }
    }

    private func confirmDate(_ date: Date) {
        selectedStartDate = Calendar.current.startOfDay(for: date)
        var words = text.components(separatedBy: " ")
        words.removeAll { $0.hasPrefix("~") }
        text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { text += " " }
        datePickerActive = false
        datePickerQuery = ""
        parsedStartDate = nil
        focused = true
    }

    private func cancelDatePicker() {
        var words = text.components(separatedBy: " ")
        words.removeAll { $0.hasPrefix("~") }
        text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        datePickerActive = false
        datePickerQuery = ""
        parsedStartDate = nil
    }

    private func formatDateBadge(_ date: Date) -> String {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let days = cal.dateComponents([.day], from: today, to: date).day ?? 0
        switch days {
        case 0:  return "Today"
        case 1:  return "Tomorrow"
        case 2...6:
            let fmt = DateFormatter()
            fmt.dateFormat = "EEEE"
            return fmt.string(from: date)
        default:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMM d"
            return fmt.string(from: date)
        }
    }
}
