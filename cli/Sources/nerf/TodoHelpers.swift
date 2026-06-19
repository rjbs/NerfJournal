import ArgumentParser
import Foundation
import GRDB

// Shared helpers for the todo-creating subcommands (add-todo, did).

// A todo starting today must land on today's page, which the CLI never
// creates — so callers require it to exist. Returns the page if present.
func fetchTodayPage(_ dbQueue: DatabaseQueue, date: Date) throws -> JournalPage? {
    do {
        return try dbQueue.read { database in
            try JournalPage
                .filter(Column("date") == date)
                .fetchOne(database)
        }
    } catch {
        throw CLIError("could not query journal pages: \(error)")
    }
}

// Resolves a category name to an id (matched case-insensitively). By default a
// miss warns but continues, since a miscategorized todo is better than a lost
// one for scripted callers; under strict a miss instead throws so nothing is
// created and the program exits nonzero.
func resolveCategory(_ dbQueue: DatabaseQueue, name: String?, strict: Bool) throws -> Int64? {
    guard let name else { return nil }
    do {
        let categories = try dbQueue.read { db in try Category.fetchAll(db) }
        if let match = categories.first(where: { $0.name.lowercased() == name.lowercased() }) {
            return match.id
        }
        if strict {
            throw CLIError("category \"\(name)\" not found")
        }
        fputs("warning: category \"\(name)\" not found — adding todo without category\n", stderr)
    } catch let error as CLIError {
        throw error
    } catch {
        if strict {
            throw CLIError("could not query categories: \(error)")
        }
        fputs("warning: could not query categories: \(error) — adding todo without category\n", stderr)
    }
    return nil
}

struct DuplicateFound {
    var field: String
    var value: String
}

// Skip insertion if any open (ending IS NULL) todo already has this title or URL.
func findOpenDuplicate(_ dbQueue: DatabaseQueue, title: String, url: String?) throws -> DuplicateFound? {
    do {
        return try dbQueue.read { database -> DuplicateFound? in
            let titleDup = try Row.fetchOne(
                database,
                sql: "SELECT 1 FROM todo WHERE ending IS NULL AND title = ?",
                arguments: [title]
            )
            if titleDup != nil {
                return DuplicateFound(field: "title", value: title)
            }
            if let url = url {
                let urlDup = try Row.fetchOne(
                    database,
                    sql: "SELECT 1 FROM todo WHERE ending IS NULL AND externalURL = ?",
                    arguments: [url]
                )
                if urlDup != nil {
                    return DuplicateFound(field: "url", value: url)
                }
            }
            return nil
        }
    } catch {
        fputs("warning: could not check for duplicates: \(error)\n", stderr)
        return nil
    }
}
