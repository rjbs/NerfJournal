---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 10: AppKit Interoperability and the Quick-Entry Panel

### What is Combine? Is it just "the pub/sub mechanism for Swift"?

That's the right skeleton but it undersells the framework. Combine (2019) is
Apple's **declarative reactive-streams** framework. Pub/sub is the structure — a
[`Publisher`](https://developer.apple.com/documentation/combine/publisher) emits
values over time and a `Subscriber` receives them — but the value is the composable
**operator chain** in between (`map`, `filter`, `debounce`, `removeDuplicates`,
`dropFirst`, `combineLatest`). So: lazy, composable pipelines over asynchronous
sequences of values, not merely a notification bus. If you know RxSwift / ReactiveX,
it's Apple's house version of that.

The pieces:
- **`Publisher`** — produces values plus one completion (finished or failure).
- **`Subscriber`** — consumes them; `sink { }` is the everyday one.
- **`Subscription`** — the live connection, demand-driven (backpressure): the
  subscriber signals how many values it wants, so it's a *pull* model underneath.
- **[`AnyCancellable`](https://developer.apple.com/documentation/combine/anycancellable)**
  — an RAII drop-guard; when the token deallocates, the subscription is torn down.
  This is exactly why Unit 10's pipeline ends in `.store(in: &cancellables)`.

Rust mapping (clean): `Publisher` ≈ `Stream`; the operators ≈ `StreamExt`
combinators; `.sink {}` ≈ `.for_each`; `AnyCancellable`'s drop-cancels behavior ≈ a
drop-guard / `JoinHandle` whose `Drop` aborts; the demand-driven `Subscription` ≈
the `poll_next` pull model.

**Why the curriculum covers it thinly (on purpose):** there's no standalone Combine
unit. It appears implicitly in Unit 4 — `@Published` *is* a publisher and
`ObservableObject` emits through `objectWillChange`, both Combine types — and
explicitly in Unit 10's panel-resize pipeline, which states the point directly:
"Combine is not a new framework here, it's the one you already met." You've been
using Combine since Unit 4 without it being named.

**Worth knowing — Combine is in quiet maintenance.** Essentially no new surface
since 2019. Apple steered its use cases toward async/await + `AsyncSequence` (for
one-shot and streaming async work) and the **Observation** framework
([`@Observable`](https://developer.apple.com/documentation/observation), macOS 14+)
as the modern replacement for `ObservableObject`/`@Published`. NerfJournal targets
macOS 14+ but still uses the `ObservableObject` style — a conservative, fine choice.
Starting fresh today you'd reach for `@Observable` first and treat Combine as the
drop-to-it tool for genuine event-stream plumbing — like the KVO `publisher(for:)`
bridge in Unit 10, which has no async/await equivalent.

### What *is* an AppDelegate? The text talks about it in Units 5, 9, and 10 but never defines it.

Correct — it's assumed, not explained. The units cover the SwiftUI bridge
(`@NSApplicationDelegateAdaptor`) and what NerfJournal's `AppDelegate` *does*, but
they lean on phrases like "the *classic* `NSApplicationDelegate`" and "the delegate
seat that was always there," which only land if you already know the Cocoa delegate
pattern. It's not a Swift or Carbon concept; it's a NeXTSTEP/Objective-C convention,
so neither a Swift nor a systems background hands it to you.

**The delegate pattern** is Cocoa's alternative to subclassing for customizing a
framework object's behavior. Rather than making you subclass `NSApplication`, the
framework holds a reference to a *separate* object — its **delegate** — and calls
well-known methods on it at interesting moments. The framework owns
*what-happens-when*; the delegate supplies *what-to-do*.

- **Rust analogy:** a trait object handed to a library. `NSApplicationDelegate` is
  the trait; your `AppDelegate` is the concrete impl; `NSApplication` stores it as
  `dyn NSApplicationDelegate` and calls back into it. The protocol's optional
  methods behave like trait methods with default impls you may override or ignore.
- **Perl analogy:** a handler object with a known interface that you register with a
  framework, which then calls `$delegate->applicationDidFinishLaunching(...)` at the
  right moment — duck-typed callbacks.

**The *application* delegate** is the headline use of that pattern. Each app has one
`NSApplication` (`UIApplication` on iOS) representing the process; its delegate is
where the **app lifecycle** lands: `applicationDidFinishLaunching`,
`applicationWillTerminate`, dock-icon reopen, files-dropped-on-the-app, etc.
Historically — every Cocoa app before SwiftUI — the AppDelegate was *the* root
object of the program and the nearest thing Cocoa had to `main()`; tutorials started
by putting startup code in `applicationDidFinishLaunching`.

SwiftUI's [`App`](https://developer.apple.com/documentation/swiftui/app) protocol
replaced it as the entry point and folded most of the lifecycle into scenes and
property wrappers, which is why a SwiftUI app can omit an AppDelegate entirely.
[`@NSApplicationDelegateAdaptor`](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)
is the trapdoor back to it for the process-global things SwiftUI still doesn't model
(here: the global hot key).

References:
- [`NSApplicationDelegate`](https://developer.apple.com/documentation/appkit/nsapplicationdelegate) — the protocol and its full lifecycle method list
- [Delegation (Cocoa Encyclopedia)](https://developer.apple.com/library/archive/documentation/General/Conceptual/CocoaEncyclopedia/DelegatesandDataSources/DelegatesandDataSources.html) — Apple's canonical writeup of the pattern
- [Managing your app's life cycle](https://developer.apple.com/documentation/uikit/app_and_environment/managing_your_app_s_life_cycle) — clearest narrative of what the app delegate is *for*
