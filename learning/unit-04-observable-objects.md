---
title: "Unit 4: Observable Objects and Stores"
nav_order: 40
---

# Unit 4: Observable Objects and Stores

## Introduction

Unit 3 covered state that lives inside a single view — `@State` properties
owned by SwiftUI on behalf of one view, invisible to the rest of the tree.
That model works for transient UI concerns: is this field focused, is this
popover open. It doesn't work for data that multiple views need to read and
write, or that outlives any individual view.

NerfJournal's solution — and the standard SwiftUI pattern — is a set of
*observable objects*: class-based stores that hold the application's data,
publish changes to any view that's watching, and live at the top of the
scene graph where they're accessible to the whole window.

---

## `ObservableObject` and `@Published`

[`ObservableObject`](https://developer.apple.com/documentation/combine/observableobject)
is a protocol for classes (not structs — reference types only) that want to
notify SwiftUI when their data changes. The protocol requires one thing: an
`objectWillChange` publisher that fires before any change. In practice you
never touch `objectWillChange` directly — `@Published` handles it for you.

[`@Published`](https://developer.apple.com/documentation/combine/published)
is a property wrapper that fires `objectWillChange` automatically before each
assignment. Any view that's observing the object gets re-rendered after the
change lands.

```swift
final class CategoryStore: ObservableObject {
    @Published var categories: [Category] = []

    func load() async throws {
        categories = try await db.dbQueue.read { db in
            try Category.order(Column("sortOrder")).fetchAll(db)
        }
        // Assigning to `categories` fires objectWillChange, then updates
        // the value. SwiftUI re-renders any view that read `categories`.
    }
}
```

The mechanics: `@Published` is a property wrapper whose setter calls
`self.objectWillChange.send()` before storing the new value. SwiftUI
subscribes to that publisher when a view first reads from the object, and
re-renders the view when it fires. You never write the subscription code
— attaching the store to a view (covered below) wires it up automatically.

**Why classes?** Because the whole point is *shared mutable state*. Structs are
value types — every assignment copies. If `CategoryStore` were a struct, each
view would hold its own independent copy, and a mutation in one view would be
invisible to all others. Classes share a single instance by reference, so all
views observing the same `CategoryStore` object see the same data.

---

## Attaching a Store to a View

Three property wrappers attach an `ObservableObject` to a view:

### `@StateObject` — the view owns the object

[`@StateObject`](https://developer.apple.com/documentation/swiftui/statedobject)
creates the object when the view first appears and keeps it alive as long as
the view exists in the hierarchy. Even if the declaring view's struct is
recreated on re-render, the object is *not* recreated — SwiftUI holds it
separately, the same way it holds `@State`.

```swift
@main
struct NerfJournalApp: App {
    @StateObject private var pageStore = PageStore()
    @StateObject private var journalStore = JournalStore()
    // ...
}
```

`NerfJournalApp` is the root of the scene graph. Creating stores here with
`@StateObject` gives them the longest possible lifetime — they live for the
entire run of the app.

**`@StateObject` vs `@ObservedObject`**: this distinction trips people up.
`@ObservedObject` tells SwiftUI "I'm watching this object, but I don't own
it." If you accidentally use `@ObservedObject` to create a store inline, the
object is recreated every time the parent re-renders — you lose all its state.
The rule: use `@StateObject` for the view that *creates* the object; use
`@ObservedObject` for views that receive an already-created object as a
parameter. In NerfJournal, `@ObservedObject` doesn't appear at all — stores
are created at the top with `@StateObject` and shared via the environment.

**`@State` vs `@StateObject`**: both tie storage to a view's lifetime in the
hierarchy. The difference is what they store and how SwiftUI detects changes.
`@State` stores a value type (struct, Int, Bool). SwiftUI owns the storage
directly and detects changes via the property wrapper's setter — when you
assign to a `@State` property, SwiftUI sees the write and schedules a
re-render. `@StateObject` stores a reference type — specifically an
`ObservableObject`. SwiftUI manages the object's lifetime (creates it once,
keeps it alive), but doesn't watch for assignments to the property itself.
Instead, it subscribes to the object's `objectWillChange` publisher. The
object announces its own changes via `@Published`; SwiftUI listens.

```swift
@State private var count = 0               // SwiftUI watches the assignment
@StateObject private var store = MyStore() // SwiftUI watches store.objectWillChange
```

A mutable class stored in a plain `@State var` would be invisible to SwiftUI —
it would only notice if you replaced the whole reference, not if you mutated
the object's contents.

### `@EnvironmentObject` — reads from the injected environment

[`@EnvironmentObject`](https://developer.apple.com/documentation/swiftui/environmentobject)
reads an object that was injected higher up the tree via `.environmentObject()`.
It's like `@ObservedObject` but without an explicit parameter — the view just
declares what type it needs, and SwiftUI finds the matching injected instance.

```swift
// Injection at the root (NerfJournalApp.swift):
JournalView()
    .environmentObject(pageStore)
    .environmentObject(categoryStore)

// Consumption anywhere in the subtree (JournalView.swift):
struct JournalView: View {
    @EnvironmentObject private var pageStore: PageStore
    @EnvironmentObject private var categoryStore: CategoryStore
    // ...
}
```

**Why not just pass the store as an init parameter?** The core reason is
*prop drilling* — threading a value through every layer of the view hierarchy
even when intermediate layers don't need it. Consider NerfJournal's hierarchy:

```
NerfJournalApp
└── JournalView(pageStore:)
    └── JournalPageDetailView(pageStore:)
        └── ForEach(todos) { todo in
                TodoRow(pageStore:, todo:)  ← actually uses it
            }
```

With a plain init parameter, every view in the chain must declare it, receive
it, and forward it — including views that don't use `pageStore` themselves but
must carry it to pass down. `@EnvironmentObject` skips the chain: inject once
at the top, and any view in the subtree declares it and reaches it directly.

A plain `let pageStore: PageStore` property also wouldn't subscribe to
`objectWillChange` — you'd get stale renders. You'd need `@ObservedObject var
pageStore: PageStore`, which still requires prop drilling. `@EnvironmentObject`
is essentially `@ObservedObject` sourced from the environment rather than from
an init parameter — observation is included. The React equivalent is Context —
same problem, same solution.

If a view declares `@EnvironmentObject var pageStore: PageStore` but no
`PageStore` was injected, the app crashes at runtime. This is the one sharp
edge of the pattern — the injection and the declaration are not connected at
compile time.

`@EnvironmentObject` is matched by type. If you inject two objects of the same
type, the second overwrites the first. NerfJournal avoids this: each store is
a distinct type.

---

## NerfJournal's Six Stores

```
NerfJournalApp (@StateObject)
├── PageStore        — current page's todos, notes, future todos; all mutations
├── JournalStore     — read-only index of pages; drives calendar highlighted dates
├── BundleStore      — task bundles and their todos
├── CategoryStore    — categories (name, color, sort order)
├── ExportGroupStore — export groups and memberships
└── AppDatabase      — wraps the GRDB DatabaseQueue; runs migrations
```

`AppDatabase` is the odd one out — it's not an `ObservableObject` at all.
It's a plain class that wraps the database connection, created once and
shared via a static `.shared` property. The stores hold a reference to it
but views never interact with it directly.

Each store follows the same pattern: an `async throws` mutation method writes
to the database, then calls `refreshContents()` (or equivalent) to re-query
and update `@Published` properties. SwiftUI then re-renders views that read
those properties.

```swift
func completeTodo(_ todo: Todo, ...) async throws {
    try await db.dbQueue.write { db in     // 1. mutate database
        try Todo.filter(...).updateAll(db, [...])
    }
    try await refreshContents()            // 2. re-query → update @Published
    // @Published assignment → objectWillChange → view re-render
}
```

This "mutate then re-query" pattern is deliberate: rather than trying to patch
`todos` in-place (error-prone, especially for bulk operations), every mutation
ends with a full re-fetch from the database. The database is the source of
truth; the `@Published` arrays are a cache of the last query result.

---

## `@MainActor`

All six stores are marked `@MainActor`:

```swift
@MainActor
final class PageStore: ObservableObject { ... }
```

[`@MainActor`](https://developer.apple.com/documentation/swift/mainactor) is a
*global actor* — a Swift concurrency mechanism that ensures all methods on the
annotated type run on the main thread. This matters because:

1. UIKit and AppKit (which SwiftUI sits on top of) require that UI updates
   happen on the main thread. Assigning to a `@Published` property from a
   background thread will cause crashes or undefined behavior.
2. The database reads happen asynchronously — `await db.dbQueue.read { ... }`
   runs the closure on GRDB's private queue, then returns the result to the
   caller. Without `@MainActor`, "the caller" could be any thread.

With `@MainActor`, after `await db.dbQueue.read { ... }` completes and
control returns to the store method, Swift guarantees execution is back on the
main thread before the next line runs. Assigning to `categories = ...` is
always safe. The compiler enforces this — calling a `@MainActor` method from a
non-isolated context requires `await`, which suspends until the main thread is
available.

The Rust parallel: `@MainActor` is like requiring `Send + 'static` for thread
safety, but inverted — instead of proving data is safe to move across threads,
you're declaring that this code must *stay* on one specific thread.

---

## `[weak self]` in Notification Observers

The stores subscribe to `NotificationCenter` in `init`, and the closures
capture `self`:

```swift
init(database: AppDatabase = .shared) {
    self.db = database
    NotificationCenter.default.addObserver(
        forName: .nerfJournalDatabaseDidChange,
        object: nil,
        queue: .main
    ) { [weak self] _ in
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await self.load()
        }
    }
}
```

`[weak self]` captures `self` as a weak reference. Without it, the closure
holds a strong reference to the store, and the store holds the closure via
NotificationCenter — a reference cycle that prevents deallocation. With
`[weak self]`, if the store is ever deallocated, `self` becomes nil inside the
closure, the `guard let self` fails, and the closure exits harmlessly.

In NerfJournal's case the stores live for the entire app lifetime, so the
cycle would never actually cause a leak. The pattern is still correct practice
— any time you capture `self` in a closure that gets stored somewhere (an
observer, a completion handler), use `[weak self]`.

One subtlety: `[weak self]` prevents the retain cycle and ensures the closure
exits harmlessly if `self` is gone, but *the closure itself remains registered
in NotificationCenter and keeps firing*. With the block-based API
(`addObserver(forName:object:queue:using:)`), the block is retained by
NotificationCenter until explicitly removed. For short-lived objects this
matters — you need to capture the token the method returns and remove it in
`deinit`:

```swift
private var observers: [NSObjectProtocol] = []

init() {
    let token = NotificationCenter.default.addObserver(
        forName: .nerfJournalDatabaseDidChange, ...
    ) { [weak self] _ in ... }
    observers.append(token)
}

deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
}
```

NerfJournal discards the token (doesn't capture the return value). This is
only safe because the stores live for the entire app lifetime. The older
selector-based API ([`addObserver(_:selector:name:object:)`](https://developer.apple.com/documentation/foundation/notificationcenter/addobserver(_:selector:name:object:)))
has automatically cleaned up dead observers since macOS 10.11, so `deinit`
cleanup is only needed with the block-based form.

---

## How `JournalStore` Watches `PageStore`

The stores are not entirely independent. `JournalStore` needs to know when
todos change (to refresh the calendar's highlighted dates). Rather than
`JournalStore` holding a reference to `PageStore` — which would tangle the
ownership graph — they communicate via `NotificationCenter`:

```swift
// PageStore, at the end of refreshContents():
NotificationCenter.default.post(name: .nerfJournalTodosDidChange, object: nil)

// JournalStore, in init():
NotificationCenter.default.addObserver(
    forName: .nerfJournalTodosDidChange, ...
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self, let date = self.selectedDate else { return }
        try? await self.selectDate(date)
    }
}
```

`PageStore` posts a notification; `JournalStore` reacts. Neither knows about
the other. This is the same `NotificationCenter` pattern you'd use in AppKit
— it's not SwiftUI-specific. Unit 6 covers more of the cross-store
communication patterns.

---

## Reading

- [`ObservableObject`](https://developer.apple.com/documentation/combine/observableobject)
- [`@Published`](https://developer.apple.com/documentation/combine/published)
- [`@StateObject`](https://developer.apple.com/documentation/swiftui/statedobject)
- [`@EnvironmentObject`](https://developer.apple.com/documentation/swiftui/environmentobject)
- [`@MainActor`](https://developer.apple.com/documentation/swift/mainactor)
- [Model data in SwiftUI](https://developer.apple.com/documentation/swiftui/model-data)
  — Apple's overview of the whole observable object model

---

## Code Tour

### `NerfJournalApp.swift` lines 98–145

The root of the app. All six stores are created with `@StateObject`. Then
`.environmentObject()` injects them into each window's view subtree. Notice
that not every store goes to every window — `BundleManagerView` gets
`bundleStore` and `categoryStore`, not `pageStore`; this is deliberate scoping.

### `PageStore.swift` lines 1–22: class declaration and init

Read the `@MainActor` annotation, `ObservableObject` conformance, `@Published`
properties, and the distributed notification observer in `init`. The observer
is for the CLI tool — when `nerf-add-todo` inserts a todo from the command
line, it posts a distributed notification that triggers a refresh here.

### `PageStore.swift` lines 475–515: `refreshContents`

The workhorse method. It runs two queries against the database and assigns the
results to `@Published` arrays. Every mutation method ends by calling this —
the database is the source of truth, and this is how the in-memory cache stays
in sync.

### `CategoryStore.swift` lines 1–28

A simpler store to read first. One `@Published` array, one `load()` method,
one NotificationCenter observer. The pattern is identical to `PageStore` but
without the complexity of multiple query sets or undo support.

### `JournalView.swift` lines 20–28: `@EnvironmentObject` declarations

Four `@EnvironmentObject` properties at the top of `JournalView`. This view
reads from all of them; SwiftUI re-renders it whenever any of those objects
fire `objectWillChange`.

---

## Exercises

**1.** `CategoryStore` uses `@Published var categories: [Category] = []` and
reassigns the whole array in `load()`. What would happen if `load()` were
called on a background thread — before `@MainActor` was on the class? Why
would that be a problem even if GRDB's result is correct?

**2.** In `NerfJournalApp`, the stores are `@StateObject`. What would break if
they were `@ObservedObject` instead? (Hint: when does `NerfJournalApp.body`
run, and what does `@ObservedObject` do on each run?)

**3.** `PageStore.refreshContents` assigns to `todos`, `notes`, and
`futureTodos`. Each assignment fires `objectWillChange` separately. Does that
mean SwiftUI re-renders three times? Look up SwiftUI's change coalescing
behavior — the answer is more nuanced than it first appears.

**4.** `JournalStore` observes `.nerfJournalTodosDidChange` but not
`.nerfJournalDatabaseDidChange`. `CategoryStore` observes
`.nerfJournalDatabaseDidChange` but not `.nerfJournalTodosDidChange`. Why does
each store subscribe to a different notification? What does each one need to
react to?
