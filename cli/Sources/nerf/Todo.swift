import ArgumentParser
import Foundation
import GRDB

// The command is `TodoCommand`, not `Todo`, so it doesn't collide with the
// `Todo` model type it queries.
struct TodoCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "todo",
        abstract: "Print today's remaining todos, grouped by category."
    )

    @Flag(name: .long,
          help: "Emit a JSON array of {title, category, start, url} objects.")
    var json = false

    @OptionGroup var db: DatabaseOptions

    func run() throws {
        let dbQueue = try db.open()
        let today = Calendar.current.startOfDay(for: Date())

        // "Remaining" = still open (ending IS NULL); "today's" = start on or before
        // today, which keeps carried-forward work and excludes Future Log items.
        let todos: [Todo]
        let categories: [Category]
        do {
            (todos, categories) = try dbQueue.read { database in
                let todos = try Todo
                    .filter(Column("start") <= today && Column("ending") == nil)
                    .order(Column("id"))
                    .fetchAll(database)
                let categories = try Category.fetchAll(database)
                return (todos, categories)
            }
        } catch {
            throw CLIError("could not query todos: \(error)")
        }

        let groups = groupedByCategory(todos, categories: categories)

        if json {
            try printJSON(groups)
            return
        }

        guard !groups.isEmpty else {
            print("No remaining todos.")
            return
        }

        for (index, group) in groups.enumerated() {
            if index > 0 { print("") }
            let swatch = Palette.swatch(named: group.category?.color ?? "")
            print("\(swatch) \(group.category?.name ?? "Other")")
            for todo in group.items {
                print("  \(titleCell(todo))")
            }
        }
    }

    // Hyperlinks the title to its externalURL via OSC 8 when one is set; terminals
    // that don't understand the escape just show the bare title.
    private func titleCell(_ todo: Todo) -> String {
        guard let url = todo.externalURL, !url.isEmpty else { return todo.title }
        let esc = "\u{001B}"
        return "\(esc)]8;;\(url)\(esc)\\\(todo.title)\(esc)]8;;\(esc)\\"
    }

    private func printJSON(_ groups: [CategoryGroup]) throws {
        struct Entry: Encodable {
            var title: String
            var category: String?
            var start: Date
            var url: String?

            // Manual encode (not the synthesized one) so nil category/url emit
            // explicit JSON null rather than being omitted.
            enum CodingKeys: String, CodingKey { case title, category, start, url }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(title, forKey: .title)
                try c.encode(category, forKey: .category)
                try c.encode(start, forKey: .start)
                try c.encode(url, forKey: .url)
            }
        }

        let entries = groups.flatMap { group in
            group.items.map {
                Entry(title: $0.title,
                      category: group.category?.name,
                      start: $0.start,
                      url: $0.externalURL)
            }
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        print(String(data: data, encoding: .utf8)!)
    }
}

private typealias CategoryGroup = (id: String, category: Category?, items: [Todo])

// Groups todos by category, sorting named groups by sortOrder. Todos whose
// categoryID is nil or no longer matches a known category collect into an
// "Other" group appended at the end. Mirrors the app's groupedByCategory so the
// CLI lists work in the same order as the journal page view.
private func groupedByCategory(_ todos: [Todo], categories: [Category]) -> [CategoryGroup] {
    let grouped = Dictionary(grouping: todos, by: \.categoryID)
    var named: [CategoryGroup] = []
    var other: [Todo] = grouped[nil] ?? []
    for (catID, group) in grouped {
        guard let catID else { continue }
        if let cat = categories.first(where: { $0.id == catID }) {
            named.append((id: "\(catID)", category: cat, items: group))
        } else {
            other.append(contentsOf: group)
        }
    }
    named.sort { $0.category!.sortOrder < $1.category!.sortOrder }
    if !other.isEmpty {
        named.append((id: "other", category: nil, items: other.sorted { ($0.id ?? 0) < ($1.id ?? 0) }))
    }
    return named
}
