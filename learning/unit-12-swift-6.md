---
title: "Unit 12: Swift 6 — Strict Concurrency by Default"
nav_order: 120
---

# Unit 12: Swift 6 — Strict Concurrency by Default

## Introduction

Unit 9 described Swift's concurrency model: isolation domains, `Sendable`, the main
actor, and the escape hatches at the ragged edges. It described the model as a
compile-time guarantee, and so it is, but only to the degree the compiler is asked to
check. Until this point NerfJournal was built in **Swift 5 language mode**, where much of
that checking is optional and most `Sendable` violations compile without complaint. The
model was there; the compiler was enforcing a subset of it.

NerfJournal now builds in **Swift 6 language mode**, where the checking is complete and
every data-race risk the compiler can see is an error. This unit covers what that means,
the switches that control it, and the concurrency features the new sync-engine code
uses that Unit 9 never had a reason to show: real `actor` types, `AsyncStream` with
`for await`, `isolated deinit`, and `Task.detached`.

One fact frames the whole unit. When the app moved to Swift 6 mode, exactly **one line of
app source** had to change: `DayClock`'s `deinit` became an `isolated deinit`. Everything
else already satisfied the stricter rules. That's not luck. The shapes Unit 9 described
(stores pinned to the main actor, database work in `@Sendable` closures, value-type
records crossing the boundary) are the shapes Swift 6 demands, so code written that way
migrates almost for free. The shared NerfCore package did need one mechanical change,
explicit `Sendable` on its public types, and the reason for that is a lesson about module
boundaries that this unit and the next both use.

