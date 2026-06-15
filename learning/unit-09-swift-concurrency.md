---
title: "Unit 9: Swift Concurrency"
nav_order: 90
---

# Unit 9: Swift Concurrency

## Introduction

Several earlier units have leaned on concurrency without quite naming it. Unit 4
noted the stores are `@MainActor`. Unit 7 described `await db.dbQueue.write { … }`
as "the actor-crossing seam" and said value types are "what make the hand-off
clean." Unit 8's `scheduleUndo` did "the `Task { @MainActor }` dance." This unit
pays those debts: it explains the model those phrases come from, precisely enough
that you can predict what the compiler will and won't allow.

Swift's concurrency is a *compile-time* data-race prevention system. Like Rust's
`Send`/`Sync` and borrow checker, it refuses to build code that could race —
rather than, like Perl or pre-2021 Swift, letting you write the race and hoping a
code review or a crash catches it. The cost is that you must tell the compiler
where your data lives (which *isolation domain* owns it), and the compiler holds
you to it.

NerfJournal is a good specimen because it has exactly **two** isolation domains
and no custom actors, so the whole story fits in your head:

- the **main actor**, which owns every store's `@Published` UI state, and
- GRDB's **`DatabaseQueue`**, which owns the SQLite connection.

Everything interesting in this unit is about how work crosses between those two
safely, and what to do at the ragged edges — the C callbacks and notification
closures — where the compiler can't see the isolation you know is there.

