---
title: "Unit 8: Undo, Transactions, and Correctness"
nav_order: 80
---

# Unit 8: Undo, Transactions, and Correctness

## Introduction

Undo is one of those features that feels like it should be free and turns out to
be a small theory of your own data model. To undo an action you must, before you
perform it, know exactly what state you are about to destroy and exactly how to
put it back — and you must put it back so faithfully that *other* pending undo
steps, captured before yours, still make sense afterward.

This unit works through NerfJournal's undo system end to end: where the
`UndoManager` comes from, the small `scheduleUndo` helper every mutation funnels
through, how prior state is captured as a value before the database is touched,
and why `restoreTodo` is careful to re-insert the *original* row identity rather
than a fresh one. Along the way it covers how a bulk operation becomes a *single*
undo step, how each mutation rides one SQLite transaction, and — being precise
about where a mechanism stops holding — exactly what this pattern does and does
**not** give you. (It does not give you redo, and the code says so out loud.)

The relevant comparison is less to Perl or Rust than to the command pattern you
may know from any GUI toolkit: an action and its inverse, pushed onto a stack.
What's Swift-specific is how the async, actor-isolated, value-typed pieces fit
together — and that's where the interesting details live.

---

## Where the `UndoManager` comes from

NerfJournal never constructs an
[`UndoManager`](https://developer.apple.com/documentation/foundation/undomanager).
SwiftUI hands one down through the environment, and views pull it out with
[`@Environment(\.undoManager)`](https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager):

```swift
@Environment(\.undoManager) private var undoManager
```

This appears in each view that initiates mutations — the todo row and the page
detail view. The value is the `UndoManager` belonging to the view's
*window*, which is also the one the standard Edit menu's Undo/Redo items and
Cmd-Z are wired to. Register an action with it and Cmd-Z just works; no menu
plumbing required (a payoff of the standard-menus decision from Unit 5).

Two consequences of it coming from the environment:

- **It's optional.** `@Environment(\.undoManager)` is `UndoManager?`. There isn't
  always a window with an undo manager (think of a command fired when no document
  window is key), so it can be `nil`. This is why every store method that supports
  undo takes `undoManager: UndoManager? = nil` — the store never assumes one
  exists, and an action simply isn't undoable when it's absent.
- **The view passes it inward.** The store is created once and lives for the whole
  app; the `UndoManager` is per-window and reached through the view tree. So the
  view reads it from the environment and passes it as an argument on each call:
  `pageStore.completeTodo(todo, undoManager: undoManager)`. The store doesn't —
  and shouldn't — hold a reference to it.

---

## The shape of one undoable mutation

Every undoable method in `PageStore` has the same four-beat shape. `completeTodo`
is the smallest example:

```swift
func completeTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
    let ending = TodoEnding(date: defaultEndingDate, kind: .done)
    try await db.dbQueue.write { db in                 // 1. mutate
        try Todo.filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: ending)])
    }
    scheduleUndo(with: undoManager) { store in          // 2. register the inverse
        try await store.uncompleteTodo(todo, undoManager: undoManager)
    }
    try await refreshContents()                         // 3. refresh + 4. notify
}
```

1. Perform the mutation inside a `dbQueue.write` (Unit 7's actor-crossing seam).
2. Register the inverse with the undo manager.
3. `refreshContents()` re-reads the database and republishes the `@Published`
   arrays — and posts `.nerfJournalTodosDidChange` (Unit 6).

The ordering of the first two beats is deliberate and load-bearing: the undo is
registered **after** the write succeeds. If the write throws, the method exits
before `scheduleUndo` runs, so no undo step is registered for a mutation that
never happened. You never get a Cmd-Z that "undoes" a no-op.

Notice the inverse is just *another ordinary store method*: undoing a
`completeTodo` is exactly a `uncompleteTodo`. There's no separate "undo code path"
to keep correct — the inverse is real functionality the app already has. We'll see
in a moment what that buys and what it costs.

### The `scheduleUndo` dance

The inverse can't be handed to `UndoManager` directly, because there's an
impedance mismatch. `registerUndo(withTarget:handler:)` wants a *synchronous*
closure. But every NerfJournal mutation is `async` (it awaits the database) and
`@MainActor`-isolated (Unit 9). `scheduleUndo` is the adapter:

```swift
// Registers an undo action, handling the Task { @MainActor } dance that
// every async mutation needs. -- claude, 2026-03-02
private func scheduleUndo(with manager: UndoManager?,
                          _ action: @escaping (PageStore) async throws -> Void) {
    manager?.registerUndo(withTarget: self) { store in
        Task { @MainActor in try? await action(store) }
    }
}
```

Three details, each worth reading slowly:

- **`withTarget: self`.** `UndoManager` keeps an *unowned* reference to the target
  and hands it back to the handler when undo fires (here as `store`). It does not
  retain the target, so there's no reference cycle between the long-lived store and
  the manager. The handler receives the store as a parameter rather than capturing
  `self`, which keeps the closure from being the thing that retains it.
- **`Task { @MainActor in ... }`.** The synchronous handler can't `await`, so it
  spawns a `Task` to run the async inverse on the main actor. The handler returns
  immediately; the actual undo work happens slightly later. (This deferral has a
  consequence for redo — see below.)
- **`try?`.** Errors from the inverse are swallowed. A database failure *during an
  undo* is silently dropped rather than surfaced. That's a real, if minor,
  limitation: there's no UI path for "your undo failed," so the pragmatic choice
  is to discard the error rather than crash. Worth knowing it's a deliberate floor,
  not an oversight.

---

## Capturing prior state — as a value, before the write

To reverse a mutation you need the old value, and you must capture it *before* you
overwrite it. Every "set" method does this on its first line:

```swift
func setTitle(_ title: String, for todo: Todo, undoManager: UndoManager? = nil) async throws {
    let oldTitle = todo.title                    // capture first
    try await db.dbQueue.write { db in
        try Todo.filter(Column("id") == todo.id)
                .updateAll(db, [Column("title").set(to: title)])
    }
    scheduleUndo(with: undoManager) { store in
        try await store.setTitle(oldTitle, for: todo, undoManager: undoManager)
    }
    try await refreshContents()
}
```

`oldTitle` is a `String`, a value type (Unit 1). The capture is a *copy*: nothing
the database does afterward can change `oldTitle`, and the undo closure holds its
own independent snapshot. This is the quiet workhorse of the whole design — value
semantics mean "remember the old state" is just a local `let`, with no defensive
copying, no risk of the remembered value mutating out from under you. The same
pattern recurs for `oldEnding`, `oldCategoryID`, `oldTimestamp`, and the bulk
arrays below.

`markPending` shows why capturing the *specific* prior state matters. A pending
todo can come from either a completed or an abandoned one, and the correct inverse
differs:

```swift
let oldEnding = todo.ending
scheduleUndo(with: undoManager) { store in
    if oldEnding?.kind == .done {
        try await store.completeTodo(todo, undoManager: undoManager)
    } else if oldEnding?.kind == .abandoned {
        try await store.abandonTodo(todo)
    }
}
```

Undo has to restore the kind of ending that was actually there, so the captured
`oldEnding` decides which inverse to run. A coarser "make it done again" would be
wrong half the time.

---

## `restoreTodo` and the identity question

Deleting a todo and undoing the delete is the case that most rewards precision.
Here is the whole of it:

```swift
func deleteTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
    try await db.dbQueue.write { db in
        try Todo.filter(Column("id") == todo.id).deleteAll(db)
    }
    scheduleUndo(with: undoManager) { store in
        try await store.restoreTodo(todo)        // hands back the captured value
    }
    try await refreshContents()
}

private func restoreTodo(_ todo: Todo) async throws {
    guard page != nil else { return }
    try await db.dbQueue.write { db in
        var restored = todo
        try restored.insert(db)                  // insert WITH the original id
    }
    try await refreshContents()
}
```

The subtlety is in `var restored = todo; try restored.insert(db)`. The `todo`
value captured by the undo closure still has its **original** `id` — say `42` —
because it was captured before the delete and value types don't change underfoot.
When GRDB inserts a record whose primary key is already set to a non-`nil` value,
it inserts *that* row id rather than letting SQLite autoincrement a new one. So
undoing a delete brings todo `42` back as todo `42`.

Why does that matter? Two reasons, both about correctness across *other* undo
steps and the UI:

- **Sort order.** Todos are displayed via `sortedForDisplay()`, which orders by
  `id` (Unit 7). Re-inserting with the original id drops the todo back into its
  original position. A fresh autoincremented id would be larger than every
  existing id, so the restored todo would jump to the bottom of the list — a
  visible, wrong "undo."
- **Identity for other pending operations.** Every undo closure on the stack
  refers to its todo by value, and every store method keys off `Column("id")`. If a
  restored todo came back with a new id, any *earlier* undo step that mentions id
  `42` would now target nothing — silently a no-op. By preserving the id, the
  whole stack stays coherent.

This is the reverse of the `addTodo` path, where the todo is constructed with
`id: nil` precisely so SQLite *will* assign a fresh one (Unit 7's
nil-means-not-yet-persisted). Insert with `nil` to create; insert with the
original id to *restore*. Same method, opposite intent, distinguished entirely by
whether the id is already set.

---

## Bulk operations: one transaction, one undo step

A context-menu action can target many selected todos at once. The design goal is
that such an action behaves as a single unit in *both* senses: atomic in the
database, and a single press of Cmd-Z to reverse the whole thing. `bulkDelete`:

```swift
func bulkDelete(_ todos: [Todo], undoManager: UndoManager? = nil) async throws {
    let snapshot = todos                              // capture all of them
    try await db.dbQueue.write { db in                // ONE transaction
        for todo in todos {
            try Todo.filter(Column("id") == todo.id).deleteAll(db)
        }
    }
    scheduleUndo(with: undoManager) { store in        // ONE undo registration
        try await store.restoreBulkTodos(snapshot)
    }
    try await refreshContents()
}
```

Both properties come from structure, not from any special bulk API:

- **Atomicity** is the `dbQueue.write` wrapping the whole loop. GRDB runs a `write`
  block inside one transaction (Unit 7), so either all the deletes commit or, if
  any statement throws, the transaction rolls back and none do. There's no state
  where half the selection is deleted.
- **One undo step** is the single `scheduleUndo` call. The manager records exactly
  one action for the entire batch, so Cmd-Z restores every todo in `snapshot`
  together. `restoreBulkTodos` loops the same way, re-inserting each captured value
  with its original id (the identity argument above, applied N times):

  ```swift
  private func restoreBulkTodos(_ todos: [Todo]) async throws {
      try await db.dbQueue.write { db in
          for todo in todos {
              var restored = todo
              try restored.insert(db)
          }
      }
      try await refreshContents()
  }
  ```

`setBulkCategory` adds one wrinkle worth singling out. It captures prior categories
from **both** live and future todos:

```swift
let oldCategories: [(Int64, Int64?)] = (todos + futureTodos)
    .filter { ids.contains($0.id!) }
    .map { ($0.id!, $0.categoryID) }
```

The selection can include a future-dated todo (one shown only in the Future Log,
Unit 6's `futureTodos`). If the capture scanned only `todos`, a selected future
todo's prior category would be missing from the snapshot, and undo would silently
fail to restore it. Searching `todos + futureTodos` ensures every id in the
selection has its old value recorded. It is a "which set does the data actually
live in?" question, and the answer has to match the query in `refreshContents`
that produced those two arrays in the first place: get the captured set wrong and
undo is quietly incomplete.

---

## What you get, and what you don't: the redo gap

Because each inverse is itself a full mutation that calls `scheduleUndo`, you
might expect redo to fall out for free: undo a complete → it runs `uncompleteTodo`
→ which registers a `completeTodo` as *its* inverse → which is the redo. That is
the classic command-pattern bootstrap, and `UndoManager` is built to support it
(it routes registrations made *while undoing* onto the redo stack).

But here it doesn't quite happen, and the code knows it — `setBulkCategory` and
`sendToDate` both carry the comment *"there is no redo."* The reason is the `Task`
in `scheduleUndo`:

`UndoManager` decides whether a `registerUndo` call is a redo registration by
checking, *synchronously*, whether it is currently inside an undo (its
`isUndoing` flag). When Cmd-Z fires, the manager sets `isUndoing`, runs the
registered handler, and clears the flag. NerfJournal's handler, though, only
*spawns a `Task`* and returns immediately — the actual inverse, and its
`scheduleUndo`/`registerUndo` call, run later, after `isUndoing` has already been
cleared. So that re-registration isn't seen as a redo; it lands on the **undo**
stack instead.

The practical effect: pressing Cmd-Z repeatedly *toggles* the action (complete →
undo uncompletes → undo completes again → …) rather than building a separate redo
stack, and the Edit menu's Redo item stays empty. For a journaling app that's an
acceptable trade — you can always undo your undo — and the source comments name
the limitation outright rather than implying a redo that isn't wired up. If true
redo were wanted, the fix would be to make the undo work happen synchronously
within the handler, or to register the redo explicitly while `isUndoing` is set,
rather than deferring through a `Task`.

The takeaway is to be exact about where the mechanism stops: the
inverse-registers-its-inverse trick gives you arbitrarily deep undo; it does
**not**, through a deferred `Task`, give you redo.

---

## Stale captures in `ForEach` context menus

One more correctness hazard, called out in passing in earlier units. A row view
captures its `todo` *by value at render time*. If that row sits unchanged while
the underlying todo is mutated by some other path, the captured `todo` is now a
stale snapshot — and an action that reads fields off it (like `markPending` reading
`todo.ending`) could decide its inverse from out-of-date state.

The mitigation appears in the context menu, which re-derives its working set from
the store at the moment the menu is built, not from a captured array:

```swift
.contextMenu {
    let affectedIDs: Set<Int64> = selectedIDs.contains(todo.id!) && selectedIDs.count > 1
        ? selectedIDs : [todo.id!]
    let affectedTodos = store.todos.filter { affectedIDs.contains($0.id!) }
    // ... menu items use affectedTodos ...
}
```

SwiftUI rebuilds a `contextMenu`'s content each time it's presented, so
`store.todos.filter { ... }` runs against the *current* published array when you
right-click — fresh, not render-time. The selection is tracked by **id**
(`selectedIDs`, `affectedIDs`) rather than by holding `Todo` values, and the actual
`Todo` structs are looked up from the store at use time. Identity travels as the
stable key; the mutable data is always re-fetched. (The single-row branch still
hands the captured `todo` to the store, which is acceptable because those methods
re-query by `todo.id` inside the `write` and capture prior state fresh at call
time — but the id-keyed lookup is the robust pattern, and the one to reach for when
in doubt.)

---

## Reading

- [`UndoManager`](https://developer.apple.com/documentation/foundation/undomanager)
  — the action/inverse stack
- [`registerUndo(withTarget:handler:)`](https://developer.apple.com/documentation/foundation/undomanager/registerundo(withtarget:handler:))
  — register an inverse; note the unowned target
- [`isUndoing`](https://developer.apple.com/documentation/foundation/undomanager/isundoing)
  / [`isRedoing`](https://developer.apple.com/documentation/foundation/undomanager/isredoing)
  — how the manager routes a registration to the undo vs. redo stack
- [`@Environment(\.undoManager)`](https://developer.apple.com/documentation/swiftui/environmentvalues/undomanager)
  — the window's undo manager, surfaced to views
- [`setActionName(_:)`](https://developer.apple.com/documentation/foundation/undomanager/setactionname(_:))
  — name an action so the Edit menu reads "Undo Complete Todo" (NerfJournal does
  not currently use this — see Exercise 4)

---

## Code Tour

### `PageStore.swift` lines 512–518: `scheduleUndo`

The whole adapter, six lines. Read `withTarget: self`, the `Task { @MainActor }`,
and the `try?` together — each maps to a bullet in "The `scheduleUndo` dance."

### `PageStore.swift` lines 75–100: `completeTodo` / `uncompleteTodo`

The smallest inverse pair. Confirm the four-beat shape, and that the undo is
registered only after the `write` returns. Note each calls the *other* — the
inverse is ordinary functionality.

### `PageStore.swift` lines 289–298 and 413–420: `deleteTodo` and `restoreTodo`

The identity argument in code. Focus on `var restored = todo; try restored.insert(db)`
and why the captured `todo` still carries id `42`. Contrast with `addTodo` (lines
201–217), which inserts with `id: nil`.

### `PageStore.swift` lines 165–186: `bulkDelete` / `restoreBulkTodos`

One `write` for atomicity, one `scheduleUndo` for a single undo step. Then lines
314–332 (`setBulkCategory`) for the `todos + futureTodos` capture, and the two
"no redo" comments at lines 315 and 347.

### `JournalView.swift` lines 940–943: fresh lookup in the context menu

`affectedTodos = store.todos.filter { ... }` built at menu-present time. Note the
selection is carried as `Set<Int64>` ids, not `Todo` values.

---

## Exercises

**1.** `completeTodo` registers its undo *after* the `dbQueue.write` succeeds.
Suppose you moved `scheduleUndo` to *before* the write. Describe a concrete
sequence where Cmd-Z then reverses something that never happened.

**2.** `restoreTodo` does `var restored = todo; try restored.insert(db)`. Rewrite
it (in your head) to instead create a new todo with the same fields but `id: nil`.
Name two things that break, and tie each to a specific line elsewhere in the app.

**3.** `bulkDelete` wraps its loop in a single `dbQueue.write`. If you instead
called `deleteTodo` once per selected todo in a loop, you'd get N transactions and
N undo registrations. What does Cmd-Z do in that version, and how is it worse for
the user?

**4.** `UndoManager` has `setActionName(_:)`, which makes the Edit menu read "Undo
Complete Todo" instead of a bare "Undo." NerfJournal never calls it. Where in the
four-beat shape would a call go, and what would you name a `setBulkCategory`
action so it reads well for both one and many todos?

**5.** The "no redo" behavior comes from the `Task` in `scheduleUndo` deferring the
inverse past the window where `isUndoing` is true. Sketch a version of
`scheduleUndo` that would let redo work. What new problem do you introduce by
making the undo handler run its database work synchronously, given that the work
is `async` and `@MainActor`-isolated?
