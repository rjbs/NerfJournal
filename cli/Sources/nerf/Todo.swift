import ArgumentParser
import Foundation
import GRDB
import NerfCore

// The command is `TodoCommand`, not `Todo`, so it doesn't collide with the
// `Todo` model type it queries.
struct TodoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "todo",
        abstract: "Print today's remaining todos, grouped by category."
    )

    @Flag(name: .long,
          help: "Emit a JSON array of {title, category, start, url} objects.")
    var json = false

    @OptionGroup var db: DatabaseOptions

    func run() async throws {
        let sync = try db.openSync()
        let today = CivilDate.today

        // "Remaining" = still open; "today's" = start on or before today, which
        // keeps carried-forward work and excludes Future Log items.
        let todos: [Todo]
        let categories: [Category]
        do {
            categories = try await sync.categories()
            todos = try await TaskReader(sync: sync).todos()
                .filter { $0.start <= today && $0.ending == nil }
        } catch {
            throw CLIError("could not read todos: \(error)")
        }

        let groups = groupedByCategory(todos, categoryID: \.categoryID, categories: categories)

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
            let swatch = Palette.swatch(named: group.category?.color.rawValue ?? "")
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

    private typealias CategoryGroup = (id: String, category: Category?, items: [Todo])

    private func printJSON(_ groups: [CategoryGroup]) throws {
        struct Entry: Encodable {
            var id: Int64?
            var title: String
            var category: String?
            var start: CivilDate
            var url: String?

            // Manual encode (not the synthesized one) so nil category/url emit
            // explicit JSON null rather than being omitted.
            enum CodingKeys: String, CodingKey { case id, title, category, start, url }
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(title, forKey: .title)
                try c.encode(category, forKey: .category)
                try c.encode(start, forKey: .start)
                try c.encode(url, forKey: .url)
            }
        }

        let entries = groups.flatMap { group in
            group.items.map {
                Entry(id: $0.id,
                      title: $0.title,
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
