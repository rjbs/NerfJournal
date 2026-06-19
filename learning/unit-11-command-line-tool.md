---
title: "Unit 11: The Command-Line Tool — swift-argument-parser and a Standalone Executable"
nav_order: 110
---

# Unit 11: The Command-Line Tool — swift-argument-parser and a Standalone Executable

## Introduction

Every unit until now described one program: the SwiftUI app. This unit is about a
*second* one — `nerf`, the command-line tool in `cli/` — that ships in the same
repository, talks to the same SQLite file, and shares some of the same source code,
yet is built by a different toolchain and never appears in the Xcode project at all.

That second program is interesting for two reasons. First, it's your clearest look at
**Swift away from a UI framework**: no `App`, no scene, no run loop that someone else
owns. A CLI's `main` runs top to bottom and exits, which is the execution model you
already know from Perl and Rust, so the Swift-specific parts stand out in relief.
Second, it's built as a **Swift Package** — the dependency-and-build unit that
SwiftPM (the Swift Package Manager) understands — rather than an `.xcodeproj`, so this
is the unit where "how does Swift code get compiled and what is a dependency" finally
gets a direct answer instead of being hidden behind Xcode's UI.

The spine of the unit is [swift-argument-parser](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser),
Apple's official argument-parsing library. Its central idea is one a Rust reader will
recognize instantly: **a command's argument specification is not code you write, it's a
struct whose fields you declare.** The properties — annotated `@Argument`, `@Option`,
`@Flag` — *are* the parser. This is exactly clap's derive API in Rust
(`#[derive(Parser)]` with `#[arg(...)]` on fields), and the resemblance is not a
coincidence; both grew from the same realization that a CLI's surface is fundamentally
declarative. If you've used `App::Cmd` or `MooseX::Getopt` in Perl, the subcommand
shape will feel familiar too, though Swift leans harder on the type system than any
Perl option parser does.

A note to carry through: this unit deliberately revisits two threads from earlier. The
hand-written GRDB record encoding from Unit 7 reappears here — because the CLI
re-declares the app's model types rather than importing them, and you'll see *why*. And
the `DateParser` that closed Unit 10 turns out to be the same file, compiled into this
second target unchanged. The shared, framework-free module reused by two programs is
the payoff the previous unit set up.

---

## A second program, not a second window: the Swift Package

