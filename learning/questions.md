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

