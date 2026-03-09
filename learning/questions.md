---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 1: Swift as a Language

### How does the leading-dot shorthand work: `.nerfJournalDatabaseDidChange`, `.main`, `.done`?

This is Swift's **implicit member expression**. When the expected type is known
from context, you can write `.memberName` instead of `TypeName.memberName` and
Swift fills in the type.

`addObserver(forName:)` declares its parameter as `Notification.Name?`. Swift
sees `.nerfJournalDatabaseDidChange`, knows it needs a `Notification.Name`, and
looks for a static member with that name on `Notification.Name` — finding it in
the extension. `queue: .main` works the same way: the parameter expects
`OperationQueue?`, `.main` is a static property on `OperationQueue`.

It works wherever Swift can determine the type from context — function parameter
types, variable annotations, return types. The rule: if there's only one type
that could make sense, you can drop the type name and keep just the dot.

It works the same for enum cases and static constants:

```swift
case .done          // TodoEnding.Kind.done — enum case
queue: .main        // OperationQueue.main  — static property on a class
forName: .nerfJournalDatabaseDidChange  // Notification.Name(...) — static
                                        //   constant on a struct, via extension
```

The extension is what makes the last one feel surprising. The value isn't an
enum case — it's a static constant defined in an extension:

```swift
extension Notification.Name {
    static let nerfJournalDatabaseDidChange = Notification.Name("nerfJournalDatabaseDidChange")
}
```

But the dot-syntax shorthand works identically for static properties as for
enum cases, as long as the type is inferable from context.

### What does `_` mean in a function parameter: `func foo(_ bar: T)`?

Swift lets every parameter have two names: an **argument label** used at the
call site, and a **parameter name** used inside the function body:

```swift
func foo(argumentLabel parameterName: Type)
```

`_` as the argument label means "no label" — the caller omits it:

```swift
// with _:    store.completeTodo(myTodo, undoManager: mgr)
// without _: store.completeTodo(todo: myTodo, undoManager: mgr)
```

Inside the function, the parameter is still called by its parameter name.
`_` only suppresses the external label.

It's a convention borrowed from Objective-C, where the first argument's role
was implied by the method name itself. `completeTodo(myTodo)` reads naturally
— the "what" is already in the name, so labeling it `todo:` would be
redundant. Subsequent parameters (`undoManager:`) get labels because their
roles aren't implied by the function name.

When argument label and parameter name would be the same word, Swift lets you
write just `undoManager: UndoManager?` rather than
`undoManager undoManager: UndoManager?`.

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