The relevant references are the Swift book's
[Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
chapter, Swift.org's
[migration guide](https://www.swift.org/migration/documentation/migrationguide/), and the
[`Actor`](https://developer.apple.com/documentation/swift/actor) and
[`AsyncStream`](https://developer.apple.com/documentation/swift/asyncstream) references.

---

## Language mode is not compiler version

The first distinction to get straight: the Swift **compiler version** and the Swift
**language mode** are separate knobs. A Swift 6.2 compiler can compile code in Swift 5
mode or Swift 6 mode. The language mode decides which rules apply. The compiler
version decides which rules exist.

Swift 6 mode turns the concurrency checks from opt-in warnings into errors. In Swift 5
mode a `Sendable` violation is usually silent, or a warning if you raise the
`SWIFT_STRICT_CONCURRENCY` level. In Swift 6 mode it stops the build. Rust readers can
think of it as an edition: `edition = "2021"` doesn't pick your `rustc`, it picks which
rules your crate is held to, and you can migrate a crate at a time.

Each of NerfJournal's three build products sets its mode in its own way:

- **The app** is an Xcode target, so it uses build settings in `project.pbxproj`:
  ```
  SWIFT_APPROACHABLE_CONCURRENCY = YES;
  SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor;
  SWIFT_VERSION = 6.0;
  ```
- **NerfCore** is a Swift package whose manifest begins `// swift-tools-version: 6.0`. A
  package built with tools version 6 or later defaults to Swift 6 language mode, so
  nothing else needs saying.
- **The CLI** is also a package, at tools version 6.2, with two features turned on by
  name:
  ```swift
  swiftSettings: [
      .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
      .enableUpcomingFeature("InferIsolatedConformances"),
  ]
  ```

The three settings differ on purpose. The rest of the unit explains each one.

---

## Default actor isolation: the app is main-actor unless it says otherwise

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Swift Evolution proposal SE-0466, new in
Swift 6.2) changes the default for every declaration in the module that doesn't state
its own isolation. Without it, an unannotated type or function is **nonisolated**: it
belongs to no actor and can be called from anywhere. With it, an unannotated
declaration is **`@MainActor`**, as if you had written the attribute yourself.

For a UI app this is the right default, because almost everything in it is UI. Views,
stores, the app delegate, and the export helpers all run on the main actor anyway.
Under the old default, every one of them needed an annotation, and forgetting one
produced a type the compiler treated as callable from any thread. Under the new
default, forgetting is safe. The code that has to run elsewhere is the exception, and
it opts out explicitly with `nonisolated`, or by living in another module (more on
that below).

One visible consequence: `PageStore`, `CategoryStore`, `DayClock`, and `AppDelegate`
all still begin with an explicit `@MainActor`. Under the module default these
annotations are redundant. They're harmless, and they still say something useful to a
human reading one file in isolation, but the compiler would infer them anyway.

The setting is per module, which is why NerfCore and the CLI don't use it.

**NerfCore** is a library, called from the app's main actor and from the CLI's
nonisolated commands. A library that defaulted its types to `@MainActor` would force
every caller onto the main actor to use it, which makes no sense for a command-line
program and would make `await` mandatory for calls that don't need it. NerfCore's mutable
shared state lives in actors of its own (`JournalSync`, below), and its data types are
plain `Sendable` values that can go anywhere.

**The CLI** has a more mechanical reason, and it comes from swift-argument-parser. The
library declares its root protocol as
`public protocol ParsableArguments: Decodable, _SendableMetatype` (the underscore is in
the source). Requiring `SendableMetatype` tells the compiler that a conforming *type*
must be usable from any concurrency context, because the library's generated `main()`
creates and runs commands from a nonisolated context. A type conforming to such a
protocol doesn't take the module's main-actor default. So under a main-actor default,
the command structs would stay nonisolated while everything else in the module, the
helper functions in `TodoHelpers.swift` and the `Palette` enum, became `@MainActor`.
Every call from a command into its own module's helpers would then cross an actor
boundary. The build fails with errors like *main actor-isolated global function
'fetchTodayPage(_:date:)' cannot be called from outside of the actor*. You could fix
each one with an `await` or a `nonisolated`, but at that point you're annotating the
whole module to undo its own default. The CLI also has no shared mutable state for the
main actor to guard: each invocation runs one command and exits.

---

## Approachable concurrency: two rules that make the defaults kinder

`SWIFT_APPROACHABLE_CONCURRENCY = YES` is an Xcode setting that turns on a bundle of
*upcoming features*. These are rule changes that will become the default in a future
language mode, and you can opt into them now. Two of them matter here, and they are
the two the CLI enables by name, since a package has no single switch for the bundle.

**`NonisolatedNonsendingByDefault`** (SE-0461) changes where a nonisolated `async`
function runs. Under the Swift 6.0 rule, calling a nonisolated `async` function always
hops off the caller's actor onto the global concurrent executor, a background thread
pool. That hop is a boundary crossing, so every argument and result must be `Sendable`,
even when the caller had no wish to go anywhere. Under the new rule, a nonisolated
`async` function runs *on the caller's actor* by default. Called from the main actor, it
stays on the main actor; called from nowhere in particular, it runs nowhere in
particular. If you really want a function to move off the caller's actor, you mark it
`@concurrent`. The effect is that "nonisolated" stops meaning "runs in the background"
and goes back to meaning what it says: *this function has no actor of its own*.

**`InferIsolatedConformances`** (SE-0470) lets a main-actor type conform to a protocol
*on the main actor only*. Without it, a `@MainActor` struct conforming to, say,
`Equatable` must provide a nonisolated `==`, because the protocol doesn't know about
actors. With it, the compiler infers that the conformance itself is main-actor-isolated
and stops anyone using it from elsewhere. In a module whose default is `@MainActor`,
this is the difference between "every protocol conformance fights you" and "conformances
just work, inside the main actor."

Neither rule makes the checking weaker. They change defaults so that the code you'd
naturally write is the code that's correct. Swift's concurrency story spent 2021–2024
being technically sound and often exasperating, and approachable concurrency (Swift
6.2, 2025) is the language admitting that. A program could satisfy Swift 6.0's rules
and still be littered with `nonisolated` and `@Sendable` noise that bought no safety.
These features remove the need for most of it.

---

## Why public types need an explicit `Sendable`

The one mechanical change NerfCore needed:

```swift
public struct Todo: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64?
    public var title: String
    // ...
}
```

Unit 9 said that a struct made entirely of `Sendable` members is *implicitly* `Sendable`,
much as Rust auto-derives `Send`. That's true, with one exception that matters here:
**inference stops at `public`**. The compiler infers `Sendable` for internal and private
types, whose every use it can see. It won't infer it for a public type, because a public
type's `Sendable`-ness is part of its contract with *other modules*, and the compiler
won't make a promise on your behalf that you might break by adding a field next month.

So when the record types moved out of the app (where they were internal) into NerfCore
(where they are public), they lost their inferred `Sendable`. The app's Swift 6 build
then refused to pass a `Todo` into a database closure or across an actor boundary. The
fix was to write `Sendable` on every public record type. That states, as API, what was
already true. Each is a value type over `Sendable` fields, so the compiler checks the
claim and accepts it.

This is the first of several ways a module boundary turns implicit facts into explicit
declarations. Unit 13 covers the rest.

---

## Real actors: `JournalSync` and `SyncEngine`

Unit 9 described NerfJournal as having exactly two isolation domains, the main actor and
GRDB's `DatabaseQueue`, and showed a toy `actor Counter` because nothing in the app
declared one. The sync engine adds two real ones.

Jinx's `SyncEngine` (in the separate Jinx package) is declared
`public actor SyncEngine<Store: SyncStore>`, generic over its storage backend. Its own
documentation comment states its contract: *it is an actor and never runs on the main
actor; everything it hands out is a `Sendable` value*. Inside, it holds exactly the
kind of state the aside in Unit 9 predicted would need an actor: a session, a sync
status, a set of types needing a fresh fetch, a per-type batch size it lowers after a
"request too large" error. That mutable bookkeeping is written by the background sync
loop, the UI, and the CLI. Pinning it to the actor means none of those writers can race.

NerfCore's `JournalSync` wraps the engine with the journal's specifics:

```swift
public actor JournalSync {
    public typealias Engine = SyncEngine<GRDBSyncStore>

    public nonisolated let engine: Engine
    public nonisolated let settings: SyncSettings
    nonisolated let writer: any DatabaseWriter
    private var fetchedListsOnce = false
    // ...
}
```

Two things to notice.

**`nonisolated let`.** An actor's properties are isolated to it, so reading one from
outside normally takes an `await`. But an immutable `let` of a `Sendable` type can't race:
nobody can write it after `init`, and the value is safe to share. Within the declaring
module, Swift lets you read such a property without `await`. **Across a module
boundary**, it won't unless the property is marked `nonisolated`. That marking is a
promise that the property will stay safe to read without `await`, which matters because
changing it would break callers in other modules. So `engine` and `settings` are
`public nonisolated let`, and the app can write `database.sync.engine` as a plain
synchronous property access. The `await` in `await database.sync.engine.changes()`
belongs to `changes()`, which runs inside the engine's actor. Getting hold of the engine
doesn't need one.

**`fetchedListsOnce` and reentrancy.** Here is the one piece of mutable state
`JournalSync` adds, and the method that uses it:

```swift
public func listIndex() async throws -> TaskListIndex {
    var index = TaskListIndex(objects: try await lists())
    if index.entries.isEmpty, !fetchedListsOnce {
        fetchedListsOnce = true
        try await engine.sync()
        index = TaskListIndex(objects: try await lists())
    }
    return index
}
```

Read it with one fact about Swift actors in mind: **an actor is not a lock held for a
whole method.** It's held only between suspension points. At every `await`, the actor
is released, and another call into the same actor may run before this one resumes. This
is called *reentrancy*, and it's the single most surprising thing about Swift actors for
anyone who knows mutexes.

So during `try await engine.sync()`, which may take a network round trip, a second call
to `listIndex()` can enter `JournalSync` and run. If the flag were set *after* the
`await`, that second call would see `fetchedListsOnce == false`, decide it too should
sync, and the engine would be asked to fetch twice. Setting the flag *before* the
suspension is what makes "sync at most once" hold under reentrancy. The cost is
visible too: the second caller sees the flag set and the lists still empty, and returns
an empty index without waiting for the first caller's sync to finish. The code chooses
"never sync twice" over "every caller waits for the first sync." Exercise 3 asks you to
judge that trade.

In Rust terms, a Swift actor is like a `tokio::sync::Mutex` around its state that is
automatically **released at every `.await` and re-acquired after it**. Rust programmers
avoid holding a guard across an `.await` for deadlock reasons. Swift actors never do it,
by design, so they can't deadlock on themselves, but any invariant spanning an `await` is
yours to protect, as `listIndex` does.

---

## `AsyncStream` and `for await`: change notifications as a sequence

Under the old app, when the CLI wrote to the database, it posted a
`DistributedNotificationCenter` message, and the stores ran a notification observer
that opened a `Task { @MainActor in … }` to reload (Unit 9's "notification-observer
pattern"). That machinery is gone. The engine now publishes every committed change as an
asynchronous sequence of values, and the stores consume it with a loop.

The producer side, in Jinx's `SyncEngine`:

```swift
public func changes() -> AsyncStream<ChangeSet> {
    let id = UUID()
    let (stream, continuation) = AsyncStream<ChangeSet>.makeStream()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
        Task { await self?.removeSubscriber(id) }
    }
    return stream
}

func emit(_ changeSet: ChangeSet) {
    guard !changeSet.isEmpty else { return }
    for continuation in subscribers.values {
        continuation.yield(changeSet)
    }
}
```

[`AsyncStream`](https://developer.apple.com/documentation/swift/asyncstream) is the
standard library's way to make an
[`AsyncSequence`](https://developer.apple.com/documentation/swift/asyncsequence) from
push-style events. `makeStream()` returns a pair: the stream, which the consumer
iterates, and a **continuation**, which the producer holds and calls `yield` on to push
a value. Each caller of `changes()` gets its own pair, and the engine keeps every
continuation in a dictionary so that `emit` can fan each change set out to all
subscribers. It's a broadcast channel built from single-consumer streams.

`onTermination` runs when the consumer stops iterating, whether its loop ends or its
task is cancelled. Its job is to remove the continuation from `subscribers` so the
engine stops yielding into a stream nobody reads. Note that `onTermination` is a
synchronous `@Sendable` closure, while `removeSubscriber` is isolated to the engine
actor. The closure can't `await`, so it starts a `Task` to make the hop. That's the same
shape as Unit 9's observer closure opening a `Task` to reach the main actor.

The consumer side, in `PageStore.init`:

```swift
changeTask = Task { [weak self] in
    let changes = await database.sync.engine.changes()
    for await change in changes {
        guard change.types[JournalSync.taskType.name] != nil
                || change.types[JournalSync.listType.name] != nil else { continue }
        try? await self?.refreshContents()
    }
}
```

**`for await`** iterates an async sequence: each pass suspends until the next value
arrives, then runs the body. While suspended it holds no thread and doesn't block the
main actor. The UI runs normally between changes. The loop ends when the stream
finishes or the enclosing task is cancelled.

**The `Task` inherits the main actor.** It's created inside `PageStore.init`, which is
main-actor-isolated, and a `Task` created in an isolated context inherits that
isolation. So the loop body runs on the main actor, and `refreshContents()` can assign
`@Published` properties directly. No `@MainActor` annotation on the `Task` is needed.

Compare `CategoryStore`, which has both kinds of listener side by side:

```swift
NotificationCenter.default.addObserver(
    forName: .nerfJournalDatabaseDidChange, object: nil, queue: .main
) { [weak self] _ in
    Task { @MainActor [weak self] in
        guard let self else { return }
        try? await self.load()
    }
}
changeTask = Task { [weak self] in
    let changes = await database.sync.engine.changes()
    for await change in changes {
        guard change.types[JournalSync.listType.name] != nil else { continue }
        try? await self?.load()
    }
}
```

The in-process notification survives for whole-database events (import, reset). Its
`Task` still says `@MainActor` explicitly, and there it isn't redundant: the closure
handed to `addObserver` is a `@Sendable` closure with no isolation of its own, even in a
main-actor-default module, so a `Task` created inside it has nothing to inherit. Where a
`Task` is created decides what it inherits. Two `Task {}` literals a few lines apart, in
the same initializer, get different isolation.

**`[weak self]` in a long-lived loop.** The task runs for the life of the store, so a
strong capture of `self` would keep the store alive forever: the store owns the task,
and the task would own the store. The weak capture breaks that cycle. Each
`self?.refreshContents()` briefly holds a strong reference for the duration of the call,
and otherwise the loop doesn't keep the store alive. That leaves the reverse problem. When
the store goes away, the loop must stop, or it keeps waiting on changes for a store that
no longer exists. That's the deinit's job.

---

## `isolated deinit`: cleaning up main-actor state

```swift
isolated deinit {
    changeTask?.cancel()
}
```

In Swift 6, a `deinit` is nonisolated by default even in a main-actor class. Deallocation
can happen on whatever thread released the last reference, and the language doesn't
promise to hop to the main actor first. A nonisolated `deinit` therefore can't touch
main-actor state that isn't `Sendable`. `isolated deinit` (SE-0371) asks the runtime
to run the deinitializer on the class's actor, hopping there if needed, so the body can
use isolated state freely.

`DayClock` is the case that forced the feature in. Its `deinit` invalidates a `Timer`,
and `Timer` is main-actor-bound and not `Sendable`. In Swift 5 mode that compiled
silently. In Swift 6 mode it's an error, and that was the one line of app source the
migration changed.

The stores use the same form to cancel their change tasks, and the chain of effects is
worth following once. `changeTask?.cancel()` marks the task cancelled. The `for await`
loop's pending wait on the `AsyncStream` returns `nil`, so the loop ends. The stream's
`onTermination` fires, which starts the `Task` that removes this subscriber from the
engine's dictionary. Every link is a standard-library behavior. Nothing in NerfJournal
hand-codes the teardown beyond the one `cancel()`.

---

## `Task.detached`: work that belongs to nobody

The engine's sync loop is started once, at launch, in `AppDelegate`:

```swift
private func startSync() {
    let sync = AppDatabase.shared.sync
    syncTask = Task.detached {
        await sync.engine.run()
    }
}
```

A plain `Task { … }` here would inherit the main actor, because `AppDelegate` is
main-actor code. That would still work: the closure would start on the main actor, hit
`await sync.engine.run()`, hop into the engine's actor, and stay there, releasing the main
actor for the whole time the loop runs. A
[`Task.detached`](https://developer.apple.com/documentation/swift/task)
inherits *nothing*: not the actor, not the priority, not task-local values. Its closure
is nonisolated from the first instruction.

The practical difference here is small. The useful thing is the signal. `Task.detached`
says this work has no relationship to the context that started it: it isn't
UI work, it shouldn't run at the user-interactive priority the main actor carries, and
it is meant to outlive any particular piece of UI. Reach for `detached` when that's true
and the plain `Task` otherwise. Plain `Task` is the right default far more often, because
inheriting the caller's actor is usually what you want.

---

## What stays the same

The ragged edges from Unit 9 are still ragged. The Carbon hot-key callback is still a
C function pointer that does `DispatchQueue.main.async { MainActor.assumeIsolated { … } }`.
`DayClock` adds three more `assumeIsolated` sites, for notification observers registered
with `queue: .main` and for a `Timer` scheduled on the main run loop. Swift 6 doesn't
make those boundaries visible to the compiler. It makes everything else checked, so
what remains unchecked is easier to find. `assumeIsolated` is still an assertion: you are
still promising something the compiler can't verify, and the runtime will trap if you
are wrong.

---

## How this maps to Rust, and to Perl

- **Language mode ≈ Rust edition.** Opt in per crate (per module), migrate one at a time,
  same toolchain either way.
- **Default actor isolation ≈ a single-threaded runtime's default.** The nearest Rust
  analogy is a `current_thread` Tokio runtime in which everything that touches the GUI
  must be on the one thread, except that Swift puts the rule into each declaration's type
  and lets you opt individual declarations out.
- **Public types lose inferred `Sendable` ≈ semver hygiene Rust leaves implicit.** Rust's
  auto traits *do* leak across crate boundaries: adding a `Rc` field to a public struct
  silently makes it `!Send` and breaks downstream crates, a well-known semver hazard.
  Swift closes that hole by refusing to infer the property for public types, and making
  you state it.
- **Actor ≈ a mutex released at every `.await`.** That reentrancy has no direct Rust
  equivalent, and it's the thing to keep in mind when an actor method spans a suspension.
- **`AsyncStream` + continuation ≈ a channel's receiver and sender.** `makeStream()` is
  `mpsc::channel()`. The receiver implements `Stream`, the sender is the continuation,
  `for await` is `while let Some(x) = rx.next().await`, and `onTermination` is the
  sender noticing the receiver was dropped.
- **`Task.detached` ≈ `tokio::spawn`; plain `Task` ≈ spawning onto the current local
  set.** The detached one carries no context with it.

For Perl the parallel is mostly absence, as in Unit 9. The closest thing to
`for await change in changes` is an event loop (`IO::Async`, `Mojo::IOLoop`, `AnyEvent`)
handing your callback each event. The difference is that Swift turns the callback into
a loop with ordinary control flow, and checks at compile time that the loop body touches
only state it's allowed to.

---

## Reading

- [Swift 6 migration guide](https://www.swift.org/migration/documentation/migrationguide/)
  — language mode, data-race safety, and incremental adoption
- [Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)
  — the Swift book chapter; read the sections on actors and on actor reentrancy
- [`Actor`](https://developer.apple.com/documentation/swift/actor) and
  [`Sendable`](https://developer.apple.com/documentation/swift/sendable)
- [`AsyncStream`](https://developer.apple.com/documentation/swift/asyncstream) and
  [`AsyncSequence`](https://developer.apple.com/documentation/swift/asyncsequence)
- [`Task.detached`](https://developer.apple.com/documentation/swift/task)
- Swift Evolution proposals, for the precise rules:
  [SE-0466](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
  (default actor isolation),
  [SE-0461](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0461-async-function-isolation.md)
  (nonisolated async functions run on the caller's actor),
  [SE-0470](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0470-isolated-conformances.md)
  (isolated conformances),
  [SE-0371](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0371-isolated-synchronous-deinit.md)
  (isolated `deinit`)

---

## Code Tour

### `NerfJournal.xcodeproj/project.pbxproj` lines 422–425

The three build settings, repeated per configuration. They're the whole of the app's
Swift 6 adoption apart from one `deinit`.

### `cli/Package.swift` lines 1 and 20–25; `NerfCore/Package.swift` line 1

The CLI's tools version and its two upcoming features, and NerfCore's tools version,
which by itself selects Swift 6 mode. Note what neither package sets: a default actor
isolation.

### `NerfCore/Sources/NerfCore/Models.swift` line 175

`public struct Todo: … Sendable`. Every public record type in this file carries the
same explicit conformance.

### `NerfCore/Sources/NerfCore/JournalSync.swift` lines 96–155

The `actor` declaration, the `public nonisolated let` properties, and `listIndex()`.
Find the `await` that reentrancy can slip through, and confirm the flag is set before it.

### Jinx: `Sources/Jinx/SyncEngine.swift` lines 84–105 and 178–199

In the separate Jinx repository. The generic actor and its mutable bookkeeping, then
`changes()`, `removeSubscriber`, and `emit`: the producer half of the stream.

### `NerfJournal/PageStore.swift` lines 19–43

The consumer half: the change-stream `Task` in `init`, its filter on change types, and
the `isolated deinit` that cancels it. Then `CategoryStore.swift` lines 18–42 for the
two listeners side by side, one `Task` annotated and one not.

### `NerfJournal/DayClock.swift` lines 13–48

The `isolated deinit` that Swift 6 required, and three `assumeIsolated` sites unaffected
by the migration.

### `NerfJournal/AppDelegate.swift` lines 26–32

`startSync()` and its `Task.detached`.

---

## Exercises

**1.** Remove `isolated` from `DayClock`'s `deinit` and build. Read the error and name
the non-`Sendable` thing the `deinit` is touching. Then do the same to `PageStore`'s
`deinit`. Does the build still fail? Explain the difference in terms of what each
`deinit` touches: a `Timer` in one case, a `Task` in the other.

**2.** Delete `Sendable` from `public struct Todo` in NerfCore and build the app. Where
does the first error appear, and in which module? Now imagine `Todo` were declared in
the app module, as it was before NerfCore, and explain why the same deletion would have
compiled.

**3.** In `JournalSync.listIndex()`, move `fetchedListsOnce = true` to *after*
`try await engine.sync()`. Describe two concurrent calls that now cause the engine to
sync twice. Then consider the code as written: what does the *second* caller get back
while the first is still syncing, and what does `defaultListId()` do with that? Is
"sync at most once" worth that behavior, or would you rather have every caller wait for
one shared sync? (Consider storing a `Task` in place of the `Bool`.)

**4.** In `CategoryStore.init`, delete the `@MainActor` from the `Task` inside the
`NotificationCenter` observer and build. Then delete nothing from the `changeTask`
`Task` a few lines down, which never had the annotation. Explain why one needs it and the
other doesn't, using only the rule "a `Task` inherits the isolation of the context it's
created in."

**5.** Temporarily set the CLI's package to a main-actor default by adding
`.defaultIsolation(MainActor.self)` to its `swiftSettings`, and build. The errors are
not on the commands' `run()` methods but on calls *inside* them, to `fetchTodayPage`,
`Palette.swatch`, and `Palette.hex`. Explain why the command structs stayed nonisolated
while those helpers became main-actor, starting from `ParsableArguments`'s declaration
in the swift-argument-parser checkout under `cli/.build/checkouts/`. Then list what you'd
have to change to make the build pass with the main-actor default, and decide whether
any of it would buy safety. (Restore `Package.swift` afterward.)

**6.** `AppDelegate.startSync()` uses `Task.detached`. Replace it with a plain
`Task { await sync.engine.run() }`. Trace which actor the closure starts on, where it
hops at the `await`, and whether the main actor is blocked while the sync loop runs.
Given the answer, argue for which spelling you'd keep.

**7.** `SyncEngine.changes()` hands every subscriber its own `AsyncStream`. Suppose
instead it returned one shared stream to all callers. `AsyncStream` is a
single-consumer sequence: it doesn't copy each value to every iterator, so with two
`for await` loops on one stream, at best each value reaches only one of them. What would
go wrong when both `PageStore` and `CategoryStore` subscribe, and how
does the per-subscriber dictionary avoid it?