The app is an Xcode project: a `.xcodeproj` bundle, a `project.pbxproj` you've had to
hand-edit (the gotchas file remembers the pain), and a build driven by Xcode. The CLI
is something else entirely — a **Swift Package**, declared by a single manifest file:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nerf",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", branch: "master"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "nerf",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        )
    ]
)
```

A few things are worth naming here, because this is the first time the curriculum has
looked a package manifest in the eye.

**`Package.swift` is Swift, not config.** The manifest is a Swift program that builds up
a `Package` value; SwiftPM compiles and runs it to learn the package's shape. The
`// swift-tools-version:` comment on the very first line is not decoration — SwiftPM
reads it *before* compiling the rest, to decide which manifest API to expose. This is
unusual (a comment that's semantically load-bearing) and worth filing away. The types
you're constructing — `Package`, `.executableTarget`, `.product` — come from
[`PackageDescription`](https://developer.apple.com/documentation/packagedescription),
a library Apple ships with the toolchain specifically for manifests.

**A *target* is a module; a *product* is what a target depends on.** `nerf` is an
[executable target](https://www.swift.org/documentation/package-manager/) — a module
that compiles to a runnable binary because exactly one of its files carries the `@main`
entry point. The two `dependencies:` lines on the package name *external* packages by
URL; the two `.product(...)` lines inside the target say which library products *this*
target links against. The indirection (depend on a package, then on a product within
it) exists because one package can vend several products — GRDB is one product from the
`GRDB.swift` package, `ArgumentParser` is one product from `swift-argument-parser`.

**Version pinning differs per dependency, on purpose.** `from: "1.3.0"` means "1.3.0 up
to but not including 2.0.0" — SemVer-compatible, the same caret-range default `cargo`
uses for `argument-parser = "1.3.0"`. But GRDB is pinned to `branch: "master"`, a
moving target with no version guarantee. That's a deliberate (if slightly risky) choice
to track GRDB's tip, and the resolved commit is frozen in `Package.resolved` (the
analogue of `Cargo.lock` or `cpanfile.snapshot`) so a checkout still builds
reproducibly until someone runs `swift package update`.

You build and run this with `swift build` and `swift run nerf …` from inside `cli/`,
never through Xcode. The app and the CLI are two separate compilations that happen to
share a directory and a database file — and, as we'll see, a little source code.

---

## `@main` and the entry point: `Nerf.swift`

In the SwiftUI app, the entry point is the `@main struct NerfJournalApp: App` — but you
never wrote a `main()`; the `App` protocol supplied the run loop and you filled in
scenes. The CLI uses the same `@main` attribute for the opposite arrangement: it marks
the type whose static `main()` *is* the program, and that `main()` comes from
swift-argument-parser rather than from you.

The entire root command is ten lines:

```swift
import ArgumentParser

@main
struct Nerf: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nerf",
        abstract: "Interact with your NerfJournal database from the command line.",
        subcommands: [AddTodo.self, Did.self, Categories.self, TodoCommand.self, Done.self, Abandon.self]
    )
}
```

[`ParsableCommand`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/parsablecommand)
is the protocol that makes a struct a command. Conforming to it gets you a synthesized
static `main()` that parses `CommandLine.arguments`, constructs an instance of the
right command with its properties filled in, and calls that instance's `run()`. The
`@main` attribute points the OS-level entry at that synthesized `main()`.

`Nerf` itself has no arguments and no `run()` of its own — it's a pure dispatcher. Its
[`CommandConfiguration`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/commandconfiguration)
names the program (`nerf`), gives the one-line abstract that heads the `--help` output,
and lists the subcommands by metatype (`AddTodo.self` is "the type `AddTodo`," Swift's
spelling of a type-as-value, like Rust's turbofish-free `AddTodo::` used as a value or
Perl's bareword class name passed to a dispatcher). When the user runs `nerf add-todo
…`, the framework matches `add-todo` against each subcommand's own `commandName`,
constructs that subcommand, and runs it. Omitting a `run()` on a command that *has*
subcommands makes it auto-print help — which is exactly what you want for a bare `nerf`.

The shape here — one root that only routes, leaf commands that do the work — is the
same one `App::Cmd` gives a Perl tool and `clap`'s subcommand enum gives a Rust one.
What's Swift-specific is that each subcommand is its own *type*, registered by handing
the parent its metatype.

---

## The declarative parser: properties *are* the spec

This is the conceptual heart of the unit, so it's worth slowing down. Look at
`add-todo`, the richest command, with its body elided:

```swift
struct AddTodo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-todo",
        abstract: "Add a todo to today's NerfJournal page."
    )

    @Flag(name: .customLong("no-migrate"),
          help: "Mark the todo as non-migratable (default: migratable).")
    var noMigrate = false

    @Option(name: .long,
            help: "Assign to the named category, matched case-insensitively …")
    var category: String?

    @Flag(name: .long, help: "Fail without creating the todo if --category names an unknown category.")
    var strict = false

    @Option(name: .long, help: "Set an external URL on the todo.")
    var url: String?

    @Option(name: .long, help: "Start date for the todo …")
    var start: String?

    @OptionGroup var db: DatabaseOptions

    @Argument(help: "The todo title (all words are joined into one title).")
    var title: [String]

    func run() throws { /* … */ }
}
```

Read it as a *declaration of the command's surface*, not as setup code. Each property
wrapper says what kind of input the property receives, and the property's name and type
say the rest:

- [`@Argument`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/argument)
  is a positional operand — no `--name`, just a bare word on the command line. `title`
  is typed `[String]`, an array, which makes it **variadic**: every trailing positional
  word is collected into it. That's why `nerf add-todo buy milk and eggs` works and the
  `run()` body joins them back with `joined(separator: " ")` — the parser hands you the
  words, the command decides they're one title.
- [`@Option`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/option)
  is a named value: `--category Work`, `--url https://…`. Typed `String?`, an
  [optional](https://developer.apple.com/documentation/swift/optional), so absence is
  representable as `nil` — no flag, no value, and the command branches on that. The
  type *is* the requiredness rule: a non-optional `@Option` with no default would be
  mandatory; `String?` makes it elective.
- [`@Flag`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/flag)
  is a boolean switch — present or absent, no value. `var strict = false` becomes
  `--strict`, defaulting to off; passing `--strict` flips it true.

The `name:` argument controls the spelling. `.long` derives the flag from the property
name with the Swift-to-kebab convention you'd expect, so `var strict` → `--strict`. But
`noMigrate` would derive to `--no-migrate` only if the conversion handled the embedded
word boundary the way the author wanted, so it's pinned explicitly with
`.customLong("no-migrate")` — a small reminder that the derivation is a *default*, not a
law, and you override it when the public surface and the Swift name should differ.

The defining move, and the thing to actually internalize: **there is no parsing code
here.** No `if arg == "--category"`, no index juggling, no `Getopt::Long` spec string.
The struct's stored properties, with their wrappers, types, and defaults, are a
complete machine-readable description of the command, and the framework turns it into a
parser, a `--help` screen, and usage errors. A Rust reader has seen this exact trick:
it is clap's derive API, field for field —

```rust
#[derive(Parser)]
struct AddTodo {
    #[arg(long = "no-migrate")] no_migrate: bool,   // @Flag(name: .customLong("no-migrate"))
    #[arg(long)] category: Option<String>,          // @Option var category: String?
    title: Vec<String>,                              // @Argument var title: [String]
}
```

— down to optionality meaning "elective" and `Vec`/`[String]` meaning "variadic." Where
Swift uses property wrappers, Rust uses attribute macros; the philosophy is identical.
For Perl the closest cousin is `MooseX::Getopt`, where object attributes become options,
but Perl's version can't lean on the type to encode "required vs. optional vs. list" the
way both Swift and Rust do.

---

## Composition over inheritance: `@OptionGroup`

One line in `AddTodo` is different in kind from the others:

```swift
@OptionGroup var db: DatabaseOptions
```

Every subcommand needs to accept `--database PATH` (an override the tests rely on), and
nobody wants to re-declare that option six times. The reuse mechanism is *not*
inheritance — these are structs, and Swift structs don't inherit. It's **composition**:
`DatabaseOptions` is its own little parsable type, and
[`@OptionGroup`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/optiongroup)
splices its options into whichever command embeds it.

```swift
struct DatabaseOptions: ParsableArguments {
    @Option(name: .long, help: "Override the default database path (for testing).")
    var database: String?

    static func defaultPath() -> String { /* …/journal.sqlite */ }

    func open() throws -> DatabaseQueue {
        let path = database ?? Self.defaultPath()
        var config = Configuration()
        config.busyMode = .timeout(5)
        do {
            return try DatabaseQueue(path: path, configuration: config)
        } catch {
            throw CLIError("could not open database at \(path): \(error)")
        }
    }
}
```

Note the protocol:
[`ParsableArguments`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/parsablearguments),
not `ParsableCommand`. The distinction is exactly the one its name implies — a
`ParsableArguments` is a *bundle of parseable fields* with no `run()` and no
`commandName`; it can't be invoked on its own, only mixed into a command. A
`ParsableCommand` is that plus an entry point. `DatabaseOptions` is shared *parsing
surface*, not a shared command.

What makes this design more than DRY bookkeeping is that `DatabaseOptions` also carries
the *behavior* tied to those options: `defaultPath()` (the sandbox container path the
app writes to) and `open()` (which applies the option, sets a busy timeout so a write
contending with the running app waits rather than failing, and wraps any failure in a
friendly `CLIError`). The option and the code that consumes it travel together as one
reusable unit. clap models the same thing with `#[command(flatten)]` on a struct of
shared args; Perl role-based option sets (a `MooseX::Getopt` role consumed by several
commands) are the nearest analogue.

---

## Errors as control flow, exit codes as the result

A CLI's "return value" to the shell is its **exit code**, and its error channel is
stderr. swift-argument-parser maps Swift's error handling onto both, so the commands
never call `exit(1)` by hand — they just `throw`.

```swift
struct CLIError: Error, CustomStringConvertible {
    var description: String
    init(_ message: String) { description = message }
}
```

The contract is simple and worth stating precisely: if a command's `run()` throws, the
framework catches it, prints a message to stderr, and exits non-zero. Two error types
divide the labor:

- [`ValidationError`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/validationerror)
  is the framework's own type for "the user invoked me wrong." `add-todo` throws it for
  an empty title. The framework treats it specially — it prints the usage hint along
  with the message — because it means *bad arguments*, not *a failed operation*.
- `CLIError` is the tool's own runtime-failure type: "no journal page for today," "could
  not open database," "category not found." Its conformance to
  [`CustomStringConvertible`](https://developer.apple.com/documentation/swift/customstringconvertible)
  is the whole trick — the framework prints an error by reading its `description`, so a
  one-field struct whose `description` *is* the message produces clean output with no
  stack trace and no Swift type noise.

The split matters because the two categories deserve different treatment: a usage error
should remind you of the correct usage, an operational error should just tell you what
went wrong. This is the same instinct as Perl distinguishing a `Getopt::Long` failure
from a `die "no such file"`, or Rust distinguishing a clap parse error from an
`anyhow::Error` your command logic returns.

The most instructive error handling is in `done`/`abandon`, because it shows the *order*
of operations carrying a correctness guarantee — a theme straight out of Unit 8:

```swift
private func endTodo(id: Int64, kind: TodoEnding.Kind, db: DatabaseOptions) throws {
    let dbQueue = try db.open()
    let today = Calendar.current.startOfDay(for: Date())
    let now = Date()

    do {
        try dbQueue.write { database in
            guard var todo = try Todo.filter(Column("id") == id).fetchOne(database) else {
                throw CLIError("no todo with id \(id)")
            }
            if todo.start > today {
                throw CLIError("todo \(id) hasn't started yet (starts \(dayString(todo.start)))")
            }
            if let ending = todo.ending {
                throw CLIError("todo \(id) is already \(ending.kind == .done ? "done" : "abandoned")")
            }
            todo.ending = TodoEnding(date: now, kind: kind)
            try todo.update(database)
        }
    } catch let error as CLIError {
        throw error
    } catch {
        throw CLIError("could not update todo: \(error)")
    }
}
```

The fetch, all three validations, and the update happen *inside one*
[`write`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasequeue)
*transaction*. That's deliberate, and the comment in the source says why: a throw from
inside the closure rolls the transaction back, so a failed check leaves nothing changed;
and because the read-validate-write is atomic, a second writer (the app, or another
`nerf` invocation) can't slip a state change in between the fetch and the update. If the
validation ran *before* opening the transaction, two `nerf done` calls racing on the same
id could both pass the "still open" check and both write. Putting the guards inside the
transaction is what makes "you can't finish an already-finished todo" actually hold.

The `catch let error as CLIError { throw error }` clause is a small but careful touch: it
lets the precise domain messages propagate untouched, while the bare `catch` wraps any
*other* failure (a GRDB error, say) in a generic `CLIError`. Without the first clause,
the second would swallow "todo 7 is already done" and re-label it "could not update
todo." The author wanted the specific message to win.

---

## Two programs, one schema: deliberate duplication

Here's a decision that looks wrong until you see the constraint. The CLI re-declares the
model types — `JournalPage`, `Todo`, `TodoEnding`, `Category` — in its own
`Database.swift`, rather than importing them from the app. The app's `Models.swift` and
this file describe the *same SQLite tables* and must agree, yet neither imports the
other.

Why not share them? Because the app is not a library. It's an application target inside
an `.xcodeproj`; there is no compiled module the package could `import`, and SwiftPM and
Xcode don't share a build graph here. To share the *types*, the author would have to
extract them into a third package that both the app and the CLI depend on — real work,
and a structural commitment. The pragmatic call was to duplicate four small structs and
keep them in sync by hand, accepting the risk that a schema change touches two files.
(The memory of the v7 migration shows the maintenance cost is real but bounded.)

What's worth studying is *how faithfully* the re-declaration has to mirror the app, and
this is where Unit 7's thread resurfaces. Two of the four types can lean on Swift's
synthesis; one cannot:

```swift
struct Category: FetchableRecord, TableRecord, Decodable {
    var id: Int64?
    var name: String
    var color: String
    var sortOrder: Int
    static let databaseTableName = "category"
}
```

`Category` and `JournalPage` are plain `Decodable`, so GRDB's
[`FetchableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/fetchablerecord)
gets its row-decoding for free from the compiler-synthesized `Decodable` conformance.
`Todo` cannot, because of its `ending: TodoEnding?` column:

```swift
struct Todo: MutablePersistableRecord {
    // … stored properties …
    func encode(to container: inout PersistenceContainer) throws {
        container["id"]            = id
        container["title"]         = title
        container["shouldMigrate"] = shouldMigrate
        container["start"]         = start
        container["ending"]        = ending
        container["categoryID"]    = categoryID
        container["externalURL"]   = externalURL
    }
}

extension Todo: FetchableRecord {
    init(row: Row) {
        id = row["id"]; title = row["title"]; shouldMigrate = row["shouldMigrate"]
        start = row["start"]; ending = row["ending"]
        categoryID = row["categoryID"]; externalURL = row["externalURL"]
    }
}
```

`TodoEnding` is stored as a JSON string in one column, via a `DatabaseValueConvertible`
conformance (it encodes itself to a JSON string and back). That custom column type is
exactly what defeats the automatic `Codable`-to-GRDB path, so `Todo` hand-writes both
halves: `encode(to container:)` for the write side that
[`MutablePersistableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/mutablepersistablerecord)
requires, and `init(row:)` for the read side `FetchableRecord` requires. This is the
same "a non-`Codable` GRDB record must spell out its own encoding" lesson from Unit 7,
now seen from the CLI's side — and it explains why `Todo` is the *only* one of the four
types carrying manual code.

The happier half of the sharing story is `DateParser.swift`. It imports nothing but
`Foundation`, depends on no model and no UI, and is **the same file** as the app's
quick-entry parser, vendored into this target so `nerf add-todo --start tomorrow`
accepts the identical vocabulary as the in-app `~` field. A framework-free module
reused verbatim across two programs is the clean case the duplicated models are *not* —
and the contrast is the lesson. Shared logic with no framework entanglement travels for
free; shared logic welded to an app target gets copied. (The source notes the two
copies must be updated together — the honest cost of vendoring instead of packaging.)

---

## Output for both machines and humans

A good CLI serves two audiences — a person at a terminal and a script parsing its
output — and `nerf`'s read commands serve both from one code path with a `--json` switch.

```swift
@Flag(name: .long, help: "Emit a JSON array of {title, category, start, url} objects.")
var json = false
```

The human path renders color and links; the machine path renders JSON. Three details
reward a look:

**Explicit nulls in JSON.** `nerf todo --json` does *not* use the synthesized `Encodable`
for its entry struct. It hand-writes `encode(to:)` precisely so that a `nil` category or
URL serializes as an explicit `"category": null` rather than being *omitted* — because a
script consuming the output should see a stable set of keys, not keys that appear and
vanish per row. Swift's default `Encodable` would drop nils for an `Optional`; the manual
encoder calls `c.encode(category, …)` (not `encodeIfPresent`) to force the null through.
This is the second time in the CLI that hand-written `Codable` buys a *specific* wire
format — the first being `TodoEnding`'s database JSON.

**Hyperlinks via OSC 8.** When a todo has an `externalURL`, the human output wraps its
title in the terminal hyperlink escape sequence (`ESC ] 8 ; ; URL … ESC ] 8 ; ;`), so a
modern terminal shows a clickable title and an old one shows the bare text. It's a
graceful-degradation trick: emit the richer thing in a way that harmlessly falls back.

**Colors borrowed from SwiftUI.** `nerf categories` prints a colored `●` swatch, and the
`Palette` enum gets those colors by `import SwiftUI` and resolving the *same* `Color.blue`,
`Color.red`, … values the app draws with, then converting to a 24-bit ANSI escape. The
comment explains the point: rather than hand-copy hex values that could drift from the
app's, the CLI asks SwiftUI for the exact colors macOS renders. It's a surprising import
for a command-line tool — SwiftUI, in a program with no window — but it's used purely as
a color *database*, which is a tidy way to stay honest to the UI.

---

## How this maps to Rust, and to Perl

- **swift-argument-parser ≈ clap's derive API, almost exactly.** `@Argument`/`@Option`/
  `@Flag` are `#[arg(...)]` on struct fields; `Optional` means elective, an array/`Vec`
  means variadic, a default value sets the default, and the help text lives in the
  annotation. Both generate the parser, the `--help`, and usage errors from the struct
  alone. Subcommands: Swift registers child *types* in `CommandConfiguration.subcommands`;
  clap uses an enum of subcommand variants. The mental model transfers with almost no
  loss.
- **`@OptionGroup` ≈ clap's `#[command(flatten)]`.** Shared options as a composed struct,
  spliced into each command — not inheritance, which neither language's value types offer
  here anyway.
- **Throwing `run()` → exit code ≈ `fn main() -> Result<(), E>` in Rust.** Return/throw an
  error, the runtime prints it and sets a non-zero exit. `CLIError: CustomStringConvertible`
  is the role `impl Display for MyError` plays for `anyhow`-style reporting; `ValidationError`
  is clap's own parse-error type kept distinct from your domain errors.
- **The Swift Package ≈ a Cargo crate.** `Package.swift` is `Cargo.toml` (but written in
  Swift, not TOML); an executable target is a binary crate; `Package.resolved` is
  `Cargo.lock`; `from: "1.3.0"` is the caret range `"1.3.0"`; `swift build`/`swift run`
  are `cargo build`/`cargo run`.

For Perl the analogies are looser but real. A subcommand tool built on `App::Cmd` has the
same root-dispatches-to-leaves shape, and `MooseX::Getopt` turns object attributes into
options the way the property wrappers turn struct fields into them — but Perl encodes far
less in types, so "required," "optional," and "list" are spec strings or attribute traits
rather than the field's type itself. The exit-code-and-stderr contract is just Perl's
`die`/`exit`, done for you. And the deepest Perl parallel is the *packaging* instinct, not
the parsing one: `DateParser` shared by the app and the CLI is the same move as factoring
logic into a module that both a web app and a cron job `use` — and the duplicated model
structs are what happens when you *can't* cleanly `use` the original, and copy instead.

---

## Reading

- [swift-argument-parser documentation](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser)
  — the library's full reference; start with the landing page's overview
- [`ParsableCommand`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/parsablecommand)
  and [`ParsableArguments`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/parsablearguments)
  — command vs. shared-argument-bundle
- [`@Argument`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/argument),
  [`@Option`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/option),
  [`@Flag`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/flag),
  [`@OptionGroup`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/optiongroup)
  — the four wrappers this unit turns on
- [`CommandConfiguration`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/commandconfiguration)
  and [`ValidationError`](https://swiftpackageindex.com/apple/swift-argument-parser/documentation/argumentparser/validationerror)
- [Swift Package Manager](https://www.swift.org/documentation/package-manager/)
  and [`PackageDescription`](https://developer.apple.com/documentation/packagedescription)
  — the manifest API
- [`CustomStringConvertible`](https://developer.apple.com/documentation/swift/customstringconvertible)
  — the protocol that makes `CLIError` print cleanly
- GRDB:
  [`MutablePersistableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/mutablepersistablerecord),
  [`FetchableRecord`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/fetchablerecord),
  [`DatabaseQueue`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/databasequeue)
  — re-encountered from Unit 7

---

## Code Tour

### `cli/Package.swift`: the whole manifest

Twenty lines. Identify the tools-version comment, the two external `dependencies`, the
single `.executableTarget`, and how each target dependency names a `product` *within* a
package. Compare the two version rules (`from:` vs `branch:`) and decide which you'd be
nervous about.

### `cli/Sources/nerf/Nerf.swift`: the dispatcher

The `@main` root. Note it has no arguments and no `run()` — only a `CommandConfiguration`
listing six subcommand *types*. This is the entire routing layer.

### `cli/Sources/nerf/AddTodo.swift`: the declarative surface, then the logic

Read the property block (lines 11–33) as a *specification*: each wrapper, each type, each
default. Then read `run()` and watch the parsed values get used — `title.joined`, the
`start`-date branch, the today's-page guard, the duplicate check, the `write`. Notice
where parsing ends and the command's own logic begins.

### `cli/Sources/nerf/Database.swift`: the re-declared schema

The four model structs. Find the one (`Todo`) that hand-writes `encode(to:)` and
`init(row:)` and the three that don't, and connect the difference to `TodoEnding` being a
`DatabaseValueConvertible` JSON column. Then read `DatabaseOptions` (lines 103–122): the
`@Option`, the `defaultPath()`, and `open()` with its busy timeout.

### `cli/Sources/nerf/TodoHelpers.swift` and `EndTodo.swift`: shared logic and the atomic write

`TodoHelpers` holds the free functions `add-todo` and `did` share (`fetchTodayPage`,
`resolveCategory`, `findOpenDuplicate`) — note `resolveCategory`'s default-warns /
`--strict`-throws split. Then `endTodo` in `EndTodo.swift`: confirm the fetch, all three
guards, and the update sit inside one `write` block, and articulate the race that ordering
prevents.

### `cli/Sources/nerf/Todo.swift` and `Palette.swift`: two audiences

`TodoCommand.run()`'s split between the human (grouped, colored, OSC-8-linked) and `--json`
paths; the hand-written entry `encode(to:)` forcing explicit nulls; and `Palette`'s
`import SwiftUI` used purely to resolve the app's exact colors for an ANSI swatch.

### `cli/Sources/nerf/DateParser.swift`: the file you've already read

Identical to the app's `DateParser` from Unit 10. Confirm it imports only `Foundation`,
and that this is what makes it shareable by copy where the model structs are not.

---

## Exercises

**1.** `add-todo`'s `title` is `@Argument var title: [String]` and the body re-joins the
words. What would change for the user if it were a single `@Argument var title: String`
instead? Try both in your head against `nerf add-todo buy milk` — what does each require
the user to type, and which is friendlier for a shell?

**2.** `category` is `@Option var category: String?` (optional) while `strict` is
`@Flag var strict = false` (defaulted bool). Make `category` *required* and reason about
what the parser would then reject. Why is "optional" the right call for `--category` but
"defaulted false" the right call for `--strict`?

**3.** `DatabaseOptions` is a `ParsableArguments`, not a `ParsableCommand`. What stops you
from adding a `run()` to it and invoking `nerf database`? What is the protocol distinction
actually preventing, and why is that the design you want?

**4.** In `endTodo`, move the three validation guards to *before* `dbQueue.write { … }`
(fetch and check outside the transaction, then open a transaction only to update).
Construct the exact interleaving of two concurrent `nerf done 7` invocations that now
corrupts the invariant "a todo is ended at most once." Then explain why keeping the guards
inside the single `write` closes the race.

**5.** The CLI re-declares `Todo` instead of importing the app's. Suppose you extracted the
four model types into a shared Swift package both the app and the CLI depend on. List one
concrete benefit and one concrete cost, and decide whether four small structs justify it.
(The v7 migration in your memory is a data point.)

**6.** `Category` conforms to `Decodable` and gets `FetchableRecord` for free, but `Todo`
hand-writes `init(row:)`. Identify the single property responsible, and explain precisely
why a `DatabaseValueConvertible` column breaks the synthesized path the way a `Codable`
column wouldn't.

**7.** `nerf todo --json` hand-writes `encode(to:)` and uses `encode` (not `encodeIfPresent`)
for the optional `category` and `url`. Switch them to `encodeIfPresent` and describe how the
output changes for a todo with no category. Why does a script consuming this output prefer
the explicit `null`?

**8.** `Palette` does `import SwiftUI` in a program that never shows a window, purely to read
`Color.blue` and friends. Argue for and against this dependency: what does it buy over a
hand-written table of hex values, and what does it cost (build, conceptual, portability)?
Would you keep it?
