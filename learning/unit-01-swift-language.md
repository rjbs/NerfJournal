---
title: "Unit 1: Swift as a Language"
nav_order: 10
---

# Unit 1: Swift as a Language

## Introduction

Before touching SwiftUI, you need the language it's built on. Swift is
statically typed, compiled, and designed around a distinction — value types vs.
reference types — that will shape every decision in the units that follow.

This unit covers the language features you'll see constantly in NerfJournal's
source: structs, enums, optionals, protocols, extensions, closures, and computed
properties. None of this is SwiftUI-specific; it's just Swift.

The single most important idea in this unit is that **structs are value types**.
Everything else makes more sense once that has settled in.

---

## Value Types vs. Reference Types

In Perl, almost everything passed around is a reference. Scalars are copied, but
you mostly work with references to arrays, hashes, and objects anyway, and
knowing whether you have a copy or a reference to shared data is largely your
problem to track.

Swift makes this distinction part of the type system. Every type is either a
**value type** or a **reference type**, and the language enforces the difference.

- **Structs** (`struct`) are value types. Assigning one to a new variable, or
  passing it to a function, copies it. You get an independent duplicate.
- **Classes** (`class`) are reference types. Assigning one gives you another
  pointer to the same object, just as in Perl.

```swift
// Struct — value type
struct Point { var x: Int; var y: Int }
var a = Point(x: 1, y: 2)
var b = a       // b is an independent copy
b.x = 99
print(a.x)      // still 1
```

```swift
// Class — reference type
class Box { var value: Int = 0 }
let x = Box()
let y = x       // y points to the same Box
y.value = 99
print(x.value)  // 99 — same object
```

NerfJournal uses **structs for almost everything**: `Todo`, `Category`,
`TaskBundle`, `Note`, `TodoEnding`, `JournalPage`. The stores (`PageStore`,
`CategoryStore`, etc.) are classes, because they need to be shared objects with
identity that multiple views observe.

**Why does this matter for SwiftUI?** SwiftUI detects changes by comparing
values. When a store publishes an updated array of `Todo` structs, SwiftUI can
compare the old and new arrays because structs support equality checking. If
`Todo` were a class, two different `Todo` objects with the same data would be
unequal (different pointers), and one pointing to the same data would always
look unchanged. The value-type model makes the reactive system work cleanly.

---

## Optionals

Swift has no implicit `nil`. A variable of type `String` *cannot* be nil. If
you want a value that might be absent, you declare it as `String?` — an
*optional*.

```swift
var name: String = "rjbs"   // can never be nil
var nick: String? = nil     // might be nil, might be a String
```

To use the value inside an optional, you must unwrap it. The common ways:

**`if let`** — unwrap into a new name if present, skip the block if nil:
```swift
if let n = nick {
    print("Hello, \(n)")   // n is String here, not String?
}
```

**`guard let`** — like `if let` but inverted: exit early if nil, continue with
the unwrapped value:
```swift
guard let n = nick else { return }
// n is String from here on
```

**`??`** — provide a default when nil:
```swift
let display = nick ?? "anonymous"
```

**Optional chaining** — call methods or access properties on an optional, get
nil back if the optional is nil:
```swift
let upper = nick?.uppercased()  // String? — nil if nick was nil
```

In Models.swift, `Todo` has several optional fields:

```swift
var ending: TodoEnding?    // nil means the todo is still pending
var categoryID: Int64?     // nil means uncategorized
var externalURL: String?   // nil means no URL attached
```

The computed property `isPending` on `Todo` uses optional's nil-ness directly:
```swift
var isPending: Bool { ending == nil }
```

And `isDone` uses optional chaining to reach the `kind` inside the ending:
```swift
var isDone: Bool { ending?.kind == .done }
```

If `ending` is nil, `ending?.kind` is nil, nil is not equal to `.done`, so
`isDone` is false. One line, no unwrapping ceremony.

---

## Enums

Swift enums are much richer than C-style enums or Perl constants.

**Basic enum** — a closed set of cases:
```swift
enum Direction { case north, south, east, west }
var heading = Direction.north
```

**Raw values** — backed by a primitive type:
```swift
enum Status: String {
    case pending = "pending"
    case done    = "done"
}
print(Status.done.rawValue)   // "done"
Status(rawValue: "done")      // Optional<Status> — might not match
```

**Associated values** — each case carries data:
```swift
enum Result {
    case success(value: Int)
    case failure(message: String)
}
```

`switch` on enums is *exhaustive* — the compiler errors if you miss a case.
This is intentional. If you add a case to an enum, every switch on it becomes
a compile error until you handle the new case.

