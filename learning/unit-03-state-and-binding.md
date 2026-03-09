---
title: "Unit 3: Local State and Binding"
nav_order: 30
---

# Unit 3: Local State and Binding

## Introduction

Unit 2 established that views are values — structs that SwiftUI re-creates by
calling `body` whenever something changes. But that raises an obvious question:
where does *state* live? If a view is a short-lived struct, and the user types
into a text field, who remembers what they typed between renders?

The answer is [`@State`](https://developer.apple.com/documentation/swiftui/state):
a property wrapper that moves a value *out* of the struct and into SwiftUI's
own storage, keyed to that view's identity in the hierarchy. The struct can
be thrown away and recreated; the state persists.

This unit covers the two lowest-level reactivity tools — `@State` and
[`@Binding`](https://developer.apple.com/documentation/swiftui/binding) — and
the view identity model that determines how long state lives.

---

## `@State`

A `@State` property is owned by SwiftUI, not by the struct that declares it.
When the value changes, SwiftUI re-renders the declaring view (and any children
that depend on it). The struct itself is just a description; SwiftUI holds the
actual storage.

```swift
struct Counter: View {
    @State private var count = 0

    var body: some View {
        Button("Count: \(count)") { count += 1 }
    }
}
```

`count += 1` inside a `@State` property triggers a re-render. If `Counter`
were a plain struct with a plain `var count`, mutating it inside a closure
wouldn't be possible (structs are value types — the closure captures a copy),
and even if it were, it wouldn't notify SwiftUI to re-render.

To be precise about what "owned by SwiftUI" means: when SwiftUI first renders
a view, it allocates persistent storage for each `@State` property, keyed to
that view's position in the hierarchy. The struct itself *does* contain a
`@State` wrapper — but that wrapper is a thin shell that knows where to find
the real value in SwiftUI's external storage, not the storage itself. Accessing
the property goes through the wrapper to the external store; writing to it
writes there and enqueues a re-render.

The struct instance is genuinely thrown away and recreated on every render.
SwiftUI calls `body` fresh each time. The new instance's wrapper reconnects to
the *same* storage as before, because the view occupies the same position in
the hierarchy. The wrapper is the thread of continuity; the struct is
scaffolding that gets rebuilt. Two views of the same type at *different*
positions get independent storage slots.

`@State` is always `private` — it's local to the declaring view. If another
view needs to read or write the value, you pass a *binding* to it.

---

## The `$` Prefix and Bindings

The `$` prefix on a `@State` property produces a
[`Binding<T>`](https://developer.apple.com/documentation/swiftui/binding) —
a two-way connection to the underlying storage. Reading from the binding reads
the current value; writing to it writes back through to `@State` and triggers
a re-render.

```swift
struct Counter: View {
    @State private var count = 0

    var body: some View {
        Stepper("Count: \(count)", value: $count)
        //                                ^ Binding<Int>, not Int
    }
}
```

`Stepper` takes a `Binding<Int>` so it can both read the current value and
write back when the user taps + or −. You'd pass `count` (the plain `Int`) for
display; you pass `$count` (the `Binding<Int>`) when something needs to write.

This is the `$` convention throughout SwiftUI:
- `count` — the current value
- `$count` — the binding (read + write)

`TextField` takes a binding to the string it displays and edits:

```swift
TextField("New task…", text: $newEntryText)
```

`newEntryText` is a `@State var newEntryText = ""`. The `TextField` reads it
to show the current text and writes back to it as the user types.

---

## `@Binding` — Receiving a Binding

When a child view needs to read *and write* state owned by a parent, it
declares a [`@Binding`](https://developer.apple.com/documentation/swiftui/binding)
property. The parent passes `$stateProperty`; the child uses it as if it were
local state.

```swift
struct LabeledToggle: View {
    let label: String
    @Binding var isOn: Bool          // connected to parent's @State

    var body: some View {
        Toggle(label, isOn: $isOn)  // pass the binding further down
    }
}

struct Parent: View {
    @State private var enabled = false

    var body: some View {
        LabeledToggle(label: "Enable", isOn: $enabled)
    }
}
```

Data flows **down** as values; changes flow **back up** through bindings. The
parent always owns the state; the child is just a conduit for reading and
writing it. The Rust analogy: `@Binding` is a mutable reference (`&mut T`)
to state the current function doesn't own.

`@Binding` is not `@State` — there's no storage, just a connection. When the
bound value changes, SwiftUI re-renders views that read it, wherever they are.

---

## `@FocusState`

[`@FocusState`](https://developer.apple.com/documentation/swiftui/focusstate)
works exactly like `@State` for keyboard focus. A `Bool` focus state is true
when the associated control is focused, false otherwise; you can also use an
enum to track which of several controls is focused.

```swift
@State private var newEntryText = ""
@FocusState private var addFieldFocused: Bool

TextField("New task…", text: $newEntryText)
    .focused($addFieldFocused)
```

Setting `addFieldFocused = true` in code moves keyboard focus to that field.
Reading it tells you whether the field currently has focus. NerfJournal uses
this throughout to move focus when the user presses Cmd-N (focus the add
field) or presses Escape (clear focus).

---

## Custom Bindings

Sometimes you need a binding that doesn't directly map to a `@State` property
— for example, to bridge between a store and a SwiftUI control that expects a
binding. `Binding(get:set:)` lets you construct one from explicit getter and
setter closures:

```swift
Picker("Category", selection: Binding(
    get: { todo.categoryID },
    set: { newID in
        Task { try? await store.setCategory(newID, for: todo, undoManager: undoManager) }
    }
)) {
    Text("None").tag(nil as Int64?)
    ForEach(categoryStore.categories) { category in
        Text(category.name).tag(category.id as Int64?)
    }
}
```

The `Picker` reads `todo.categoryID` and writes back by calling into the store.
There's no `@State` involved — the current value lives in the store, and the
setter commits it there. This pattern appears wherever a SwiftUI control needs
to drive a store mutation directly.

---

## The `todoToSetURL` / `showingSetURLAlert` Pattern

This is the most important practical lesson in this unit. Consider the natural
way to drive an alert from an optional value:

```swift
// Tempting but broken on macOS:
@State private var todoToSetURL: Todo? = nil

.alert("Set URL", isPresented: Binding(
    get: { todoToSetURL != nil },
    set: { if !$0 { todoToSetURL = nil } }
)) {
    TextField("URL", text: $urlText)
    Button("Set") {
        guard let todo = todoToSetURL else { return }  // ← todoToSetURL is already nil here!
        commitURL(for: todo)
    }
}
```

On macOS, when the user presses Return inside a `TextField` in an alert,
SwiftUI fires the binding's *setter* — dismissing the alert by setting
`todoToSetURL = nil` — *before* the button action runs. By the time `Button("Set")`
executes, the guard fails and nothing happens.

The correct pattern uses a separate `Bool` to drive the presentation, and only
clears `todoToSetURL` inside the button actions themselves:

```swift
// Correct:
@State private var todoToSetURL: Todo? = nil
@State private var showingSetURLAlert = false

Button("Set URL…") {
    todoToSetURL = todo
    urlText = todo.externalURL ?? ""
    showingSetURLAlert = true          // ← Bool drives the alert
}

.alert("Set URL", isPresented: $showingSetURLAlert) {
    TextField("URL", text: $urlText)
    Button("Set") {
        guard let todo = todoToSetURL else { return }  // ← still set here ✓
        commitURL(for: todo)
        todoToSetURL = nil             // ← clear after reading
    }
    Button("Cancel", role: .cancel) {
        todoToSetURL = nil
        urlText = ""
    }
}
```

The `Bool` is the presentation signal; the optional carries the payload. They
are deliberately separate. You'll see this pattern in `FutureLogView.swift`
and `TodoRow` throughout NerfJournal.

---

## View Identity and `@State` Lifetime

SwiftUI maintains a persistent *view graph* — a render tree that outlives any
individual struct instance. Your struct's `body` is the *input* to that tree,
not the tree itself. When a re-render is triggered, SwiftUI calls `body` to get
a fresh description, diffs it against what's already in the graph, and patches
in place: updating values where the structure is the same, creating new nodes
(with fresh `@State`) where new views appeared, and tearing down nodes (and
their state) where views disappeared.

Instance identity is useless for this matching — struct instances are ephemeral
by design, and two successive instances at the same position are
indistinguishable as objects. So SwiftUI uses *structural position* as the
stable identity instead.

**Structural identity**: a view's identity is its *position in the view
hierarchy*. Two views of the same type at the same position are considered the
same view; their state is preserved. A view at a position that disappears loses
its state.

```swift
// These are structurally distinct — different positions in the if/else:
if isEditing {
    TextField("", text: $editTitle)  // position A (only when isEditing)
    // @State in this TextField resets each time isEditing toggles
} else {
    Text(todo.title)                 // position A (only when !isEditing)
}
```

**Explicit identity** lets you tell SwiftUI which views correspond to which
data across updates. [`ForEach`](https://developer.apple.com/documentation/swiftui/foreach)
uses the `id` of each element (via [`Identifiable`](https://developer.apple.com/documentation/swift/identifiable)
or an explicit `id:` parameter) to maintain stable identity as items are
inserted, removed, or reordered:

```swift
ForEach(todoGroups, id: \.id) { group in
    Section { ... }
}
```

When `todoGroups` changes, SwiftUI matches up old and new items by their `id`.
An item with the same `id` as before is the *same view* — its state and
animations carry over. An item with a new `id` is freshly created. This is
why `ForEach` requires identifiable elements: without stable IDs, SwiftUI can't
do the matching.

The `.id()` modifier lets you force-reset a view's identity:

```swift
TextField("", text: $text)
    .id(currentTodo.id)  // if currentTodo.id changes, treat this as a new view
```

This is occasionally useful when you want to guarantee a fresh view (and fresh
`@State`) when data changes — for example, to clear a text field when switching
between todos. The ID only needs to be unique *among siblings in the same
parent* — not globally. `.id(currentTodo.id)` is fine even though `id` is an
autoincrement integer, because that view isn't competing with any other view
for that value; it just needs to produce a *different* value when `currentTodo`
changes.

The same scope applies to `ForEach` IDs — unique within the collection, not
globally. The difference in intent:
- `ForEach(items, id: \.id)` — IDs distinguish siblings *from each other*; must be unique within the collection at any given moment
- `.id(value)` on a single view — signals "treat me as new when this value changes"; sibling uniqueness isn't the point

---

## Other Local State Wrappers

Two more wrappers you'll see in NerfJournal, briefly:

**[`@AppStorage`](https://developer.apple.com/documentation/swiftui/appstorage)**
— like `@State`, but persisted to `UserDefaults`. Changes still trigger
re-renders. `JournalPageDetailView` uses it for the `resolvedWithNotes`
display preference:

```swift
@AppStorage("resolvedWithNotes") private var resolvedWithNotes = false
```

**[`@Environment`](https://developer.apple.com/documentation/swiftui/environment)**
— reads values SwiftUI injects into the environment (not the same as
`@EnvironmentObject` from Unit 4). Common values: `\.undoManager`,
`\.openWindow`, `\.colorScheme`. You've already seen this:

```swift
@Environment(\.undoManager) private var undoManager
@Environment(\.openWindow) private var openWindow
```

These are read-only; you can't write back through `@Environment`.

---

## Reading

- [`@State`](https://developer.apple.com/documentation/swiftui/state)
- [`@Binding`](https://developer.apple.com/documentation/swiftui/binding)
- [`@FocusState`](https://developer.apple.com/documentation/swiftui/focusstate)
- [Managing user interface state](https://developer.apple.com/documentation/swiftui/managing-user-interface-state)
  — Apple's overview of state and binding
- [SwiftUI — View Identity](https://developer.apple.com/documentation/swiftui/view-identity)
  — structural vs. explicit identity, with animations

---

## Code Tour

### `JournalView.swift` lines 308–319: `JournalPageDetailView` `@State` cluster

Read the block of `@State` declarations at the top of `JournalPageDetailView`.
Each one represents a distinct piece of transient UI state: what's being
edited, whether a field is visible, which items are selected. None of this
belongs in the store — it's UI concern, not data concern.

### `JournalView.swift` lines 797–820: `TodoRow` `@State` and alert pattern

Note `showingSetURLAlert: Bool` paired with the URL-holding state. Then find
the `.alert("Set URL"…)` that uses `$showingSetURLAlert` — you'll see the
correct pattern: the `Bool` drives presentation, the optional carries context,
and the optional is only cleared inside the button actions.

### `FutureLogView.swift` lines 94–96 and 216–227: same pattern

`FutureLogRow` uses the same `todoToSetURL` / `showingSetURLAlert` pairing.
Read both the state declarations and the alert to see how they interlock.

### `BundleManagerView.swift` lines 36–44: custom `Binding` for list selection

```swift
private var selectionBinding: Binding<Int64?> {
    Binding(
        get: { bundleStore.selectedBundle?.id },
        set: { id in
            let bundle = id.flatMap { id in bundleStore.bundles.first { $0.id == id } }
            Task { try? await bundleStore.selectBundle(bundle) }
        }
    )
}
```

A computed property that *returns* a `Binding`. The `List(selection:)` expects
a `Binding<Int64?>` to drive selection; the store holds the actual selected
bundle. The binding bridges between them. Note `flatMap` on the optional `id` —
`Optional.flatMap` is the same as `Optional.map` but used when the transform
itself returns an optional, avoiding double-wrapping.

---

## Exercises

**1.** In `JournalPageDetailView`, `scrollToFieldRequest` is `@State private var scrollToFieldRequest = 0`.
It's an `Int`, not a `Bool`. Why might an `Int` be more useful than a `Bool` for
triggering a scroll action? (Hint: what happens if you set a `Bool` to `true`
when it's already `true`?)

**2.** The `BundleManagerView` rename alert at line 67 uses the `Binding(get: { bundleToRename != nil }, set: { ... })` pattern rather than a separate Bool. Based on what you learned about the `todoToSetURL` pattern: under what conditions would this be a problem? Is there a TextField in that alert?

**3.** Sketch (in pseudocode or Swift) how you'd adapt the `selectionBinding`
pattern to drive a `Picker` over `categoryStore.categories` — where selecting
an item should call `pageStore.setCategory(id, for: todo)`. This is almost
exactly what the category picker in `TodoRow` does at line 972.

**4.** In `MonthCalendarView`, `displayMonth` is `@State`:
```swift
@State private var displayMonth: Date = {
    let cal = Calendar.current
    return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
}()
```
The initial value is a closure that runs immediately (the trailing `()`). Why
can't you just write `@State private var displayMonth: Date = Date()`?
(Consider what `Date()` gives you, and what the calendar grid needs.)
