---
title: "Unit 6: Focus, Cross-Window Communication, and Notifications"
nav_order: 60
---

# Unit 6: Focus, Cross-Window Communication, and Notifications

## Introduction

The macOS menu bar belongs to no particular window. When a user chooses "Add
Todo" from the File menu, that command needs to reach into the frontmost
journal window and trigger its add-field — but `TodoCommands` isn't a view,
has no direct reference to `JournalPageDetailView`, and may be running while
any of four different windows is frontmost.

This unit covers the two mechanisms SwiftUI provides for this problem: the
*focused scene object* system for exposing stores to menu commands, and
*focused values* for publishing view-level state upward through the focus
chain. It also covers the `NotificationCenter` patterns that let stores
communicate with each other without direct references — and why NerfJournal's
CLI tool requires a different notification center entirely.

---

## The Problem: Menus Without References

Menu commands in SwiftUI are declared outside any window's view hierarchy.
`TodoCommands` has no `init` parameters, no stored properties pointing at
specific views, and no way to call methods on a particular
`JournalPageDetailView` instance. Yet "Add Todo" must focus a specific text
field inside a specific window.

The solution is an ambient *focus environment* — a set of values that flow
upward from focused views and scenes toward the menu bar. Commands read from
this environment; views and scenes publish into it. When no matching value is
in scope (no relevant window is frontmost), the command reads nil and disables
itself.

---

## Scene-Level Focus: `focusedSceneObject` and `@FocusedObject`

