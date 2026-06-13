import ArgumentParser
import GRDB

struct Categories: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "categories",
        abstract: "List the categories defined in NerfJournal, in display order."
    )

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

        guard !categories.isEmpty else {
            print("No categories defined.")
            return
        }

        let nameWidth = categories.map(\.name.count).max() ?? 0
        for category in categories {
            let name = category.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)
            print("\(name)  \(category.color)")
        }
    }
}
