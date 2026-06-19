---
title: "Unit 10: AppKit Interoperability and the Quick-Entry Panel"
nav_order: 100
---

# Unit 10: AppKit Interoperability and the Quick-Entry Panel

## Introduction

Every unit so far has lived inside SwiftUI's world: views are values, state flows
through property wrappers, the framework owns the run loop. That world has edges.
SwiftUI has no API for a system-wide hot key, no `NSPanel`, no floating utility
window that appears even when the app isn't frontmost. NerfJournal's quick-entry
panel — Cmd-Shift-J from anywhere, type a todo (pending, or one already done), hit
Return — needs all three, so it drops down a layer to AppKit (and below AppKit, to Carbon) and then
climbs back up to host a SwiftUI view inside the panel it built by hand.

This unit is therefore less about a single framework than about the **seams**
between them. Three of those seams matter, and they run in different directions:

- **SwiftUI → AppKit**, via [`@NSApplicationDelegateAdaptor`](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor):
  giving a SwiftUI `App` a classic `NSApplicationDelegate` so there's somewhere to
  do launch-time AppKit setup.
- **AppKit → C**, via Carbon's `RegisterEventHotKey` and a bare C function pointer:
  the part of the system that predates not just SwiftUI but Swift, where you manage
  memory and isolation by hand.
