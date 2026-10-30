---
title: Syllabus
nav_order: 2
---

# NerfJournal Swift/SwiftUI Learning Path

A self-guided curriculum for an experienced programmer — strong in Perl and
general programming concepts, fluent in event-driven programming and MVC —
learning Swift and SwiftUI using NerfJournal as the working example throughout.

## How This Works

Each unit lives in its own file in this directory and follows this structure:

- **Introduction** — what the unit covers and why it matters now
- **Concepts** — explanation tied directly to how the concept appears in NerfJournal,
  with notes on what's surprising or tricky coming from general OOP / Perl background
- **Reading** — links to Apple docs, swift.org, WWDC sessions, and other resources
- **Code tour** — specific files and line ranges to read and understand
- **Exercises** — optional hands-on experiments; skip freely, but at least read them

---

## Units

### Unit 1 — Swift as a Language

The language before the framework. Value types vs. reference types (structs vs.
classes) is the single most important concept in the whole curriculum — SwiftUI
is built on it. Optionals replace null and force you to be explicit about
absence. Closures, trailing closure syntax, and captures show up everywhere.
Protocols are how Swift does polymorphism. Property wrappers (`@Something`) are
syntax sugar for a real language feature, not magic. Modules are how Swift
organizes and isolates code — the basis for access control (`public`,
`internal`, `private`) and for understanding what `import` actually does.

**Files to look at:** `Todo.swift`, `TodoEnding.swift`, `Category.swift`

---

### Unit 2 — Views as Values

SwiftUI's fundamental model: a `View` is a protocol, views are structs (value
types), and the whole UI is a description that SwiftUI renders and re-renders as
data changes. Contrast with UIKit/AppKit's mutable object trees. Modifiers,
`ViewBuilder`, and basic layout (stacks, spacers, padding). View composition —
breaking UI into small reusable pieces.

**Files to look at:** `FutureLogRow.swift`, `DayCell.swift`, `MonthCalendarView.swift`

---

### Unit 3 — Local State and Binding

`@State` and `@Binding` — the smallest unit of reactivity. How data flows
*down* the view tree (parent owns state, passes it to children) and signals
flow *back up* (via bindings). The two-way binding model. Why the
`todoToSetURL`/`showingAlert` pattern in NerfJournal is the correct approach,
and what goes wrong with the obvious alternative. View identity and lifetime:
how SwiftUI decides what changed (structural identity vs. explicit identity via
`Identifiable` and `.id()`), and why this determines when `@State` is
preserved or reset.

**Files to look at:** `BundleDetailView.swift`, `JournalView.swift` (`@State` declarations)

---

### Unit 4 — Observable Objects and Stores

`ObservableObject`, `@Published`, and the three ways to attach one to a view
(`@StateObject`, `@ObservedObject`, `@EnvironmentObject`). How NerfJournal's
six stores (`PageStore`, `JournalStore`, `BundleStore`, `CategoryStore`,
`ExportGroupStore`, `AppDatabase`) fit this model — who owns them, who reads
them, how updates propagate. Why `@MainActor` is needed when SQLite writes
happen on background threads. This is where MVC intuition maps most cleanly.

**Files to look at:** `PageStore.swift`, `NerfJournalApp.swift`, `JournalView.swift`

---

### Unit 5 — App Structure and Multiple Windows

The `App` protocol, `Scene`, and the difference between `Window` and
`WindowGroup`. Why NerfJournal uses `Window` (single instances, no "New
Window" in the File menu). `Commands`, `CommandMenu`, and `CommandGroup` for
menu customization. How the four windows — journal, bundle manager, future log,
export groups — are declared and why they each receive different environment
objects.

**Files to look at:** `NerfJournalApp.swift`, `TodoCommands.swift`, `ExportGroupManagerView.swift`

---

### Unit 6 — Focus, Cross-Window Communication, and Notifications

`@FocusedValue`, `@FocusedSceneObject`, and `@FocusedObject`: how SwiftUI
exposes which window/view is currently active to menu commands that live outside
any particular view. Why this matters when you have multiple windows that each
have their own store instance. `NotificationCenter` for in-process events.
`DistributedNotificationCenter` for the CLI tool handshake across process
boundaries.

**Files to look at:** `TodoCommands.swift`, `PageStore.swift` (`init` observer),
`HTMLExport.swift` (post-import notification)

---

### Unit 7 — Persistence with GRDB

`DatabaseQueue`, migrations, and the `AppDatabase` wrapper. How Swift's
`Codable` protocol connects to GRDB's `MutablePersistableRecord` and
`FetchableRecord`. The v3 migration strategy (wipe and recreate vs. ALTER
TABLE) and why it was chosen. Encoding quirks when using GRDB inside a Swift
Package. How `PageStore.refreshContents` queries two sets of todos and what
that query looks like.

**Files to look at:** `AppDatabase.swift`, `PageStore.swift` (`refreshContents`),
`Todo.swift` (record conformance), `cli/Sources/`

---

### Unit 8 — Undo, Transactions, and Correctness

`UndoManager` and how SwiftUI/AppKit exposes it. NerfJournal's undo pattern:
capturing state before a mutation, registering the inverse. Why `restoreTodo`
re-inserts the *original* `Todo` value with its original `id` rather than
creating a new one. Stale closure captures in `ForEach` context menus and how
to work around them. Bulk operations and single-undo-step design.

**Files to look at:** `PageStore.swift` (all `undo`-related methods),
`JournalView.swift` (context menus)

---

### Unit 9 — Swift Concurrency

`async`/`await`, `Task`, and actors — the model that replaces callback closures
and dispatch queues. `@MainActor` as actor isolation, not just "run on the main
thread": why the stores are `@MainActor`-isolated and what the compiler enforces
as a result. `Sendable` and why a closure passed to a background queue can't
freely touch `@MainActor` state. `MainActor.assumeIsolated` as the escape hatch
for code that runs on the main queue but isn't statically known to (the
notification-observer closures in `PageStore.init` and `AppDelegate`). How this
maps to — and differs from — Rust's `Send`/`Sync` and Perl's lack of any of it.

