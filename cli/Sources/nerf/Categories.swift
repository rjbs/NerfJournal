import ArgumentParser
import Foundation
import GRDB

struct Categories: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "categories",
        abstract: "List the categories defined in NerfJournal, in display order."
    )

    @Flag(name: .long,
          help: "Emit a JSON array of {name, color} objects (color as a #aabbcc string).")
    var json = false

    @OptionGroup var db: DatabaseOptions

    func run() throws {
        let dbQueue = try db.open()

        let categories: [Category]
        do {
            categories = try dbQueue.read { database in
                try Category
                    .order(Column("sortOrder"))
                    .fetchAll(database)
            }
        } catch {
            throw CLIError("could not query categories: \(error)")
        }

        if json {
            try printJSON(categories)
            return
        }

        guard !categories.isEmpty else {
            print("No categories defined.")
            return
        }

        let nameWidth = categories.map(\.name.count).max() ?? 0
        for category in categories {
            let swatch = Palette.swatch(named: category.color)
            let name = category.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("\(swatch) \(name)  \(category.color)")
        }
    }

    private func printJSON(_ categories: [Category]) throws {
        struct Entry: Encodable {
            var name: String
            var color: String
        }
        let entries = categories.map {
            Entry(name: $0.name, color: Palette.hex(named: $0.color))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        print(String(data: data, encoding: .utf8)!)
    }
}