```swift
switch heading {
case .north: print("up")
case .south: print("down")
case .east:  print("right")
case .west:  print("left")
}
```

In Models.swift, `TodoEnding.Kind` is a simple raw-value enum:

```swift
enum Kind: String, Codable { case done, abandoned }
```

And `CategoryColor` is an enum that both stores a raw `String` value (for the
database) and provides a computed `swatch` property returning a SwiftUI `Color`:

```swift
enum CategoryColor: String, CaseIterable, Codable, DatabaseValueConvertible {
    case blue, red, green, orange, purple, pink, teal, yellow

    var swatch: Color {
        switch self {
        case .blue: return .blue
        // ...
        }
    }
}
```

`CaseIterable` is a protocol that asks Swift to synthesize a static `allCases`
array containing every case. It shows up in the category picker UI.

---

## Protocols

A protocol defines a set of requirements — methods, properties — that a type
must satisfy. If you know Moose roles or Java interfaces, this is the same idea,
but checked at compile time with no runtime dispatch overhead.

```swift
protocol Describable {
    var description: String { get }
    func summarize() -> String
}

struct Todo: Describable {
    var title: String
    var description: String { title }
    func summarize() -> String { "Todo: \(title)" }
}
```

If `Todo` declares conformance to `Describable` but doesn't implement
`description` or `summarize`, the code won't compile. The contract is enforced.

In Models.swift, every model type conforms to several protocols at once:

```swift
struct Todo: Identifiable, Codable, FetchableRecord, MutablePersistableRecord {
```

- `Identifiable` — requires a property named `id`. Enables SwiftUI's `ForEach`
  to track items across updates.
- `Codable` — requires the type to encode/decode itself to/from JSON (or other
  formats). Swift synthesizes the implementation automatically for simple types.
- `FetchableRecord`, `MutablePersistableRecord` — GRDB protocols that let the
  type load from and save to the database.

Multiple conformances at once, each bringing its own behavior, all checked at
compile time.

---

## Extensions

An extension adds methods or computed properties to an existing type — including
types you didn't write, like `String` or `Array`. This is like Perl's `AUTOLOAD`
or monkey-patching, but declared explicitly and resolved at compile time.

```swift
extension String {
    var isBlank: Bool { allSatisfy(\.isWhitespace) }
}

"   ".isBlank    // true
"hi".isBlank     // false
```

Extensions in NerfJournal are used in two important ways.

First, to keep the model file organized: `Todo`'s custom `Codable` implementation
lives in an extension rather than the main struct body, so the synthesized
memberwise initializer is still available:

```swift
extension Todo {
    // Custom coding in an extension so the memberwise init is still synthesized.
    init(from decoder: Decoder) throws { ... }
    func encode(to encoder: Encoder) throws { ... }
}
```

Second, to add behavior to `Array` itself:
```swift
extension [Todo] {
    func sortedForDisplay() -> [Todo] {
        sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }
}
```

This adds `sortedForDisplay()` to any array of `Todo` values. You call it as
`todos.sortedForDisplay()` as if it were a method the standard library always
had.

---

## Closures

Closures are anonymous functions — like Perl's `sub { ... }`. They can be
stored in variables, passed as arguments, and they capture variables from the
surrounding scope.

```swift
let greet = { (name: String) -> String in
    return "Hello, \(name)"
}
greet("rjbs")   // "Hello, rjbs"
```

Swift has extensive syntactic sugar for closures passed as function arguments.
When the last argument is a closure, you can write it *after* the parentheses
(trailing closure syntax). When the types can be inferred, you can drop the
declarations. When the body is a single expression, you can drop `return`.
The arguments can be accessed as `$0`, `$1`, etc.:

```swift
// These are all equivalent:
todos.sorted(by: { (a: Todo, b: Todo) -> Bool in return a.id! < b.id! })
todos.sorted(by: { a, b in a.id! < b.id! })
todos.sorted { a, b in a.id! < b.id! }
todos.sorted { $0.id! < $1.id! }
```

You'll see the compact forms everywhere in NerfJournal. In `sortedForDisplay`:
```swift
sorted { ($0.id ?? 0) < ($1.id ?? 0) }
```

`$0` and `$1` are the two `Todo` values being compared. `id` is optional, so
`?? 0` provides a default.

**Capture semantics**: closures capture the *variables* they reference, not
copies of the values at capture time. For structs (value types), capturing a
variable and later reading it gives you the current value of that variable, not
a snapshot. This leads to a class of bug you'll see flagged in Unit 8: a closure
in a context menu captures `todo` by reference to the variable, but by the time
the closure runs, the list may have changed. Worth keeping in mind.

---

## Computed Properties