[`.focusedSceneObject(_:)`](https://developer.apple.com/documentation/swiftui/view/focusedsceneobject(_:)-1rnaj)
publishes an `ObservableObject` into the focus environment for an entire scene.
Unlike `@EnvironmentObject` (which makes data available *downward* to child
views), focused scene objects travel *upward* — out of the view hierarchy to
the menu bar.

In `NerfJournalApp.swift`, the journal window's root view applies four of them:

```swift
JournalView()
    .environmentObject(pageStore)   // downward — child views can read it
    .focusedSceneObject(pageStore)  // upward — menus can read it
    .focusedSceneObject(journalStore)
    .focusedSceneObject(categoryStore)
    .focusedSceneObject(exportGroupStore)
```

`environmentObject` and `focusedSceneObject` are completely independent — the
same object goes both directions here, but they serve different purposes and
don't interact.

The "scene" part of the name is key: the value is available to menu commands
for the **entire window**, regardless of which view inside the window currently
has keyboard focus. If the user is typing in a text field, scrolling a list, or
has no particular control focused, `pageStore` is still readable in menus as
long as the journal window is frontmost.

**`@FocusedObject`** reads a value published by either `.focusedSceneObject` or
the view-level `.focusedObject`. In `TodoCommands`:

```swift
struct TodoCommands: Commands {
    @FocusedObject var journalStore: JournalStore?
    @FocusedObject var pageStore: PageStore?
    @FocusedObject var categoryStore: CategoryStore?
    @FocusedObject var exportGroupStore: ExportGroupStore?
```

Each property is `Optional` — `nil` when no matching object is in the focus
environment (i.e., when the frontmost window hasn't published one). Menu items
gate their availability on this:

```swift
Button("Go to Today") { ... }
    .disabled(journalStore == nil)
```

When the Bundle Manager window is frontmost, `journalStore` is nil (the Bundle
Manager doesn't call `.focusedSceneObject(journalStore)`), so "Go to Today" is
grayed out. When the journal window comes forward, the focused scene objects
become available and the items enable. This is the nil-means-disabled pattern
throughout the command files.

Note that `BundleManagerView` applies `.focusedSceneObject(pageStore)` even
though it doesn't use `pageStore` directly as an environment object:

```swift
BundleManagerView()
    .environmentObject(bundleStore)   // what BundleManagerView needs
    .environmentObject(categoryStore)
    .focusedSceneObject(pageStore)    // so Debug menu works from this window too
```

This lets the Debug menu's export/import/factory-reset commands function from
the Bundle Manager window, which is a reasonable expectation.

---

## View-Level Focus: `focusedValue` and `FocusedValueKey`

Some state is more specific than "a whole window's store." The "Add Todo" command
needs to write to `addFieldFocused` inside a particular `JournalPageDetailView`.
That view may not even exist (no page loaded), and the binding to its text
field shouldn't be published when the view is in read-only mode.

This calls for view-level focused values. Unlike `.focusedSceneObject`, these
values are nil unless the specific view that publishes them is part of the
current focus chain.

The pattern in NerfJournal has three parts.

**1. Define a key.** A
[`FocusedValueKey`](https://developer.apple.com/documentation/swiftui/focusedvaluekey)
is a type whose `Value` associated type declares what the focused value carries:

```swift
struct FocusAddTodoKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

extension FocusedValues {
    var focusAddTodo: Binding<Bool>? {
        get { self[FocusAddTodoKey.self] }
        set { self[FocusAddTodoKey.self] = newValue }
    }
}
```

This is the same subscript-based dictionary pattern as `EnvironmentKey` (Unit
3's `@Environment`). The extension on `FocusedValues` provides a typed property
instead of a raw subscript.

**2. Publish the value.** `JournalPageDetailView` applies `.focusedValue` to
publish a `Binding<Bool>` into the focus environment:

```swift
.focusedValue(\.focusAddTodo, readOnly ? nil : Binding<Bool>(
    get: { addFieldFocused && !entryIsNote },
    set: { newValue in
        if newValue {
            entryIsNote = false; showAddField = true
            scrollToFieldRequest += 1
        }
        addFieldFocused = newValue
    }
))
```

When `readOnly` is true (no page is loaded for this date), the value is `nil`
— the command gets nil and disables itself. When a page exists, the value is a
custom `Binding<Bool>` (Unit 3's `Binding(get:set:)` pattern) that both reads
focus state and drives the field into view when set to `true`.

**3. Read the value.** `TodoCommands` reads it with `@FocusedValue`:

```swift
@FocusedValue(\.focusAddTodo) var focusAddTodo: Binding<Bool>?
```

```swift
Button("Add Todo") { focusAddTodo?.wrappedValue = true }
    .disabled(focusAddTodo == nil)
```

Setting `focusAddTodo?.wrappedValue = true` writes through the binding: the
`set` closure runs, `addFieldFocused` becomes true, and the text field gets
focus. The command never touches `JournalPageDetailView` directly — it just
writes to a binding that `JournalPageDetailView` chose to expose.

### `@FocusedSceneObject` vs `@FocusedValue`

The distinction matters:

| | `.focusedSceneObject` | `.focusedValue` |
|---|---|---|
| Scope | Whole scene (window) | Declaring view's focus chain only |
| Available when | Window is frontmost | View is focused (or ancestor is) |
| Type | `ObservableObject` | Any value |
| Use case | Stores: whole-window resources | View-specific state: field focus, selection |

Stores go via `.focusedSceneObject` because they're window-wide resources.
The add-field binding goes via `.focusedValue` because it only makes sense
when that specific view (with a real page loaded) is in the picture.

---

## In-Process Events: `NotificationCenter`

Stores don't hold references to each other. `JournalStore` doesn't know
`PageStore` exists. Yet when `PageStore` refreshes its todo list, `JournalStore`
needs to refresh its calendar highlighted dates. And when `PageStore` performs
a full import or factory reset, both `JournalStore` and `CategoryStore` need to
reload completely.

The mechanism is [`NotificationCenter`](https://developer.apple.com/documentation/foundation/notificationcenter)
— an in-process publish/subscribe bus. `AppDatabase.swift` declares the two
notification names NerfJournal uses:

```swift
extension Notification.Name {
    static let nerfJournalDatabaseDidChange = Notification.Name("org.rjbs.nerfjournal.databaseDidChange")
    static let nerfJournalTodosDidChange    = Notification.Name("org.rjbs.nerfjournal.todosDidChange")
}
```

**`.nerfJournalDatabaseDidChange`** is a "everything changed" signal. It's
posted by `PageStore` after `importDatabase` or `factoryReset` — operations
that replace the whole database. `JournalStore` observes it to reload its page
index and clear selection. `CategoryStore` observes it to reload the category
list.

**`.nerfJournalTodosDidChange`** is a finer-grained signal. `PageStore.refreshContents()`
posts it at the end of every normal mutation — a todo was added, completed,
moved. `JournalStore` observes it to update its calendar's highlighted dates
without doing a full reload of the page index.

Neither store subscribes to both: `JournalStore` needs both (index reload for
import, calendar refresh for mutations); `CategoryStore` only needs the
database-changed one (categories aren't affected by todo mutations).

```
PageStore.importDatabase()  →  posts .nerfJournalDatabaseDidChange
                                    → JournalStore: reloads index, clears selection
                                    → CategoryStore: reloads categories

PageStore.refreshContents() →  posts .nerfJournalTodosDidChange
                                    → JournalStore: refreshes calendar for current date
```

`NotificationCenter` is in-process only: notifications never leave the app's
memory space. This is the right tool for intra-app communication — using
`DistributedNotificationCenter` for internal events would needlessly involve
the OS for something that doesn't cross any process boundary.

---

## Cross-Process Events: `DistributedNotificationCenter`

The CLI tool (`nerf-add-todo`) runs as a separate process. When it inserts a
todo, the journal app needs to reload — but the two processes share no memory
and have no direct connection.

[`DistributedNotificationCenter`](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
routes notifications through a system daemon, crossing process boundaries.
`PageStore.init` subscribes to the CLI's signal:

```swift
DistributedNotificationCenter.default().addObserver(
    forName: NSNotification.Name("org.rjbs.nerfjournal.externalChange"),
    object: nil,
    queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in try? await self?.refreshContents() }
}
```

There are three meaningful differences from `NotificationCenter`:

**Scope.** `NotificationCenter` is in-process only. `DistributedNotificationCenter`
crosses process boundaries via a system daemon. For intra-app communication
there's no reason to involve the OS.

**Sandboxing.** Sandboxed apps have restricted access to
`DistributedNotificationCenter`. You can post and receive notifications whose
name is prefixed with your own bundle identifier, but arbitrary cross-app
notification names are blocked. NerfJournal uses
`org.rjbs.nerfjournal.externalChange` specifically because the prefix matches
the app's bundle ID, which sandbox rules permit.

**Payload.** `NotificationCenter` notifications can carry any Swift object as
`userInfo`. `DistributedNotificationCenter` must serialize the payload through
the OS — only property-list-compatible types are allowed, and large payloads
are discouraged. The CLI's notification carries no payload at all (it just
pokes the app to re-read the database), which sidesteps this entirely.

The split in NerfJournal is principled: `DistributedNotificationCenter` only
where the process boundary makes it necessary; `NotificationCenter` everywhere
else.

---

## Reading

- [`focusedSceneObject(_:)`](https://developer.apple.com/documentation/swiftui/view/focusedsceneobject(_:)-1rnaj)
  — publish a store for the active window
- [`@FocusedObject`](https://developer.apple.com/documentation/swiftui/focusedobject)
  — read a focused object in a `Commands` type or view
- [`FocusedValueKey`](https://developer.apple.com/documentation/swiftui/focusedvaluekey)
  — define a custom focused value key
- [`focusedValue(_:_:)`](https://developer.apple.com/documentation/swiftui/view/focusedvalue(_:_:))
  — publish a focused value from a view
- [`@FocusedValue`](https://developer.apple.com/documentation/swiftui/focusedvalue)
  — read a focused value
- [`NotificationCenter`](https://developer.apple.com/documentation/foundation/notificationcenter)
  — in-process publish/subscribe
- [`DistributedNotificationCenter`](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
  — cross-process notifications on macOS

---

## Code Tour

### `NerfJournalApp.swift` lines 107–131: `.focusedSceneObject` placements

Read which stores each window exposes via `.focusedSceneObject`. Notice the
journal window exposes four; the Bundle Manager exposes only `pageStore` (for
the Debug menu). The Future Log and Export Groups windows expose none — they
have no menu commands that need focused objects.

### `NerfJournalApp.swift` lines 5–12: `TodoCommands` focused properties

The four `@FocusedObject` properties and the two `@FocusedValue` properties at
the top of `TodoCommands`. Each is optional; each menu item below checks its
relevant property for nil before enabling. Read the `@FocusedValue` declarations
alongside the key definitions in `JournalView.swift` (lines 1308–1330) to see
the full chain.

### `JournalView.swift` lines 594–613: `.focusedValue` publishing

The two `.focusedValue` calls at the bottom of `JournalPageDetailView.body`.
Note `readOnly ? nil : Binding<Bool>(...)` — the conditional nil is deliberate.
Then look up in the file to find the `readOnly` computed property to understand
when nil is published.

### `JournalView.swift` lines 1308–1330: `FocusAddTodoKey` and `FocusAddNoteKey`

The two `FocusedValueKey` conformances and their `FocusedValues` extensions.
Four lines each. This is the complete boilerplate for a custom focused value.

### `PageStore.swift` lines 463–473: `importDatabase` and `factoryReset`

Both methods post `.nerfJournalDatabaseDidChange` after finishing. Read them
alongside `JournalStore.swift` (lines 16–29) and `CategoryStore.swift` (lines
12–21) to see the observer chain from post to reload.

### `PageStore.swift` lines 13–22: the distributed notification observer

`PageStore.init` — five lines that subscribe to the CLI's signal. Note the use
of `DistributedNotificationCenter.default()` rather than `NotificationCenter.default`,
and the plain string name rather than a `Notification.Name` extension constant
(the CLI uses the same string directly without importing any shared code).

---

## Exercises

**1.** In `JournalPageDetailView`, `.focusedValue(\.focusAddTodo, ...)` passes
`nil` when `readOnly` is true. What does `readOnly` mean, and when is it true?
Find the definition and read it.

**2.** `BundleManagerView` applies `.focusedSceneObject(pageStore)` even though
`BundleManagerView` itself doesn't use `pageStore`. What would break if you
removed that line? Which menu commands would be affected, and how would they
behave?

**3.** `JournalStore` subscribes to both `.nerfJournalDatabaseDidChange` and
`.nerfJournalTodosDidChange`. `CategoryStore` subscribes only to
`.nerfJournalDatabaseDidChange`. Why doesn't `CategoryStore` need
`.nerfJournalTodosDidChange`? What would happen if it did subscribe — would it
be wrong, or just wasteful?

**4.** The CLI tool posts `org.rjbs.nerfjournal.externalChange` after inserting
a todo. `PageStore` observes it and calls `refreshContents()`. But
`refreshContents()` also posts `.nerfJournalTodosDidChange`, which `JournalStore`
observes. Trace the full chain: one CLI insert → how many `NotificationCenter`
posts happen in the app, and which store methods run as a result?
