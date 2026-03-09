---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 4: Observable Objects and Stores

### What is the difference between `@State` and `@StateObject`?

Both tie storage to a view's lifetime in the hierarchy. The difference is what
they store and how SwiftUI detects changes.

**`@State`** stores a value type (struct, Int, Bool, etc.). SwiftUI owns the
storage directly and detects changes via the property wrapper's setter — when
you assign to a `@State` property, SwiftUI sees the write and schedules a
re-render.

**`@StateObject`** stores a reference type — specifically an `ObservableObject`.
SwiftUI manages the object's lifetime (creates it once, keeps it alive as long
as the view is in the hierarchy), but doesn't watch for assignments to the
property itself. Instead, it subscribes to the object's `objectWillChange`
publisher. The object announces its own changes via `@Published`; SwiftUI
listens.

```swift
@State private var count = 0               // SwiftUI watches the assignment
@StateObject private var store = MyStore() // SwiftUI watches store.objectWillChange
```

With `@State`, SwiftUI detects changes because *it* controls the storage.
With `@StateObject`, SwiftUI detects changes because the *object* fires a
publisher. A mutable class stored in a plain `@State var` would be invisible
to SwiftUI — it would only notice if you replaced the whole reference.

The lifetime guarantee is the same: tied to the view's position in the
hierarchy, surviving re-renders, torn down when the view leaves the tree.

### Why `@EnvironmentObject` instead of just passing the store as an init parameter?

The core reason is **prop drilling** — threading a value through every layer
of the view hierarchy even when intermediate layers don't need it.

Consider NerfJournal's hierarchy:

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

Change observation is also part of the answer. A plain `let pageStore:
PageStore` property wouldn't subscribe to `objectWillChange` — you'd get stale
renders. You'd need `@ObservedObject var pageStore: PageStore`, which still
requires prop drilling. `@EnvironmentObject` is essentially `@ObservedObject`
sourced from the environment rather than from an init parameter — observation
is included.

`JournalView(pageStore: myPageStore)` would work fine if only `JournalView`
needed it. The problem is that `TodoRow`, `FutureLogRow`, `BundleDetailView`,
and many other deeply nested views need it too. The React equivalent is
Context — same problem, same solution.

