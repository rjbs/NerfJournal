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
