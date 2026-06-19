import ArgumentParser

@main
struct Nerf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nerf",
        abstract: "Interact with your NerfJournal database from the command line.",
        subcommands: [AddTodo.self, Did.self, Categories.self, TodoCommand.self, Done.self, Abandon.self]
    )
}