**Files to look at:** `AppDatabase.swift`, `PageStore.swift` (`init` observers,
`async` mutations), `AppDelegate.swift` (`assumeIsolated`)

---

### Unit 10 — AppKit Interoperability and the Quick-Entry Panel

SwiftUI does not stand alone on macOS. The global quick-entry panel is pure
AppKit glue: an `NSApplicationDelegate` (bridged in via `@NSApplicationDelegateAdaptor`),
a Carbon global hot key, an `NSPanel` floating window, and an `NSHostingController`
that hosts a SwiftUI view inside it. The reverse direction too: observing a
hosting controller's `preferredContentSize` with a Combine `publisher(for:)` to
resize the panel as the SwiftUI content grows. Combine here is the same
machinery underlying `@Published`/`ObservableObject`, now used explicitly.
`DateParser` rounds out the unit as a self-contained, framework-free Swift
parsing module — the kind of plain-Swift code that the `~date` quick-entry
feature is built on.

**Files to look at:** `AppDelegate.swift`, `QuickNoteView.swift`, `DateParser.swift`

---

### Unit 11 — The Command-Line Tool: swift-argument-parser and a Standalone Executable

NerfJournal's `nerf` CLI is a second, independent program that talks to the same
SQLite file — a Swift Package executable (not part of the Xcode app project) with
its own `Package.swift` and dependencies. The unit covers
[swift-argument-parser](https://github.com/apple/swift-argument-parser): the
declarative, property-wrapper-driven model where a command is a `ParsableCommand`
struct whose `@Argument`, `@Option`, and `@Flag` properties *are* the parser, and
`@main` is the entry point. The subcommand set — `nerf add-todo`, `nerf
categories`, `nerf todo` (read-only listing, with a `--json` mode), and the
state-changing `nerf done` / `nerf abandon` — registered via
`CommandConfiguration`; shared flags mixed in with `@OptionGroup` (the
`DatabaseOptions` `--database` group); error handling through thrown errors
(`ValidationError`, a custom `CLIError`) that the framework turns into exit codes
and messages — including the domain errors `done`/`abandon` raise for an unknown,
unstarted, or already-ended todo. Plain-Swift supporting code shared with the app,
such as the `DateParser` behind `--start` (ISO 8601 dates and the `~`-style
relative grammar), shows how a module gets vendored into two targets at once. It also revisits, from the other side, why the CLI re-declares the
app's model types instead of importing them, and how a non-`Codable` GRDB record
must hand-write `encode(to:)` (the thread first pulled in Unit 7).

**Files to look at:** `cli/Package.swift`, `cli/Sources/nerf/Nerf.swift`,
`cli/Sources/nerf/AddTodo.swift`, `cli/Sources/nerf/Database.swift`

---

Units 1–11 were written against the local-SQLite NerfJournal, preserved as the
git tag `edition-local-sqlite`. The units below follow the move to a JMAP for
Tasks backend, and the coda maps what changed.

### Unit 12 — Swift 6: Strict Concurrency by Default

Unit 9's model, now enforced in full. What Swift 6 *language mode* means, as
distinct from the compiler version, and why turning it on was nearly free for
NerfJournal. Default actor isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION =
MainActor`) for the app, and why NerfCore and the CLI keep the nonisolated
default. The "approachable concurrency" feature flags. Real `actor` types at
last, `JournalSync` and Jinx's `SyncEngine`, including `nonisolated let` and
actor reentrancy. `AsyncStream` and `for await` as the replacement for
cross-process notifications, with `isolated deinit` ending the loop.
`Task.detached` for the engine's run loop.

**Files to look at:** `PageStore.swift`, `CategoryStore.swift`, `DayClock.swift`,
`AppDelegate.swift`, `NerfCore/Sources/NerfCore/JournalSync.swift`,
`cli/Package.swift`, Jinx's `SyncEngine.swift`

---

### Unit 13 — Packages, Modules, and Tests

What changes when your own code becomes a library. `NerfCore` as a Swift Package
with a library product, consumed by the app (through an Xcode local package
reference) and by the CLI (through a path dependency). The cost of `public`:
explicit initializers, explicit `Sendable`, and a name collision with
`ObjectiveC.Category`. Keeping UI out of the shared package with app-side
extensions. Testing with XCTest: async tests, table-style helpers that report
failures at the call site, a scripted fake server injected through a protocol,
and testing only through the public API.

**Files to look at:** `NerfCore/Package.swift`, `NerfCore/Sources/NerfCore/Models.swift`,
`NerfJournal/CategoryColor+Swatch.swift`, `NerfCore/Tests/NerfCoreTests/`

---

### Coda — The Software Moved On

What changed in NerfJournal after Unit 11, and why: the JMAP for Tasks backend,
the Jinx sync engine, and the TaskMaster server. Then a unit-by-unit map of the
earlier text that no longer describes the code, and what is true now.