The relevant docs are the Swift book's
[Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
chapter and the [`MainActor`](https://developer.apple.com/documentation/swift/mainactor),
[`Sendable`](https://developer.apple.com/documentation/swift/sendable), and
[`Task`](https://developer.apple.com/documentation/swift/task) references.

---

## `async`/`await`: linearizing the callback

Before structured concurrency, a database read that updates the UI looked like a
pyramid of completion handlers:

```swift
// the old way (not NerfJournal's)
dbQueue.asyncRead { result in
    let todos = try? result.get()...
    DispatchQueue.main.async {
        self.todos = todos          // hop back to main by hand
    }
}
```

[`async`/`await`](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
flattens that. An `async` function can *suspend* at an `await` — yielding the
thread to other work — and resume later, possibly on a different thread, with the
code after the `await` reading like ordinary straight-line code:

```swift
func loadIndex() async throws {
    let dates = try await db.dbQueue.read { db in
        try JournalPage.order(Column("date")).fetchAll(db).map(\.date)
    }
    pageDates = Set(dates)            // resumes on the main actor
}
```

A word on that `db in`: it is the closure's *parameter*, not a special piece of
isolation syntax. `read`/`write` run the closure on the `DatabaseQueue`'s own
serial queue — that queue *is* the isolation domain — and pass in `db`, a GRDB
[`Database`](https://swiftpackageindex.com/groue/grdb.swift/documentation/grdb/database)
connection handle, as the capability you use to issue queries *while you are inside
that domain*. It is scoped to the closure: GRDB expects you not to stash `db`
somewhere and use it after the closure returns, because by then you are no longer
on the queue. So the domain is established by *where the closure runs*; `db` is just
the access token you are handed for the duration. (The aside below makes the
analogy to an `actor` explicit.)

`await` is not "block until done." It's "I might suspend here; the runtime is free
to do other things until my result is ready." The function is `async`, so it can
only be *called* from another `async` context or from a `Task` — which is why view
code wraps these calls in `Task { … }` (more below). `throws` composes with it
exactly as you'd expect: `try await`.

The key mental shift from Perl, where there is no language-level async at all, and
from callback-style code: the thread that runs the code *after* the `await` is not
guaranteed to be the thread that ran the code before it. What *is* guaranteed —
and this is the whole point of actor isolation — is the *actor*.

---

## `@MainActor`: isolation, not "the main thread"

Every store is declared `@MainActor`:

```swift
@MainActor
final class PageStore: ObservableObject {
    @Published var page: JournalPage?
    @Published var todos: [Todo] = []
    // ...
}
```

It's tempting to read `@MainActor` as "runs on the main thread," and that's the
runtime effect, but the *useful* reading is **isolation**: the main actor is a
[global actor](https://developer.apple.com/documentation/swift/mainactor) — a
single serial executor — and everything annotated with it belongs to one
isolation domain. The compiler then guarantees that this domain's mutable state is
only ever touched from within the domain. No two threads can be inside the main
actor at once, so its state cannot be raced.

Concretely, marking the whole class `@MainActor` means:

- Every stored property and method is main-actor-isolated. You cannot read
  `pageStore.todos` or call `pageStore.completeTodo(...)` from a background thread
  without `await`ing the hop onto the main actor — the compiler rejects it.
- Therefore the `@Published` properties — which SwiftUI requires be mutated on the
  main thread — *cannot* be mutated off it. The annotation turns a runtime rule
  ("update `@Published` on main") into a compile-time guarantee.

This is why you'll never find a `DispatchQueue.main.async { self.todos = … }` in
the stores. The isolation makes it unnecessary: if you're in a store method,
you're already on the main actor; the assignment is safe by construction.

NerfJournal uses no custom `actor` types. The only shared mutable UI state worth
protecting lives on the main actor anyway (it drives the views), and the *other*
shared state — the SQLite connection — is already serialized by GRDB's
`DatabaseQueue` (Unit 7). Two serialization domains, one of them off-the-shelf, no
hand-written actors required.

### Aside: what a custom actor would look like

Because NerfJournal never needs one, the unit hasn't yet shown the feature that
gives the whole model its name. An [`actor`](https://developer.apple.com/documentation/swift/actor)
is a reference type that defines its *own* isolation domain: its stored properties
are protected the same way the main actor protects the stores, but the domain is
private to that one instance rather than global. A sketch:

```swift
actor Counter {
    private var value = 0                // isolated to this instance

    func increment() { value += 1 }      // runs in the actor's domain
    func current() -> Int { value }
}
```

From *outside*, the actor's members are reached with `await`, because the call may
have to wait for the actor to be free:

```swift
let counter = Counter()
await counter.increment()                // hop into the actor's domain
let n = await counter.current()          // await again
```

*Inside* the actor's own methods there is no `await` to touch `value` — you are
already in its domain, exactly as a store method touches `todos` directly. The
compiler guarantees no two tasks are inside `Counter` at once, so `value += 1`
cannot race, with no lock written by hand. (`@MainActor` is simply this same idea
hoisted to a *global* actor that many types can share, rather than one instance's
private domain.)

That is precisely the service `DatabaseQueue` performs for the SQLite connection:
serialize all access through one domain, entered with `await` from outside. GRDB
predates Swift's actors and implements it with a dispatch queue rather than the
`actor` keyword, but conceptually `dbQueue.read { db in … }` *is* a call into an
actor-like domain — which is why the `db` handle is valid only inside it, just as
`value` is valid only inside `Counter`. NerfJournal gets one isolation domain from
the language (`@MainActor`) and one from a library (`DatabaseQueue`), so it never
declares an `actor` of its own. If it grew shared mutable state belonging to
*neither* the UI nor the database — an in-memory cache written from several tasks,
say — a custom `actor` is the tool it would reach for.

---

## Crossing the seam: what `await db.dbQueue.write` actually enforces

Here is a complete mutation, with the isolation annotations made explicit in
comments:

```swift
func completeTodo(_ todo: Todo, undoManager: UndoManager? = nil) async throws {
    // on the main actor here
    let ending = TodoEnding(date: defaultEndingDate, kind: .done)
    try await db.dbQueue.write { db in
        // inside a @Sendable closure, running on GRDB's background queue —
        // NOT on the main actor
        try Todo.filter(Column("id") == todo.id)
                .updateAll(db, [Column("ending").set(to: ending)])
    }
    // back on the main actor here
    scheduleUndo(with: undoManager) { store in
        try await store.uncompleteTodo(todo, undoManager: undoManager)
    }
    try await refreshContents()
}
```

The seam is the `write` call, and GRDB's signature is what makes it safe. Its real
declaration (verified in the GRDB source) is, in essence:

```swift
func write<T: Sendable>(_ updates: @Sendable (Database) throws -> T) async throws -> T
```

Two `Sendable` constraints carry the entire safety argument:

- **The closure is `@Sendable`.** A
  [`@Sendable`](https://developer.apple.com/documentation/swift/sendable) closure
  may only capture values that are safe to move to another isolation domain. So the
  closure that runs on the background queue *cannot* capture or touch the main
  actor's mutable state. Try to write `self.todos = []` inside that `write` block
  and the compiler stops you: `self` is main-actor-isolated, the closure is not.
  This is precisely why you never see UI state mutated from inside a database
  block — it isn't a convention, it's unrepresentable. What the closure *does*
  capture here — `ending` and `todo.id` — are value types, hence `Sendable`, hence
  fine to copy across.
- **The return type is `Sendable`.** Whatever the closure hands back has to be safe
  to ship to the main actor when the `await` resumes. `[Todo]`, `[Note]`, `Set<Date>`
  — NerfJournal's records are structs of value types, so they're implicitly
  `Sendable`, and they cross back as independent copies. This is the concrete
  meaning of Unit 7's "value semantics are what make the hand-off clean": there is
  no shared mutable buffer straddling the boundary, so there's nothing to race.

So the pattern that recurs in every store method — capture some `Sendable` values,
`await` a database block that returns more `Sendable` values, assign them to
`@Published` properties back on the main actor — is not stylistic. It's the only
shape the type system permits. The `await` is where the main actor lets go; the
`Sendable` checks police what may travel in each direction.

`JournalStore.selectDate` makes the "assign back on the main actor" half vivid: it
fetches a page, its todos, and its notes in *one* `read`, then assigns all three
`@Published` properties in a row after the `await`. The comment explains the payoff
— doing it synchronously after a single suspension lets SwiftUI coalesce the change
into one view pass instead of animating through intermediate states. The single
`await` is also the single moment the UI could observe a half-updated store; doing
all the reads inside it and all the writes after it keeps that window shut.

---

## `Task`: starting async work from a synchronous place

View bodies, button actions, and `init`s are synchronous. To call an `async` store
method from one, you open a [`Task`](https://developer.apple.com/documentation/swift/task):

```swift
Button("Complete") {
    Task { try? await store.completeTodo(todo, undoManager: undoManager) }
}
```

A `Task` is a unit of asynchronous work that starts running immediately and runs
*concurrently* with the code that created it. The button action returns at once;
the `await`ed work happens on its own. A `Task` created inside a `@MainActor`
context inherits the main actor, so `store.completeTodo` runs with the isolation it
requires — no explicit hop needed.

The `try?` is the same pragmatic floor discussed in Unit 8: a UI action has nowhere
to surface a thrown error, so it's discarded. Worth seeing plainly rather than
glossing — it's a deliberate choice, and a place a more elaborate app would route
the error to an alert.

### The notification-observer pattern

The stores subscribe to `NotificationCenter` in their `init`s (Unit 6). The
observer closure is the textbook case of needing a `Task`:

```swift
NotificationCenter.default.addObserver(
    forName: .nerfJournalDatabaseDidChange, object: nil, queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self else { return }
        try? await self.loadIndex()
        self.selectedDate = nil
        // ...
    }
}
```

Three things to read carefully:

- **`Task { @MainActor in … }`.** The observer closure is `@Sendable` and *not*
  main-actor-isolated (it could, in principle, be called from anywhere). But
  `loadIndex()` is `async` and the property assignments are main-actor state. So the
  closure opens a `Task` explicitly pinned to `@MainActor`, which both gives it an
  `async` context to `await` in *and* the isolation to touch the store. We'll
  contrast this with `assumeIsolated` next — the choice between them is the crux of
  the unit.
- **The double `[weak self]`.** Both the outer observer closure and the inner `Task`
  capture `self` weakly. The outer one matters because `NotificationCenter` holds the
  observer closure for the app's lifetime; a strong capture would keep the store
  alive forever. The inner one matters because the notification might fire and
  schedule the `Task` just as the store is being torn down; `guard let self else
  { return }` bails cleanly if it's gone by the time the task runs.
- **`try?` again.** A failed reload from a background notification has nowhere to go,
  so it's swallowed.

---

## The ragged edge: `MainActor.assumeIsolated`

`Task { @MainActor }` is the right tool when you have async work to do or are
willing to take an extra scheduling hop. But sometimes you are *already* on the main
thread, the compiler just can't prove it, and you need to run main-actor code
*synchronously, right now* — no hop. That is what
[`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:))
is for, and `AppDelegate` (itself `@MainActor`) uses it twice.

The first is in the Carbon global-hot-key handler. The callback is a bare C
function pointer — about as far outside Swift's isolation model as you can get:

```swift
InstallEventHandler(GetApplicationEventTarget(),
    { (_, _, userData) -> OSStatus in
        guard let userData else { return noErr }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { delegate.showQuickNotePanel() } }
        return noErr
    },
    1, [eventSpec], Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
```

`showQuickNotePanel()` is main-actor-isolated, but the C callback has no isolation
at all and can't `await`. The code does the hop *itself* with
`DispatchQueue.main.async` — which genuinely puts the work on the main thread — and
then `MainActor.assumeIsolated` tells the compiler "we are demonstrably on the main
thread now; let me call main-actor code synchronously." 

The second is the `didBecomeActiveNotification` observer, which must call
`makeKeyAndOrderFront` and clean up `activationToken` *synchronously* during the
activation handoff (the comment explains the multi-display race it's threading):

```swift
NotificationCenter.default.addObserver(
    forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
) { [weak self, weak p] _ in
    MainActor.assumeIsolated {
        if let token = self?.activationToken { … }
        p?.makeKeyAndOrderFront(nil)
    }
}
```

### `assumeIsolated` vs. `Task { @MainActor }` — choosing correctly

This is the distinction to take away from the unit. Both end up running code on the
main actor; they differ in *when* and at *what risk*:

| | `Task { @MainActor in … }` | `MainActor.assumeIsolated { … }` |
|---|---|---|
| Timing | Schedules work to run *later* (a hop) | Runs *now*, synchronously |
| Can `await`? | Yes — it's an async context | No — body is synchronous |
| If you're not on main | Safe: it hops on | **Traps** (crashes): it's an assertion |
| Use when | You have async work, or a hop is fine | You're provably on main and need it *now* |

The stores use `Task { @MainActor }` because their observer work is `async`
(`await self.loadIndex()`) — `assumeIsolated` couldn't `await` it, and an extra hop
is harmless for a background reload. `AppDelegate` uses `assumeIsolated` because its
work is synchronous window manipulation that must happen immediately, without
yielding — and because it can *establish* the main-thread guarantee first
(`DispatchQueue.main.async`, or `queue: .main` on the observer) so the assertion is
sound.

That last clause is the honest caveat: `assumeIsolated` is an *assertion*, not a
proof. It converts "I, the programmer, know this runs on the main thread" into a
runtime trap if you're wrong. It's only as safe as the invariant feeding it — here,
that `queue: .main` and `DispatchQueue.main.async` really do deliver main-thread
execution, which they do. Reach for it only when you can point to *why* the thread
is guaranteed; otherwise take the `Task` hop and let the runtime make it true
instead of betting that it already is.

---

## How this maps to Rust, and to Perl

For a Rust programmer the analogy is close and worth drawing precisely:

- **`Sendable` ≈ `Send`.** Both mark a type as safe to move across threads /
  isolation domains, and both are inferred for types built entirely from
  conforming parts (Swift auto-synthesizes `Sendable` for a struct of `Sendable`
  members, much as Rust auto-derives `Send`). Swift folds Rust's `Sync` ("safe to
  share by `&`") into the same `Sendable` concept rather than splitting it out;
  reference types earn `Sendable` only by being immutable or internally synchronized
  (e.g. an `actor`, or GRDB's internally-locked `DatabaseQueue`).
- **Actor isolation ≈ the borrow checker's job, different mechanism.** Rust prevents
  data races by forbidding aliased mutable access at compile time; Swift prevents
  them by pinning mutable state to an actor and forbidding cross-actor access except
  through `await`. Different tools, same guarantee: *the compiler will not let you
  write the race.*
- **`@MainActor` ≈ a designated single-threaded executor** that certain data is
  pinned to — there is no std Rust equivalent, but it plays the role that "only ever
  touch the GUI from the UI thread" plays everywhere, now enforced by types instead
  of by discipline.

For Perl the comparison is mostly absence: core Perl offers no compile-time data
race protection, `threads` are heavyweight and discouraged, and shared state is
managed by convention and `:shared` variables rather than by the type system. The
thing to internalize coming from Perl is that in Swift the concurrency rules are
not advice — code that violates them does not compile.

---

## Reading

- [Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
  — the Swift book chapter; `async`/`await`, tasks, actors
- [`MainActor`](https://developer.apple.com/documentation/swift/mainactor)
  — the global actor the stores live on
- [`MainActor.assumeIsolated`](https://developer.apple.com/documentation/swift/mainactor/assumeisolated(_:file:line:))
  — assert (don't schedule) main-actor isolation
- [`Sendable`](https://developer.apple.com/documentation/swift/sendable)
  — the marker for "safe to cross isolation domains"
- [`Task`](https://developer.apple.com/documentation/swift/task)
  — start async work from a synchronous context
- [Migrating to Swift 6](https://www.swift.org/migration/documentation/migrationguide/)
  — the data-race-safety model in depth, if you want the full rules

---

## Code Tour

### `PageStore.swift` line 4 and lines 75–87: isolation and a seam

The `@MainActor` on the class, then `completeTodo`. Trace the three regions: main
actor before the `write`, `@Sendable` background closure inside it, main actor
again after. Confirm nothing inside the `write` touches `self`.

### `JournalStore.swift` lines 47–89: one read, then synchronous assignment

`loadIndex` and `selectDate`. Note `selectDate` fetches page + todos + notes in a
single `read` and assigns all the `@Published` properties together after the lone
`await`. Read the comment about coalescing into one view pass.

### `JournalStore.swift` lines 16–39: the observer `Task` pattern

The two `NotificationCenter` observers. Read the `Task { @MainActor [weak self] }`,
the double weak capture, and why an async reload needs the `Task` rather than
`assumeIsolated`.

### `AppDelegate.swift` lines 31–35 and 90–101: the two `assumeIsolated` sites

The Carbon C-callback hop (`DispatchQueue.main.async { MainActor.assumeIsolated { … } }`)
and the activation observer. For each, identify the invariant that makes the
assertion sound — what guarantees we're on the main thread before `assumeIsolated`
runs.

### `AppDatabase.swift` lines 248–299: the other isolation domain

`exportData`/`importData` show GRDB's `read`/`write` as `async` calls. This is the
domain boundary the stores `await` across; the `DatabaseQueue` serializes here so
no custom actor is needed.

---

## Exercises

**1.** Inside the `db.dbQueue.write { db in … }` block of `completeTodo`, add the
line `self.todos = []`. Before trying it: what does the compiler say, and which
word in GRDB's `write` signature is responsible?

**2.** The stores' notification observers use `Task { @MainActor in … }`.
`AppDelegate`'s use `MainActor.assumeIsolated { … }`. Swap one for the other in your
head: why can't `loadIndex`'s observer use `assumeIsolated`, and what would happen
at runtime if `AppDelegate`'s activation observer used a `Task` instead (think about
the multi-display race the comment describes)?

**3.** `JournalStore.selectDate` does all its database reads in one `read` and all
its `@Published` assignments after it. Suppose you split it into three separate
`await`ed reads, assigning after each. Nothing races (it's all on the main actor) —
so what *does* get worse, and for whom?

**4.** `Sendable` is auto-synthesized for `Todo` but must be earned by reference
types. Why is GRDB's `DatabaseQueue` allowed to be `Sendable` even though it's a
class with mutable state? Why is `PageStore` *not* `Sendable` (and doesn't need to
be)?

**5.** `MainActor.assumeIsolated` traps if you're wrong about being on the main
thread. Construct a plausible refactor of the Carbon callback that removes the
`DispatchQueue.main.async` and calls `assumeIsolated` directly. Why would it
sometimes work in testing and then crash in the field?