- **AppKit → SwiftUI**, via [`NSHostingController`](https://developer.apple.com/documentation/swiftui/nshostingcontroller):
  putting a SwiftUI view back inside an AppKit window — and then watching that
  view's size change with Combine to resize the window around it.

The unit closes with `DateParser`, the `~date` quick-entry grammar's engine: a
self-contained, framework-free chunk of plain Swift. After all the boundary-
crossing it's a palate cleanser — and a preview of Unit 11, because the exact same
file is compiled into the `nerf` CLI too.

A note for the Rust reader to hold onto throughout: the Carbon section is Swift's
equivalent of an `unsafe` block at an FFI boundary. The job there is the same one
`unsafe` asks of you in Rust — uphold by hand the invariants the compiler can no
longer check, and confine the danger to as small a region as possible.

---

## SwiftUI → AppKit: `@NSApplicationDelegateAdaptor`

A SwiftUI `App` has no `applicationDidFinishLaunching`, no delegate, no obvious
hook for "run this AppKit code once, at startup." The bridge is a property wrapper
on the `App` struct:

```swift
@main
struct NerfJournalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    // ...
}
```

[`@NSApplicationDelegateAdaptor`](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)
tells SwiftUI: instantiate this `NSApplicationDelegate` class, install it as the
real `NSApplication`'s delegate, and keep it alive for the life of the app. From
that point the delegate receives the ordinary AppKit lifecycle callbacks —
`applicationDidFinishLaunching` among them — exactly as it would in a hand-written
AppKit app. SwiftUI is, under the hood, still running on top of AppKit on macOS;
the adaptor just hands you the delegate seat that was always there.

`AppDelegate` is the natural home for the quick-entry machinery because that
machinery is process-global, not window-scoped. It owns no SwiftUI view and
belongs to no scene; it needs to exist from launch and respond to a key chord
whether or not any window is open. That is precisely an app-delegate's job.

Note the class is itself `@MainActor`:

```swift
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?
    private var panel: NSPanel?
    private var cancellables = Set<AnyCancellable>()
    // ...
}
```

Everything it does — installing hot keys, ordering windows front — is main-thread
AppKit work, so the whole class lives on the main actor (Unit 9). That single
annotation is what later forces the `MainActor.assumeIsolated` dance at the C
boundary: the callbacks arrive *outside* the main actor, and the isolated methods
they want to call live *inside* it.

---

## AppKit → C: the Carbon global hot key

Why Carbon — a framework deprecated for the better part of two decades? Because of
a constraint the comment in the code calls out:

```swift
// Register Cmd-Shift-J (kVK_ANSI_J = 38) as a global hot key.  The Carbon
// RegisterEventHotKey API works in sandboxed apps without accessibility
// permissions, unlike NSEvent.addGlobalMonitorForEvents or CGEventTap.
```

A *global* hot key — one that fires when your app isn't frontmost — normally means
watching the global event stream, which macOS gates behind the Accessibility
permission (the scary "allow this app to control your computer" prompt). NerfJournal
is sandboxed and would rather not ask. The one exception is the old Carbon
`RegisterEventHotKey` API: it registers a *specific* chord with the window server,
which delivers an event only for that chord, so it needs no broad surveillance
permission. It's ancient, it's C, and it's the right tool.

Registration is two calls. `InstallEventHandler` says "call this function when a
hot-key-pressed event arrives"; `RegisterEventHotKey` says "and here's the chord to
watch — Cmd-Shift-J." The interesting part is the handler, because it is a **bare C
function pointer**, and that drags us all the way out of Swift's safety guarantees:

```swift
InstallEventHandler(
    GetApplicationEventTarget(),
    { (_, _, userData) -> OSStatus in
        guard let userData else { return noErr }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
        DispatchQueue.main.async { MainActor.assumeIsolated { delegate.showQuickNotePanel() } }
        return noErr
    },
    1, [eventSpec],
    Unmanaged.passUnretained(self).toOpaque(),
    &eventHandlerRef
)
```

The closure passed here captures *nothing*. That's not stylistic — it's mandatory.
A C function pointer is just an address; it has no room to carry a Swift closure's
captured environment. (A Swift closure that captures variables is really a pair —
code plus a heap-allocated context — and a C `void (*)()` can hold only the first
half.) So a closure used as a C callback must be **non-capturing**, and the compiler
enforces it. How, then, does the callback reach `self`, the `AppDelegate` instance?

Through the C convention this API was built for: a `void *` "user data" pointer you
hand to `InstallEventHandler` at registration and that it hands back to every
callback. The two ends of that round trip are the `Unmanaged` calls:

- **At registration:** `Unmanaged.passUnretained(self).toOpaque()` turns the
  `AppDelegate` reference into a raw `UnsafeMutableRawPointer` — an opaque address —
  *without* incrementing its retain count (`passUnretained`). We don't bump the
  count because the delegate is already owned for the app's lifetime by the
  adaptor; there's no danger of it vanishing, so no need to keep a second claim on
  it.
- **In the callback:** `Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()`
  reverses the trip — reconstitutes a typed `AppDelegate` reference from the raw
  pointer, again without touching the retain count (`takeUnretainedValue`).

If you've written Rust FFI this is immediately familiar: it is `Box::into_raw` /
`Box::from_raw`, or passing `*const T` through `extern "C"` and casting back. The
`Unmanaged` type is Swift's name for "I am stepping outside ARC; I will account for
the memory myself." `passUnretained`/`takeUnretainedValue` is the borrow flavor of
that (no ownership transfer); the `passRetained`/`takeRetainedValue` pair is the
owning flavor, which you'd use if nothing else kept the object alive. Choosing the
unretained pair here is a deliberate match to the fact that the adaptor already owns
the delegate — pick wrong and you'd either leak (over-retain) or crash on a dangling
pointer (under-retain). The compiler will not catch that mistake; this is the
`unsafe` zone, and the reasoning is yours to get right.

The `MainActor.assumeIsolated` inside `DispatchQueue.main.async` is the Unit 9
mechanism, here for a Unit 9 reason: the C callback has no isolation, `showQuickNotePanel`
is main-actor-isolated, so the code hops to the main thread itself and then asserts
the isolation it just established. (Re-read Unit 9's `assumeIsolated` section if that
sentence didn't land; this is the first of its two example sites.)

One small Swift-flavored helper rounds out the C interop — turning a four-character
string into the `FourCharCode` (a packed 32-bit integer) that Carbon uses for type
signatures:

```swift
private func fourCharCode(_ str: String) -> FourCharCode {
    str.utf8.prefix(4).reduce(0) { $0 << 8 + FourCharCode($1) }
}
```

It reads each of the first four UTF-8 bytes and packs them into an integer, eight
bits at a time — `"nrfj"` becomes `0x6e72666a`. A tidy reminder that even the C
boundary is reachable with ordinary Swift idioms (`prefix`, `reduce`) rather than a
manual loop.

---

## AppKit → SwiftUI: `NSHostingController` in an `NSPanel`

With the hot key wired, pressing it calls `showQuickNotePanel`, which builds a
window from scratch and puts a SwiftUI view inside it. This is the mirror image of
`@NSApplicationDelegateAdaptor`: there we embedded AppKit *under* SwiftUI; here we
embed SwiftUI *inside* AppKit.

```swift
let store = QuickNoteStore()
let view = QuickNoteView(dismiss: { /* tear down the panel */ }, store: store)
let hosting = NSHostingController(rootView: view)
hosting.sizingOptions = .preferredContentSize

let p = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 500, height: 96),
    styleMask: [.titled, .closable, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
p.contentViewController = hosting
p.title = "Quick Entry"
p.isFloatingPanel = true
p.level = .floating
p.hidesOnDeactivate = false
p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
p.setContentSize(hosting.view.fittingSize)
p.center()
panel = p
// ... the resize pipeline (below) ...
p.orderFrontRegardless()
p.makeKeyAndOrderFront(nil)
```

[`NSHostingController`](https://developer.apple.com/documentation/swiftui/nshostingcontroller)
is the adapter: give it a SwiftUI `View` as its `rootView` and it becomes a regular
AppKit `NSViewController` you can drop anywhere AppKit expects one — here, as an
`NSPanel`'s content. (Its UIKit cousin is `UIHostingController`, and the inverse
direction — AppKit *inside* SwiftUI — is `NSViewRepresentable`, not used here.) So
`QuickNoteView`, an ordinary `@MainActor` SwiftUI view with `@State` and an
`@ObservedObject` store, runs unmodified inside a window SwiftUI never created.

`NSPanel` is the AppKit class for auxiliary windows — palettes, inspectors,
quick-entry boxes. `isFloatingPanel` and `.level = .floating` keep it above normal
windows; `orderFrontRegardless()` and `makeKeyAndOrderFront` then place it and hand it
key focus without waiting for the app to be activated first. (Whether it actually
*appears* while the app stays in the background — the whole point of a global summon —
turns out to hinge on more than these two calls.) These are plain AppKit object
mutations — set a property,
call a method — which is exactly the *imperative, mutable-object* model Unit 2
contrasted SwiftUI against. The contrast is worth feeling directly: inside `hosting`
the UI is a re-rendered value; one layer out, the window is an object you configure
by poking its properties.

But two of those construction choices — the `styleMask` argument and the
`.nonactivatingPanel` flag inside it — are not free-floating style decisions. They
are the difference between a panel that appears and one that never draws at all. That
is the next, and subtlest, seam in this unit.

### Why the panel must be nonactivating — and built that way

The whole promise of the global hot key is that it summons the panel onto *wherever
you already are*, without dragging NerfJournal — and its other windows — to the
foreground or flinging you to another Space. The app stays in the background; only a
small floating box appears. Delivering that turns out to depend on a single flag set
at exactly the right moment, and getting it wrong fails in a way no compiler warns
about.

Start with the OS constraint. On macOS 15 (Sequoia), **cooperative activation**
forbids a background app from programmatically bringing itself to the front: no
variant of [`NSApp.activate()`](https://developer.apple.com/documentation/appkit/nsapplication/activate())
will front a background app any more. So any show-path that *first* tried to activate
the app and *then* order the window front now stalls at step one — the window is
placed, given a frame, even made key, but the app never activates, so the panel is
never composited (never actually drawn). You summon it and nothing appears until you
Cmd-Tab over by hand, at which point it pops into view. That defeats the entire
feature.

The escape is a genuinely **nonactivating** panel. A nonactivating panel composites
as a floating overlay *without* fronting the app at all — so it draws immediately, on
whatever Space is active, and because the app is never activated, dismissing the panel
never yanks focus to another Space either. Both halves of the original promise fall
out of that one property.

Here is the trap, and it's the real lesson of this section. You might expect to set it
after construction, the same way every other property here is set:

```swift
let p = NSPanel(contentViewController: hosting)
p.styleMask.insert(.nonactivatingPanel)   // looks right. is a no-op.
```

That compiles, runs, and *reports back as set* — read `p.styleMask` and the bit is
there. But the activation behavior does not change. `.nonactivatingPanel` is one of
those AppKit flags the window only honors as an argument to its initializer; inserting
it afterward updates the stored mask without rewiring how the window activates, so
`makeKeyAndOrderFront` still tries to activate the app — straight back into Sequoia's
restriction. The fix is to pass it in the `styleMask:` argument at construction (which
is why `showQuickNotePanel` uses the long `NSPanel(contentRect:styleMask:backing:defer:)`
initializer rather than the convenient `init(contentViewController:)`):

```swift
let p = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 500, height: 96),
    styleMask: [.titled, .closable, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
```

This is worth banking as a category of bug, not just a fact about one flag. The type
system models `styleMask` as a plain `OptionSet` you can mutate any time, so it cannot
express "this bit is only honored at construction." A property that *accepts* a write
is not the same as a property whose write *takes effect* — and AppKit, being decades
of accreted Objective-C, has a scatter of such construction-only options. It's the
same shape of hazard as the Carbon section's retain-count bookkeeping: an invariant
the compiler can't check, left for you to know and uphold. (Rust has milder cousins —
builders that consume `self` so a setting can only be chosen before `build()` — but
nothing forces AppKit to be that disciplined.)

The remaining two lines are the supporting cast. `hidesOnDeactivate = false` keeps the
panel on screen even though the app is, by design, never the active one — without it a
background app's panel would vanish the instant focus settled elsewhere.
`collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]` lets the single panel
appear on whatever Space (or full-screen app) you happen to be in, rather than being
pinned to the Space NerfJournal was launched on — the spatial half of "summon it
wherever I am."

### One more consequence: render synchronously, load lazily

Keeping the app in the background has a second, quieter fallout, and it lands in
SwiftUI rather than AppKit. `QuickNoteView` loads its category list in a `.task` (Unit
9) — an async job SwiftUI schedules when the view appears. But SwiftUI will not
reliably *drive* that `.task` until the app activates, and here the app pointedly never
does. An earlier version gated the entire view body on the load completing:

```swift
if !store.loaded { Color.clear } else { /* the real UI */ }
```

The result was a blank panel: summoned in the background, gated on a load that the
background couldn't run, showing `Color.clear` until the user Cmd-Tabbed over and woke
the `.task`. The fix is to invert the dependency — render the UI on the first
*synchronous* pass and let the data trickle in:

```swift
var body: some View {
    VStack(alignment: .leading, spacing: 8) {
        // ... text field, lower region ...
    }
    .task { await store.load() }
    .onAppear { focused = true }
}
```

The text field needs no database to draw, so it shows and takes focus immediately;
`store.load()` runs whenever it can, and its only job is to populate the `#`-completion
category list, which simply isn't there for the first few milliseconds. The principle
is a familiar one wearing AppKit clothes: **don't block the part of the UI that has no
dependency on the part that does.** It's the same instinct as rendering a page shell
before its data arrives, except the forcing function here is an OS activation rule, not
network latency.

### Watching the SwiftUI content resize the AppKit window

One more seam runs the other way. The SwiftUI content changes height as the user types — the
category picker row appears, the date picker expands. AppKit doesn't know that;
`NSPanel` has a fixed content size until something tells it otherwise. We need to
propagate a size change *out* of SwiftUI and *into* the AppKit window. The bridge is
Combine:

```swift
hosting.publisher(for: \.preferredContentSize)
    .dropFirst()
    .filter { $0.width > 0 && $0.height > 0 }
    .sink { [weak p] size in p?.setContentSize(size) }
    .store(in: &cancellables)
```

`sizingOptions = .preferredContentSize` told the hosting controller to keep its
`preferredContentSize` property updated to match the SwiftUI content's ideal size.
This Combine pipeline observes that property and resizes the panel to follow. Read
it operator by operator:

- **`hosting.publisher(for: \.preferredContentSize)`** — `preferredContentSize` is a
  Key-Value-Observing-compliant `NSViewController` property, and Combine can wrap any
  KVO property as a [`publisher(for:)`](https://developer.apple.com/documentation/combine/performing-key-value-observing-with-combine)
  that emits a new value every time it changes. The `\.preferredContentSize` is a Swift
  *key path*, the type-safe handle to a property that KVO needs.
- **`.dropFirst()`** — skip the initial value KVO emits immediately on subscription;
  we only care about subsequent *changes*, and the constructor already did the first
  sizing with `fittingSize`.
- **`.filter { $0.width > 0 && $0.height > 0 }`** — ignore the transient zero size
  the controller reports mid-layout, which would otherwise collapse the panel.
- **`.sink { [weak p] size in p?.setContentSize(size) }`** — the terminal step:
  for each surviving value, resize the panel. `[weak p]` avoids a retain cycle (the
  panel owns the hosting controller, which owns this subscription); `p?` bails if the
  panel is already gone.
- **`.store(in: &cancellables)`** — keep the subscription alive. This is the crucial,
  easily-missed part. A Combine subscription is represented by an
  [`AnyCancellable`](https://developer.apple.com/documentation/combine/anycancellable)
  token, and when that token is deallocated the subscription is cancelled. `sink`
  returns one; if you don't *store* it, it dies at the end of the function and the
  pipeline never fires. Stashing it in the `cancellables` set ties its lifetime to
  the `AppDelegate`. Tearing down the panel does `cancellables.removeAll()`, which
  deallocates the tokens and cancels cleanly.

The payoff for the reader: **Combine is not a new framework here, it's the one you
already met.** `@Published` and `ObservableObject` from Unit 4 are Combine —
`@Published` is literally a publisher, and `ObservableObject` emits through a Combine
`objectWillChange`. Units 1–9 used that machinery implicitly, with SwiftUI managing
the subscriptions for you. This is the same machinery used *explicitly*, by hand,
because the consumer is an AppKit window rather than a SwiftUI view, and AppKit won't
manage the subscription for you. The `store(in:)` you never had to write in a view is
the bookkeeping SwiftUI was quietly doing all along.

---

## Modeling ownership: why only a done thing needs a page

A short but instructive detail, because it's a *data-model* decision showing through
the panel's behavior. The panel's toggle picks between two kinds of todo: a **pending**
one (the default) and one **born already done** — an unplanned thing that already
happened, captured after the fact. Both write through the same method, but not
symmetrically:

```swift
func addTodo(title: String, categoryID: Int64?, start: Date? = nil, done: Bool = false) async {
    let today = Calendar.current.startOfDay(for: Date())
    try? await AppDatabase.shared.dbQueue.write { db in
        if done, try JournalPage.filter(Column("date") == today).fetchOne(db) == nil {
            var page = JournalPage(id: nil, date: today)
            try page.insert(db)
        }
        var todo = Todo(
            id: nil, title: title, shouldMigrate: done ? false : true,
            start: done ? today : (start ?? today),
            ending: done ? TodoEnding(date: Date(), kind: .done) : nil,
            categoryID: categoryID, externalURL: nil
        )
        try todo.insert(db)
    }
    notify()
}
```

Notice what `done` toggles. A done todo's `start` and `ending` are both pinned to
*today* — it began and finished now — and `shouldMigrate` is false, because a finished
thing has nowhere to migrate. A pending todo keeps its caller-chosen `start` (possibly
a future date bound for the Future Log) and migrates by default. That much is the
`Todo` model (Unit 7) doing its job: one row type expresses both "to do" and "already
did," distinguished only by which of its date fields are filled.

The asymmetry worth dwelling on is the *page*. A `Todo` carries no `pageID` at all —
the page views find todos by querying on `start` date, not by ownership — so writing a
pending todo never has to touch a journal page; it's a row, and that's it. But the
*done* branch first ensures today's page exists, creating it if it doesn't. Why the
difference, when neither mode has a foreign key forcing it?

Because the two modes *mean* different things. Logging a done thing is recording that
today happened a certain way; it should anchor a real journal page for today, so the
entry shows up there immediately rather than floating in a day the journal doesn't yet
know exists. A pending todo is forward-looking: a future-dated one belongs to the
Future Log and may never touch today's page, and a today-dated one will surface the
moment today's page is opened through the normal flow. So page-creation is pushed down
to the single operation whose *meaning* requires a concrete page, and imposed nowhere
else. (This is also why the panel opens and focuses its field unconditionally instead
of refusing when today's page is missing: only one branch of one operation needs the
page, so gating the whole panel on it enforced the prerequisite far too early.)

The lesson generalizes, and it's a subtler one than a foreign key would hand you. The
data model here doesn't *force* the page to exist — nothing breaks if it's absent — so
the compiler can't point to where it must be created. Intent has to: work out which
operation's semantics actually depend on the artifact, enforce the prerequisite there,
and impose it nowhere broader.

The lazy creation also deliberately *skips* the "start-of-day abandonment ceremony"
that opening a fresh journal page through the main UI performs (migrating yesterday's
unfinished todos forward). Logging a done thing from the quick panel shouldn't trigger
a day's worth of bookkeeping as a side effect — another case of doing exactly what the
operation needs and no more.

---

## `DateParser`: plain Swift, no framework in sight

After three framework boundaries, `DateParser` is a relief: no SwiftUI, no AppKit,
no Combine — just `Foundation` for the calendar. It parses the string typed after
`~` in the quick-entry field (`~tomorrow`, `~fri`, `~+3d`, `~2026-07-20`) into a
start-of-day `Date`, or `nil` if it can't.

The first thing to notice is the type:

```swift
enum DateParser {
    static func parse(_ query: String) -> Date? { /* ... */ }
    private static func parseISO8601(_ s: String) -> Date? { /* ... */ }
    private static func nextWeekday(/* ... */) -> Date? { /* ... */ }
}
```

It's an `enum` with **no cases**. That's a Swift idiom for a pure namespace: a
caseless enum can't be instantiated (there's no value to make), so it's a bag of
`static` functions and nothing else — exactly a Perl package full of subs and no
`new`, or a Rust `mod` with free functions. Using `enum` rather than `struct` for
this is intentional: a struct could be accidentally instantiated (`DateParser()`),
whereas a caseless enum makes "this is namespace, not a type to instantiate"
*unrepresentable*, which is the same value-of-making-illegal-states-unrepresentable
move that runs through the whole language.

The parsing logic itself is ordinary Swift, but two touches reward a close read
because they're the kind of detail that turns out to matter:

```swift
// "today" is checked before "tomorrow" so that a bare "t" resolves to
// today; typing "tom" unambiguously resolves to tomorrow.
if "today".hasPrefix(q)    { return today }
if "tomorrow".hasPrefix(q) { return cal.date(byAdding: .day, value: 1, to: today) }
```

The matcher is prefix-based — `"today".hasPrefix(q)` asks "is what the user typed a
prefix of `today`?" — so the user can type as little as disambiguates. The *order*
of the checks resolves the collision: `t` is a prefix of both words, and putting
`today` first makes the shorter, more-common intent win. This is interaction design
encoded as statement order, and the comment is there precisely because the ordering
is load-bearing, not arbitrary.

The ISO-8601 branch is the other careful bit:

```swift
// ... A full timestamp is reduced to the start of its day in the local
// calendar ... so 2026-07-20T09:00:00Z and 2026-07-20 land on the same page.
if let date = parseISO8601(trimmed) {
    return cal.startOfDay(for: date)
}
```

A `Todo`'s `start` is conceptually a *day*, not a *moment* (Unit 7). So even a
full timestamp is collapsed to its local start-of-day, keeping the parser's output
type honest: every path through `parse` yields a start-of-day `Date`, never a
mid-afternoon one, so callers never have to wonder which they got.

Why dwell on a date parser in an interop unit? Because it's the counterweight that
makes the rest legible. Most of NerfJournal is either SwiftUI or glued to a
framework; `DateParser` is proof that plenty of real work is just *Swift* — value
types, optionals, `Calendar` arithmetic — owing nothing to any UI framework. That
property is also what lets it be **shared verbatim with the `nerf` CLI**: the file is
compiled into both the app and the command-line tool, because it imports nothing
either one couldn't supply. (The CLAUDE.md note "keep in sync with
NerfJournal/DateParser.swift" marks the seam; Unit 11 picks up why the CLI vendors a
copy at all instead of importing the app's.) Framework-free code is portable code —
a point worth banking now, because the entire next unit is about a second program
built from exactly this kind of Swift.

---

## How this maps to Rust, and to Perl

- **The Carbon callback ≈ Rust FFI with `unsafe` and raw pointers.** `Unmanaged`,
  `toOpaque`/`fromOpaque`, and the retained/unretained pairing are Swift's
  `Box::into_raw`/`from_raw` and `*const T` round-trip through `extern "C"`. In both
  languages the rule is the same: the type system steps aside at the boundary, you
  uphold the ownership invariants yourself, and you keep the unsafe region tiny.
  Swift draws the line with the `Unmanaged` type rather than an `unsafe` keyword, but
  the discipline is identical.
- **A non-capturing C-callback closure ≈ a Rust `fn` (not a closure).** A C function
  pointer can't carry an environment in either language; both make you smuggle state
  through a `void *`/`*mut c_void` user-data parameter instead. Perl has no real
  analogue — a Perl coderef always closes over its lexicals, because there's no
  bare-function-pointer layer beneath it.
- **The caseless `enum` namespace ≈ a Rust `mod` of free functions, or a Perl package
  with subs and no constructor.** A grouping of related functions under a name, with
  no instances involved.
- **Combine's `publisher(for:)` ≈ a stream/observer over a property.** Rust has no
  std equivalent; the nearest mental model is a channel or a `futures::Stream` of
  successive values. The lifecycle point — drop the `AnyCancellable` and the
  subscription ends — maps cleanly to Rust's RAII: the subscription is a guard whose
  `Drop` tears things down, which is why you must *hold* it.

For Perl the through-line is again mostly absence: no compile-time FFI safety
(`XS`/`FFI::Platypus` ask you to be careful, by hand and at runtime), no
property-observer framework in core, and no window server to summon a panel from.
What does carry over is the *shape* of the design — a small, framework-free module
(`DateParser`) reused across two programs is the same instinct as factoring shared
logic into a Perl module that both a web app and a cron script can `use`.

---

## Reading

- [`@NSApplicationDelegateAdaptor`](https://developer.apple.com/documentation/swiftui/nsapplicationdelegateadaptor)
  — give a SwiftUI `App` a classic AppKit delegate
- [`NSHostingController`](https://developer.apple.com/documentation/swiftui/nshostingcontroller)
  — host a SwiftUI view inside an AppKit view-controller hierarchy
- [`NSPanel`](https://developer.apple.com/documentation/appkit/nspanel)
  — the auxiliary/floating-window class
- [`.nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask/nonactivatingpanel)
  — the style-mask bit that lets a panel show without activating its app (set at construction)
- [`NSApplication.activate()`](https://developer.apple.com/documentation/appkit/nsapplication/activate())
  — the activation call Sequoia's cooperative activation refuses for a background app
- [`Unmanaged`](https://developer.apple.com/documentation/swift/unmanaged)
  — stepping outside ARC at a C boundary; retained vs. unretained
- [KVO with Combine: `publisher(for:)`](https://developer.apple.com/documentation/combine/performing-key-value-observing-with-combine)
  — wrapping a Key-Value-Observing property as a publisher
- [`AnyCancellable`](https://developer.apple.com/documentation/combine/anycancellable)
  — the token whose lifetime *is* the subscription's lifetime
- [Carbon `RegisterEventHotKey`](https://developer.apple.com/documentation/coreservices/1446166-registereventhotkey)
  — the sandbox-friendly global hot-key API (for reference; it's old)

---

## Code Tour

### `NerfJournalApp.swift` line 99: the adaptor

The single line that pulls `AppDelegate` into the SwiftUI app. Note it sits among the
`@StateObject` stores — same `App` struct, same property-wrapper syntax, but this one
reaches *down* into AppKit rather than holding SwiftUI state.

### `AppDelegate.swift` lines 18–44: registering the hot key

`registerGlobalHotKey`. Read the comment on *why Carbon*, then trace the two C calls.
Confirm the handler closure captures nothing, and find where `self` is smuggled in
(`passUnretained(self).toOpaque()`) and pulled back out (`fromOpaque(...).takeUnretainedValue()`).

### `AppDelegate.swift` lines 30–35: the C-callback boundary

The four lines inside the handler. Name each step: null-check the user data,
reconstitute the delegate, hop to main, assert isolation, call the method. This is the
whole `unsafe`-equivalent region — note how small it is.

### `AppDelegate.swift` lines 62–99: building and watching the panel

`showQuickNotePanel`'s construction half: `NSHostingController` wrapping `QuickNoteView`,
the `NSPanel` configuration, and the `publisher(for: \.preferredContentSize)` pipeline.
Read the comment on *why* the panel is built with an explicit `styleMask:` carrying
`.nonactivatingPanel` (rather than the convenient `init(contentViewController:)` plus a
later `styleMask.insert`), then read each Combine operator and find the
`.store(in: &cancellables)` that keeps it alive.

### `QuickNoteView.swift` lines 67–145: render synchronously, load lazily

The view body and its `.task`/`.onAppear`. Note that nothing gates the body on
`store.loaded`: the field draws and focuses on the first synchronous pass, and
`store.load()` only fills the category completion list once it lands. Tie this back to
the panel being summoned while the app is in the background, where SwiftUI won't drive
the `.task` until activation.

### `QuickNoteView.swift` lines 23–42: the pending/done asymmetry

`addTodo`'s single write path. Note what the `done` flag pins (`start`, `ending`,
`shouldMigrate`) and the one extra thing it does — ensure today's page exists — that
the pending path skips. Tie the difference not to a foreign key (a `Todo` has no
`pageID` at all) but to what each mode *means*.

### `DateParser.swift` lines 13–83: framework-free Swift

The caseless-`enum` namespace, the prefix-match ordering (`today` before `tomorrow`),
and the ISO-8601-to-start-of-day collapse. The one file in this unit that imports no UI
framework — and the bridge to Unit 11.

---

## Exercises

**1.** The Carbon handler uses `passUnretained`/`takeUnretainedValue`. Suppose you
changed both to the *retained* pair (`passRetained` / `takeRetainedValue`). What goes
wrong, and is it a leak or a crash? Now suppose you left registration as
`passRetained` but the callback as `takeUnretainedValue`. What changes? (Reason about
the retain count at each step.)

**2.** The hot-key handler closure captures nothing, and the compiler requires that.
Try, in your head, to make it capture `self` directly instead of round-tripping
through `userData`. What's the exact compiler objection, and what does it tell you
about how a Swift closure differs from a C function pointer?

**3.** Delete the `.store(in: &cancellables)` line from the panel-resize pipeline.
The code still compiles. What happens at runtime when the user types enough to expand
the panel, and why? (Trace the lifetime of the `AnyCancellable` `sink` returns.)

**4.** `DateParser` is an `enum` with no cases. What would change, in practice, if it
were a `struct` instead? Construct the specific misuse the caseless `enum` makes
impossible — and decide whether you think it's worth the idiom.

**5.** The done branch of `addTodo` lazily creates today's page but deliberately skips
the start-of-day migration ceremony. Argue both sides: when might a user be surprised
that logging a done thing from the quick panel *didn't* migrate yesterday's unfinished
todos forward — and why is doing the migration here nonetheless the wrong call?

**6.** `preferredContentSize` is observed via `publisher(for:)` because it's a KVO
property on an AppKit object. Contrast this with how a SwiftUI view observes a
`PageStore` change (Unit 4). Both are Combine underneath — what is SwiftUI doing for
you in the store case that you had to do by hand here, and where is the line drawn?

**7.** The panel passes `.nonactivatingPanel` in its `styleMask:` argument at
construction; doing the same with `p.styleMask.insert(.nonactivatingPanel)` afterward
compiles, reads back as set, and yet leaves the panel never drawing when summoned from
the background. Explain why a write the API *accepts* needn't *take effect* — and name
the other invariant in this unit (hint: the Carbon section) that the type system is
likewise unable to check for you.

**8.** An earlier `QuickNoteView` gated its whole body on `store.loaded`, showing
`Color.clear` until the category load finished. With the panel summoned while the app
is in the background, what specifically failed — and why does rendering the field
synchronously while letting `store.load()` finish later fix it without losing the
category completion? (Trace when SwiftUI actually drives a `.task` for a window the app
never activates.)
