---
title: Syllabus
nav_order: 2
---

# NerfJournal Swift/SwiftUI Learning Path

A self-guided curriculum for an experienced programmer — strong in Perl and
general programming concepts, fluent in event-driven programming and MVC —
learning Swift and SwiftUI using NerfJournal as the working example throughout.

## How This Works

Each unit lives in its own file in this directory. When you're ready to begin a
unit, ask Claude to generate the chapter. Each chapter follows this structure:

- **Introduction** — what the unit covers and why it matters now
- **Concepts** — explanation tied directly to how the concept appears in NerfJournal,
  with notes on what's surprising or tricky coming from general OOP / Perl background
- **Reading** — links to Apple docs, swift.org, WWDC sessions, and other resources
- **Code tour** — specific files and line ranges to read and understand
- **Exercises** — optional hands-on experiments; skip freely, but at least read them

Progress is tracked in `progress.md`.

---

## Units

### Unit 1 — Swift as a Language

The language before the framework. Value types vs. reference types (structs vs.
classes) is the single most important concept in the whole curriculum — SwiftUI
is built on it. Optionals replace null and force you to be explicit about
absence. Closures, trailing closure syntax, and captures show up everywhere.
Protocols are how Swift does polymorphism. Property wrappers (`@Something`) are
syntax sugar for a real language feature, not magic.

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
and what goes wrong with the obvious alternative.

**Files to look at:** `BundleDetailView.swift`, `JournalView.swift` (`@State` declarations)

---

### Unit 4 — Observable Objects and Stores

`ObservableObject`, `@Published`, and the three ways to attach one to a view
(`@StateObject`, `@ObservedObject`, `@EnvironmentObject`). How NerfJournal's
five stores (`PageStore`, `JournalStore`, `BundleStore`, `CategoryStore`,
`AppDatabase`) fit this model — who owns them, who reads them, how updates
propagate. Why `@MainActor` is needed when SQLite writes happen on background
threads. This is where MVC intuition maps most cleanly.

**Files to look at:** `PageStore.swift`, `NerfJournalApp.swift`, `JournalView.swift`

---

### Unit 5 — App Structure and Multiple Windows

The `App` protocol, `Scene`, and the difference between `Window` and
`WindowGroup`. Why NerfJournal uses `Window` (single instances, no "New
Window" in the File menu). `Commands`, `CommandMenu`, and `CommandGroup` for
menu customization. How the three windows — journal, bundle manager, future log
— are declared and why they each receive different environment objects.

**Files to look at:** `NerfJournalApp.swift`, `TodoCommands.swift`

---

### Unit 6 — Focus, Cross-Window Communication, and Notifications

`@FocusedValue`, `@FocusedSceneObject`, and `@FocusedObject`: how SwiftUI
exposes which window/view is currently active to menu commands that live outside
any particular view. Why this matters when you have multiple windows that each
have their own store instance. `NotificationCenter` for in-process events.
`DistributedNotificationCenter` for the CLI tool handshake across process
boundaries.

**Files to look at:** `TodoCommands.swift`, `PageStore.swift` (`init` observer),
`DatabaseExport.swift` (post-import notification)

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
`JournalPageDetailView.swift` (context menus)
