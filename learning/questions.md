---
title: Questions & Answers
nav_order: 999
---

# Questions & Answers

Questions that came up while reading the curriculum, with explanations.
These may eventually be synthesized back into the unit text.

---

## Unit 1: Swift as a Language

### `guard let` vs `if let` — does `guard` always take an `else`?

Yes, `guard` always requires an `else`. It's a compile-time requirement. The
`else` body must exit the current scope — via `return`, `throw`, `break`,
`continue`, or a `Never`-returning function like `fatalError()`.

The real distinction isn't about the `else` clause, though. It's about **where
the unwrapped binding lives**:

```swift
if let n = nick {
    greet(n)      // n is available here
}
// n is gone here

guard let n = nick else { return }
// n is available here, for the rest of the enclosing scope
greet(n)
doMoreWith(n)   // still have n
```

With `if let`, the unwrapped name only exists inside the braces. With
`guard let`, the unwrapped name escapes into the surrounding scope and stays
there.

An `if let / else` is perfectly valid Swift. The idiom question is: are you
branching on the optional, or are you asserting a precondition and continuing?
`guard` is the "bail out early, proceed with confidence" pattern — the happy
path stays at the outer indentation level rather than being nested inside a
branch.

### Enum raw value types — what is `String` doing in `enum Foo: String, SomeProtocol`?

`String` there is the enum's **raw value type**. It looks like a protocol
conformance but isn't — it means every case is backed by a `String` value.

```swift
enum CategoryColor: String, ... {
    case blue    // rawValue == "blue"
    case red     // rawValue == "red"
}

CategoryColor.blue.rawValue          // "blue"
CategoryColor(rawValue: "purple")    // CategoryColor? — .purple or nil
```

When the raw type is `String`, Swift auto-derives each case's raw value from
its name unless you override it explicitly (`case custom = "my-custom-string"`).
The same works with `Int`, where Swift auto-increments from 0.

The compiler synthesizes `RawRepresentable` conformance for you — that's what
provides `.rawValue` and the failable initializer. Everything else in the list
(`CaseIterable`, `Codable`, `DatabaseValueConvertible`) really are protocols.

### Protocols — can a computed `var` satisfy a zero-argument `func` requirement?

No. Even though `func summarize() -> String` takes no arguments, it is a
method, not a property. In Swift's type system, `var summarize: String`
(a `String`-typed property) and `func summarize() -> String`
(a `() -> String`-typed method) are distinct. Different call syntax, different
types — no substitution is allowed.

### Protocols — what does `{ get }` mean in a property requirement?

Protocol property requirements always carry a `{ get }` or `{ get set }` block.
This declares the minimum access requirement for the property — not an
implementation, but what the conforming type must provide:

```swift
protocol P {
    var x: Int { get }       // conformer must be readable
    var y: Int { get set }   // conformer must be readable AND writable
}
```

`{ get }` is a floor, not a ceiling. A conforming type can provide more than
required:

```swift
struct S: P {
    let x: Int    // satisfies { get } — constants are readable
    var y: Int    // satisfies { get set } — vars are read/write
}
```

A `let` constant satisfies `{ get }` but would *not* satisfy `{ get set }` —
the protocol would be demanding write access that a constant can't provide.

The qualifier is necessary because `var x: Int` alone in a protocol would be
ambiguous — stored? computed? settable? The `{ get }` / `{ get set }` block
makes the access requirement explicit without implying anything about
implementation.

### What is a module?

A **module** is the unit of code distribution and namespace isolation in Swift.
Every compiled target is a module: the NerfJournal app itself is a module,
GRDB is a module, SwiftUI is a module. When you write `import GRDB`, you're
making that module's public declarations available in your file.

NerfJournal's own source files — `PageStore.swift`, `Todo.swift`,
`JournalView.swift`, and everything else in the Xcode target — all belong to
the same module, `NerfJournal`. That's why `PageStore` can use `AppDatabase`
without any import statement: they're already in the same module.

Access control is defined relative to module boundaries:

| keyword | visible to |
|---|---|
| `private` | the current declaration only (or same file for extensions) |
| `internal` | anywhere in the same module (the default) |
| `public` | any module that imports this one |

Most NerfJournal types are `internal` without saying so explicitly — they're
not useful to external importers, so the default is exactly right. GRDB's types
are `public` because GRDB ships as a library that other modules consume.

The `NerfJournal` CLI tool in `cli/` is a *separate* module — it can't reach
into the app's Swift code at all, which is why it writes directly to SQLite
rather than calling into `PageStore`.

### Extensions — what is the scope of an extension on a built-in type?

Extensions are **module-scoped**. An extension defined anywhere in your module
is available everywhere in that module — not limited to the file it's in, and
certainly not to any block or function.

```swift
// StringExtensions.swift
extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

// AnyOtherFile.swift — same module, no import needed
let s = "   "
s.isBlank   // works fine
```

It does not leak to other modules. Access control applies normally: `internal`
(the default) means visible within your module only; `public` exposes it to
importers of your module.

The Rust analogy is close but not identical. Rust's orphan rule prevents
implementing an external trait on an external type — you must own at least one.
Swift has no such restriction: you can freely add methods to `String`, `Int`,
or any type you didn't define. The one limit is that you cannot add *stored
properties* to types you don't own — only computed properties.