A property doesn't have to store a value — it can compute one on demand.

```swift
struct Circle {
    var radius: Double
    var area: Double { Double.pi * radius * radius }
}
```

`area` looks like a property at the call site (`circle.area`), but there's no
stored `area` value; the computation runs each time you access it.

`Todo` uses this to derive status from the stored `ending`:
```swift
var isPending:   Bool { ending == nil }
var isDone:      Bool { ending?.kind == .done }
var isAbandoned: Bool { ending?.kind == .abandoned }
```

`CategoryColor.swatch` is a computed property returning a SwiftUI `Color`.

---

## The `mutating` Keyword

Because structs are value types, Swift enforces that methods on a struct cannot
modify the struct's stored properties — unless you explicitly mark the method
`mutating`. This signals that the method will change `self`, and Swift handles
the copy.

```swift
struct Counter {
    var count = 0
    mutating func increment() { count += 1 }
}
```

In Models.swift, every model type has:
```swift
mutating func didInsert(_ inserted: InsertionSuccess) {
    id = inserted.rowID
}
```

When GRDB inserts a new row, it calls this method to give the struct its
database-assigned ID. It's `mutating` because it modifies `self.id`.

---

## Property Wrappers (Preview)

You will see `@State`, `@Binding`, `@Published`, `@EnvironmentObject`, and
others throughout NerfJournal's UI code. These are *property wrappers* — a
language feature that lets a type annotated with `@Something` have its storage
managed and augmented by a wrapper type.

The details of each wrapper belong to later units. For now, know that
`@Something var x: T` is roughly syntactic sugar for a stored property of type
`Something<T>`, with the wrapper providing extra behavior (observation,
injection, binding). They are not magic; they are a real language mechanism
defined in the Swift standard library (and your own code can define them too).

---

## Reading

- [The Swift Programming Language — The Basics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/)
  — optionals, type safety, basic syntax
- [Structures and Classes](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/)
  — the value/reference distinction explained in depth
- [Enumerations](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/enumerations/)
  — including associated values and pattern matching
- [Protocols](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/)
- [Extensions](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/extensions/)
- [Closures](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures/)

---

## Code Tour: `Models.swift`

Open `NerfJournal/Models.swift`. All of it is worth reading at this point.

**Lines 5–27: `CategoryColor`**
An enum with a raw `String` value (for the database), `CaseIterable`
conformance (for the UI picker), and a computed `swatch` property. Notice that
the `switch` in `swatch` covers all eight cases — the compiler enforces this.

**Lines 29–40: `Category`**
A struct conforming to four protocols at once. The `id: Int64?` is optional
because it's nil until the database assigns a row ID. `didInsert` is `mutating`
because it writes back to `self.id`. The `static let databaseTableName` is a
*type property* — it belongs to the type itself, not to any instance.

**Lines 85–104: `TodoEnding`**
A struct that is itself a simple value, with an inner enum `Kind`. Notice both
`Codable` and `DatabaseValueConvertible` conformances: this struct encodes to
JSON for the export file and also encodes to a JSON string stored inside SQLite.
Two distinct serialization paths, both from the same struct.

**Lines 109–127: `Todo`**
The central model. Read the computed properties — `isPending`, `isDone`,
`isAbandoned` — and notice how much they say in one line each via optional
chaining.

**Lines 129–163: `Todo` extension**
Custom `Codable` in an extension so the synthesized memberwise initializer
(which takes all stored properties as arguments) still works. The `init(from:)`
falls back to decoding `added` when `start` is absent, preserving compatibility
with older export files.

**Lines 178–184: `extension [Todo]`**
An extension on *array of Todo*. Swift's type system allows this — you're
extending `Array` specifically when its `Element` is `Todo`.

---

## Exercises

**1.** In `Models.swift`, `Todo` has `var id: Int64?`. Why is `id` optional
rather than always having a value? What would break if you inserted a new `Todo`
with a hardcoded `id: 0`?

**2.** Change `isPending` to use `if let` instead of `== nil`:
```swift
var isPending: Bool {
    if let _ = ending { return false }
    return true
}
```
It compiles and works the same way. Then revert it. The original is idiomatic
Swift; understanding why both work is useful.

**3.** Add a computed property to `Todo` called `isOpen` that returns true if
the todo has no ending and `shouldMigrate` is true. Run `/build` to check it
compiles. Then remove it. (No test to break — this is just for the
compile-check exercise.)

**4.** `CategoryColor.swatch` is a switch statement with eight cases. What
happens if you comment out the `.yellow` case and try to build? Run `/build`
and read the error. This is the exhaustiveness guarantee in action. Uncomment
it when done.
