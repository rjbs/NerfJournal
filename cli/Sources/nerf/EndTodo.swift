import ArgumentParser
import Foundation
import JinxStore
import NerfCore

struct Done: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "done",
        abstract: "Mark a started, still-open todo as done, ending it now."
    )

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The id of the todo to mark done.")
    var id: Int64

    func run() async throws { try await endTodo(id: id, kind: .done, db: db) }
}

struct Abandon: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "abandon",
        abstract: "Mark a started, still-open todo as abandoned, ending it now."
    )

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The id of the todo to abandon.")
    var id: Int64

    func run() async throws { try await endTodo(id: id, kind: .abandoned, db: db) }
}

// Ends a todo by setting its ending to (now, kind). The checks run against
// the todo as it stands in the local store; the id is the one `nerf todo
// --json` reports, which is the engine's local key. -- claude, 2026-10-28
private func endTodo(id: Int64, kind: TodoEnding.Kind, db: DatabaseOptions) async throws {
    let sync = try db.openSync()
    let today = CivilDate.today

    let todos: [Todo]
    do {
        todos = try await TaskReader(sync: sync).todos()
    } catch {
        throw CLIError("could not read todos: \(error)")
    }
    guard let todo = todos.first(where: { $0.id == id }) else {
        throw CLIError("no todo with id \(id)")
    }
    if todo.start > today {
        throw CLIError("todo \(id) hasn't started yet (starts \(todo.start.iso))")
    }
    if let ending = todo.ending {
        throw CLIError("todo \(id) is already \(ending.kind == .done ? "done" : "abandoned")")
    }

    let ending = TodoEnding(moment: .now(), kind: kind)
    do {
        try await TaskWriter(sync: sync).update(LocalKey(id)) { $0.ending = ending }
    } catch {
        throw CLIError("could not update todo: \(error)")
    }

    await pushAfterWrite(sync)
}
