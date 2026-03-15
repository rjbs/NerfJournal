---
title: "Unit 5: App Structure and Multiple Windows"
nav_order: 50
---

# Unit 5: App Structure and Multiple Windows

## Introduction

Units 2–4 covered views, state, and stores — the pieces that make up an
individual window's UI. This unit zooms out to the level of the application
itself: how Swift declares the entry point, how SwiftUI describes windows and
menus, and how NerfJournal's four windows are declared, sized, and handed
different sets of stores.

The App/Scene model is declarative, just like views. The whole application is
described as a value; SwiftUI handles the platform details.

---

## The `App` Protocol and `@main`

Every SwiftUI application is a type that conforms to the
[`App`](https://developer.apple.com/documentation/swiftui/app) protocol. The
protocol requires one thing:

```swift
protocol App {
    associatedtype Body: Scene
    @SceneBuilder var body: Self.Body { get }
}
```

`body` returns a `Scene` — or a composition of scenes — rather than a `View`.
The `@SceneBuilder` result builder works the same way as `@ViewBuilder`: you
list scene declarations and it composes them into a single value.

The `@main` attribute marks the type as the application's entry point. Swift
generates a `main()` function that creates the type and starts the run loop.
This replaces the classic `main.swift` or `NSApplicationMain` call — it's all
synthesized from the attribute.

```swift
@main
struct NerfJournalApp: App {
    var body: some Scene {
        Window("Journal", id: "journal") { JournalView() }
    }
}
```

The Rust parallel: `@main` is like `fn main()`, but declarative — you describe
what you want, and Swift generates the actual entry point.

---

## Scene Types: `Window` and `WindowGroup`

SwiftUI offers several scene types; the two you'll see on macOS are
[`Window`](https://developer.apple.com/documentation/swiftui/window) and
[`WindowGroup`](https://developer.apple.com/documentation/swiftui/windowgroup).

**`WindowGroup`** is for applications that support multiple instances of the
same window. It automatically adds a "New Window" item to the File menu. This
is appropriate for document-based apps — each window edits a different
document. Most introductory SwiftUI tutorials use `WindowGroup` because it's
the default, and on iOS it's the only option — `Window` is a macOS-only scene
type and doesn't exist on iOS at all.

**`Window`** is for a single, named window — one instance, always. No "New
Window" item appears in the File menu for `Window` scenes. This is appropriate
when the window is a tool or panel rather than a document.

NerfJournal uses `Window` for all four windows. The journal is not a document
you open multiple copies of; neither is the Bundle Manager or the Future Log.
One instance of each is always correct. Using `WindowGroup` would add unwanted
"New Window" clutter to the File menu and create confusing duplicate windows
with shared stores.

```swift
// Window — one instance, identified by id string
Window("Journal", id: "journal") {
    JournalView()
}

// WindowGroup — multiple instances allowed; adds New Window to File menu
WindowGroup("Notes") {
    NoteView()
}
```

The `id:` parameter on `Window` is how SwiftUI and your code refer to this
scene — you'll see it used with `openWindow(id:)` when a button needs to open
a specific window.

---

## NerfJournal's Four Windows

```swift
@main
struct NerfJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var pageStore = PageStore()
    @StateObject private var journalStore = JournalStore()
    @StateObject private var bundleStore = BundleStore()
    @StateObject private var categoryStore = CategoryStore()
    @StateObject private var exportGroupStore = ExportGroupStore()

    var body: some Scene {
        Window("Journal", id: "journal") { ... }
        Window("Bundle Manager", id: "bundle-manager") { ... }
        Window("Future Log", id: "future-log") { ... }
        Window("Export Groups", id: "export-groups") { ... }
    }
}
```

All five stores are created here with `@StateObject`. This is the earliest
possible moment in the app's lifetime, and `@StateObject` ties them to the
`NerfJournalApp` instance — which lives for the entire run of the app. They'll
never be recreated or torn down.

The `.defaultSize(width:height:)` modifier on each scene sets the initial
window size. SwiftUI remembers the user's resized dimensions in subsequent
launches; `defaultSize` only applies the first time the window is opened.

---

## Scoping Environment Objects

Not every window receives every store. Each `Window` injects only what its
view hierarchy needs:

```swift
Window("Journal", id: "journal") {
    JournalView()
        .environmentObject(journalStore)
        .environmentObject(pageStore)
        .environmentObject(bundleStore)
        .environmentObject(categoryStore)
        .environmentObject(exportGroupStore)
}

Window("Bundle Manager", id: "bundle-manager") {
    BundleManagerView()
        .environmentObject(bundleStore)
        .environmentObject(categoryStore)
}

Window("Future Log", id: "future-log") {
    FutureLogView()
        .environmentObject(pageStore)
        .environmentObject(categoryStore)
}

Window("Export Groups", id: "export-groups") {
    ExportGroupManagerView()
        .environmentObject(exportGroupStore)
        .environmentObject(categoryStore)
}
```

The scoping is deliberate. The Bundle Manager doesn't need `pageStore` or
`journalStore` — it manages bundles and categories, full stop. The Future Log
reads `pageStore.futureTodos` and `categoryStore.categories` — no more. The
Export Group manager needs only `exportGroupStore` and `categoryStore`.

Providing more environment objects than a window needs isn't harmful — extra
stores won't cause re-renders unless a view actually reads from them. But
scoping precisely communicates intent and prevents views from accidentally
reaching for context they shouldn't use.

Note that `pageStore` still appears in the Bundle Manager's `.focusedSceneObject`
(covered in Unit 6) — focused objects and environment objects serve different
purposes and can overlap without conflict.

---

## Menus: `Commands`, `CommandGroup`, and `CommandMenu`

SwiftUI's menu system is declarative too. A `Commands`-conforming type
describes menu items; you attach it to a scene with the `.commands { }` modifier.

```swift
Window("Journal", id: "journal") { ... }
    .commands {
        DebugCommands()
        TodoCommands()
    }
```

The menu structure in NerfJournal shows all three customization points:

### `CommandGroup` — modify an existing menu group

[`CommandGroup`](https://developer.apple.com/documentation/swiftui/commandgroup)
inserts into, replaces, or appends to a standard system menu group. The groups
are named constants on
[`CommandGroupPlacement`](https://developer.apple.com/documentation/swiftui/commandgroupplacement).

```swift
// Replace the standard "New Item" group entirely:
CommandGroup(replacing: .newItem) {
    Button("Add Todo") { focusAddTodo?.wrappedValue = true }
        .keyboardShortcut("n", modifiers: .command)
    Button("Add Note") { focusAddNote?.wrappedValue = true }
        .keyboardShortcut("n", modifiers: [.command, .shift])
}

// Insert after "New Item" — adds to the File menu without replacing anything:
CommandGroup(after: .newItem) {
    Button("Go to Today") { ... }
        .keyboardShortcut("t", modifiers: .command)
}
```

`replacing: .newItem` removes the default "New Window" and "New Document" items
and substitutes NerfJournal's own. `after: .newItem` inserts the navigation
commands into the File menu without disturbing the others.

`replacing: .saveItem` puts the export commands where "Save" would normally
appear. NerfJournal has no "Save" concept — all writes go to the database
immediately — so this placement makes sense for the nearest equivalent.

### `CommandMenu` — add a new top-level menu

[`CommandMenu`](https://developer.apple.com/documentation/swiftui/commandmenu)
creates an entirely new menu at the top level of the menu bar:

```swift
struct DebugCommands: Commands {
    @FocusedObject var store: PageStore?

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Export…") { Task { await exportDatabase() } }
                .disabled(store == nil)
            Button("Import…") { Task { await importDatabase() } }
                .disabled(store == nil)
            Divider()
            Button("Factory Reset…") { Task { await factoryReset() } }
                .disabled(store == nil)
        }
    }
}
```

`DebugCommands` uses `@FocusedObject var store: PageStore?` to know which
window's `PageStore` is currently active. The buttons are disabled when `store
== nil` — meaning no window that exposes a `PageStore` is focused. This is the
focused-object pattern covered in depth in Unit 6.

---

## `@NSApplicationDelegateAdaptor` — the AppKit Bridge

```swift
@NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
```

[`@NSApplicationDelegateAdaptor`](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)
provides an escape hatch to AppKit's application delegate. It creates an
instance of the specified class and registers it as `NSApplication`'s delegate,
giving you access to lifecycle callbacks that SwiftUI doesn't expose directly.

NerfJournal needs it for one thing: registering a global hot key (Cmd-Shift-J)
that shows the quick-entry panel from anywhere on screen, even when NerfJournal
is in the background. SwiftUI has no API for global hot keys — that requires
Carbon's `RegisterEventHotKey`, which is an AppKit-era C API.

`AppDelegate.swift` implements `applicationDidFinishLaunching` to register the
hot key, then shows an `NSPanel` containing a SwiftUI `QuickNoteView` when the
key fires. This is a narrow bridge: the `AppDelegate` does one thing that
SwiftUI can't, and hands off to SwiftUI hosting for everything else.

The property wrapper creates and owns the `AppDelegate` instance — you
reference it via `appDelegate` if you need to call methods on it from the app
struct, though NerfJournal doesn't need to.

---

## Reading

- [`App`](https://developer.apple.com/documentation/swiftui/app) — the entry
  point protocol
- [`Window`](https://developer.apple.com/documentation/swiftui/window) and
  [`WindowGroup`](https://developer.apple.com/documentation/swiftui/windowgroup)
  — scene types for macOS
- [`Commands`](https://developer.apple.com/documentation/swiftui/commands) —
  the protocol your command types conform to
- [`CommandGroup`](https://developer.apple.com/documentation/swiftui/commandgroup)
  and [`CommandMenu`](https://developer.apple.com/documentation/swiftui/commandmenu)
  — the two customization tools
- [`CommandGroupPlacement`](https://developer.apple.com/documentation/swiftui/commandgroupplacement)
  — the named positions in the standard menu structure
- [`NSApplicationDelegateAdaptor`](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)
  — the AppKit bridge

---

## Code Tour

### `NerfJournalApp.swift` lines 98–147: the full app declaration

The `@main` struct. Read it top to bottom: five `@StateObject` stores, four
`Window` scenes each with `.environmentObject` injections, `.defaultSize`, and
`.commands`. Notice which stores go to which windows and which don't.

The `.focusedSceneObject` calls are also here but belong to Unit 6 — skip them
for now, but note their position (on the view inside the window, not the window
itself).

### `NerfJournalApp.swift` lines 5–94: `TodoCommands`

The two `CommandGroup` calls. Find `replacing: .newItem` and trace what it
replaces. Find `after: .newItem` and note it adds to the File menu. Find
`replacing: .saveItem` and understand why — NerfJournal has no "Save". The
`@FocusedValue` and `@FocusedObject` properties are Unit 6 material, but you
can read the button actions now.

### `DebugCommands.swift`: `CommandMenu`

A standalone file that's entirely one `Commands` type. Notice it creates a
whole top-level menu with three items and a divider, all gated on
`store == nil`. This is the complete picture for `CommandMenu`.

### `AppDelegate.swift`: the AppKit bridge

Read the `registerGlobalHotKey()` function to see why SwiftUI isn't enough
here: the Carbon API requires a C-style callback, an `EventHotKeyRef`, and
`InstallEventHandler` — none of which exists in Swift or SwiftUI. Then read
`showQuickNotePanel()` to see how it immediately returns to SwiftUI hosting via
`NSHostingController`. The AppKit code is minimal and well-contained.

---

## Exercises

**1.** Change one of the `Window` scenes in `NerfJournalApp` to `WindowGroup`
and run `/build`. Then open two instances of that window from the Window menu.
Notice what changes in the app behavior. Revert afterward. This isn't a
behavior you want, but seeing it makes the distinction concrete.

**2.** In `TodoCommands`, the "Add Todo" button has `.disabled(focusAddTodo ==
nil)`. Why is `focusAddTodo` nil when no journal window is focused? (Hint:
where is `.focusedValue(\.focusAddTodo, ...)` applied?) What would happen if
the button stayed enabled?

**3.** `DebugCommands` uses `@FocusedObject var store: PageStore?` but the
journal window uses `.focusedSceneObject(pageStore)`. Read the difference
between `@FocusedObject` and `@FocusedSceneObject` in Apple's documentation
(Unit 6 covers this). Which one is appropriate when the value should be
available to all menus regardless of which view within the window is focused?

**4.** The Export Groups window is opened via `openWindow(id: "export-groups")`
in `TodoCommands`. `openWindow` is an environment value (`@Environment(\.openWindow)`).
Why can `TodoCommands` read from the environment even though it's a `Commands`
type rather than a `View`? (Hint: check Apple's docs for what environment values
are available in `Commands`.)
