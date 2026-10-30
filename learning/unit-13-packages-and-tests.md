---
title: "Unit 13: Packages, Modules, and Tests"
nav_order: 130
---

# Unit 13: Packages, Modules, and Tests

## Introduction

Unit 1 introduced modules with a table of access levels and one consequence: the CLI
"can't reach into the app's Swift code at all." Unit 11 showed what that cost, a CLI
that re-declared the app's model types by hand and had to keep them in step. Its
fifth exercise asked what it would take to move those types into a shared package.

NerfJournal now has that package. **NerfCore** holds the model types, the schema, the
date types, the date parser, the export format, and the code that turns todos into JMAP
Tasks and back. The app and the CLI both import it. This unit is about what happens when
your own code becomes a library. It covers how a package is declared and consumed, what
`public` costs once there's a real boundary to cross, and how a library gets tested
from outside. That last topic is new to the book, because the app itself has no
automated tests.

Two things to keep in mind throughout. First, a module boundary turns facts the compiler
used to infer into promises you have to write down: initializers, `Sendable`, which
names are visible. Unit 12 showed one of these (explicit `Sendable` on public types),
and this unit collects the rest. Second, a test suite that can only use the public API is
a good check on that API: if the tests can't do something, neither can the app.

---

## A package with a library product

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NerfCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NerfCore", targets: ["NerfCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(path: "../../Jinx"),
    ],
    targets: [
        .target(
            name: "NerfCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "JinxJSON", package: "Jinx"),
                // ... four more Jinx products ...
            ]
        ),
        .testTarget(
            name: "NerfCoreTests",
            dependencies: ["NerfCore", .product(name: "JinxScriptedServer", package: "Jinx")]
        ),
    ]
)
```

Unit 11 read a manifest with one executable target and no products. This one has the
other three pieces a package can have.

**A product** is what a package offers to the outside. `.library(name: "NerfCore",
targets: ["NerfCore"])` says: anyone who depends on this package may link a library
called NerfCore, built from the target of the same name. Targets are a package's
internal organization, and products are its public face. A package can have targets no
product exposes (helpers, test fixtures), and one product can bundle several targets.
Jinx shows the other extreme: it vends seven separate library products (`Jinx`,
`JinxTypes`, `JinxStore`, `JinxWire`, `JinxPatch`, `JinxJSON`, `JinxScriptedServer`) so
a consumer links only the layers it uses. NerfCore links six of them. Only its tests
link the seventh.

**A plain `.target`** compiles to a library module rather than an executable, because
nothing in it is marked `@main`.

**A `.testTarget`** is a module of tests that depends on the code under test. It's built
and run by `swift test` and never shipped in a product. Here it also depends on
`JinxScriptedServer`, a product that exists only for testing. Jinx ships its own fake
server so its consumers can test against it, which a library author does when they
expect their users to need one.

**Path dependencies.** `.package(path: "../../Jinx")` names a package by its location on
disk, not by URL and version. During development this is convenient: an edit in Jinx
shows up in the next NerfCore build with no publishing step. But it ties the build to
a directory layout. NerfJournal can only be built on a machine that has Jinx checked
out beside it, at whatever revision happens to be there, and nothing like
`Package.resolved` records which. A URL dependency trades that convenience for
reproducibility. Exercise 5 asks you to weigh it.

---

## Two consumers, two mechanisms

The CLI is a package itself, so it depends on NerfCore exactly as NerfCore depends on
Jinx:

```swift
dependencies: [
    .package(path: "../NerfCore"),
    // ...
],
// ...
dependencies: [
    .product(name: "NerfCore", package: "NerfCore"),
    // ...
]
```

The app is an Xcode project, and Xcode has its own way to say the same thing: an
`XCLocalSwiftPackageReference` in `project.pbxproj`, pointing at `relativePath =
NerfCore`, plus a product dependency on its `NerfCore` library. In Xcode's UI this is
"Add Package Dependencies… → Add Local…". Under the hood Xcode runs SwiftPM to build the
package, so NerfCore compiles the same way for both consumers. (Adding a local package
reference also required raising the project file's `objectVersion` to 60, the kind of
format detail that makes `project.pbxproj` unpleasant to edit by hand.)

Either way, the consumer writes `import NerfCore` and gets the module's public
declarations, and nothing else.

---

## What `public` costs

Moving types from an app module, where everything is `internal` by default, into a
library, where only `public` declarations are visible to clients, changes more than
the keyword on each type.

### Every member needs its own `public`

Access control applies to each declaration, not to a whole type. A `public struct` with
unmarked properties is a type clients can name but whose fields they can't touch.
`Models.swift` therefore says `public` dozens of times: on each type, each stored
property, each computed property, each method, each nested type. That's noisy, but
it's also the API written out in full: anything not marked `public` is a detail the
package is free to change.

### Initializers stop being free

```swift
public struct Todo: Identifiable, Codable, Equatable, Sendable {
    public var id: Int64?
    public var title: String
    public var shouldMigrate: Bool
    public var start: CivilDate
    public var ending: TodoEnding?
    public var categoryID: Int64?
    public var externalURL: String?

    public init(id: Int64?, title: String, shouldMigrate: Bool, start: CivilDate,
                ending: TodoEnding? = nil, categoryID: Int64? = nil, externalURL: String? = nil) {
        self.id = id
        self.title = title
        // ... one assignment per property ...
    }
}
```

Unit 1 said a struct gets a memberwise initializer for free. It does, but that
initializer is **`internal`**, even on a `public` struct. Inside NerfCore you could
still write `Todo(id:title:…)` without declaring anything. From the app or the CLI, you
couldn't construct a `Todo` at all. So every public record type in NerfCore spells out a
`public init` that does exactly what the synthesized one would have done.

The rule is deliberate. If the synthesized initializer were public, adding a stored
property to a struct would change the initializer's signature and break every client
that calls it. Making you write the
public initializer means the struct's layout and its construction API can change
independently. The explicit `init` also lets you choose defaults, as `Todo`'s does for
its three optional fields, so that callers can leave them out.

### `Sendable` must be declared

Unit 12 covered this one. Public types get no inferred `Sendable`, for the same reason
public types get no public memberwise initializer: either one would make an
implementation detail part of the API without anyone deciding it should be.

### Names collide that didn't before

When `Category` lived in the app module, a bare `Category` in an app file meant the
app's type. Then it moved into NerfCore, and every bare `Category` in the app and the
CLI became a compile error: *ambiguous*. The other candidate was
**`ObjectiveC.Category`**, a type alias the Objective-C runtime module defines for
Objective-C categories, which every file that imports Foundation can see.

That wasn't a problem before because of how Swift resolves names. A declaration in your
own module **shadows** any imported declaration with the same name. While `Category`
was the app's own type, it simply won. Once it became an imported type, it was one
import among two, with neither preferred. The fix is a one-line type alias in each
consuming module:

```swift
typealias Category = NerfCore.Category
```

The alias is a declaration in the consuming module, so it shadows `ObjectiveC.Category`
again, and bare `Category` works everywhere in that module. The test files do the same
with `private typealias`, scoped to one file. Perl readers will recognize the shape:
two packages exporting the same name into your namespace, settled by importing one
explicitly.

### Access levels between `internal` and `public`

Swift has two more levels that NerfCore doesn't use, both worth knowing. **`open`** is
`public` plus the right to subclass or override from another module. `public` alone lets
clients use a class but not subclass it, and since NerfCore's types are structs, enums,
and actors, the question never comes up. **`package`** (Swift 5.9) makes a declaration
visible to every module in the same package but not to clients outside it. It's how a
multi-target package like Jinx can share helpers among its own targets without making
them public API.

---

## Keeping the UI out: extensions across a module boundary

NerfCore has no UI dependency, because the CLI links it. But the app wants a SwiftUI
`Color` for each `CategoryColor`. The answer is an **extension in the app**, on a type
declared in NerfCore:

```swift
import SwiftUI
import NerfCore

extension CategoryColor {
    var swatch: Color {
        switch self {
        case .blue:   return .blue
        case .red:    return .red
        // ...
        }
    }
}
```

Unit 1 noted that extensions are module-scoped: visible throughout the module that
declares them and nowhere else. That's what makes this work. Inside the app,
`category.color.swatch` reads as though `swatch` were part of `CategoryColor`. NerfCore
never sees it, never imports SwiftUI, and the CLI, which links NerfCore but not this
file, has no `swatch` at all. The type's definition lives in the library, and each
consumer adds what it needs. `HTMLExport.swift` does the same with a
`private extension CategoryColor` for CSS hex values, scoped to that one file.

This is Swift's answer to a question Perl answers by reopening a package from another
file, and Rust answers with extension traits. Swift's version needs no trait and no
import of the extension by name. The consuming module just has it. The limit is the
same as Rust's: an extension can add methods and computed properties, and conformances,
but not stored properties, because the type's memory layout belongs to the module that
declared it.

---

## Testing a package

NerfCore has 52 tests, run with `cd NerfCore && swift test`, finishing in about a tenth
of a second with no network. The app has none. The README notes the architecture would
allow store tests, but none exist yet. So NerfCore's suite is the example to study.

### XCTest, and the newer framework beside it

The tests use [XCTest](https://developer.apple.com/documentation/xctest), Apple's
long-standing testing framework: a test file declares a `final class` subclassing
`XCTestCase`, every method whose name begins with `test` is a test, and assertions are
functions like `XCTAssertEqual` and `XCTAssertThrowsError`.

When you run `swift test`, the output ends with a second, separate report:

```
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
```

That's [Swift Testing](https://developer.apple.com/documentation/testing), the newer
framework (2024), which SwiftPM runs alongside XCTest. It found nothing because NerfCore
doesn't use it. Swift Testing uses macros instead of naming conventions (`@Test` on a
function, `@Suite` on a type, `#expect(a == b)` instead of `XCTAssertEqual(a, b)`),
works with structs as well as classes, runs tests in parallel by default, and has
first-class parameterized tests. It's where Apple's attention is now, much as with
`@Observable` and Combine in Unit 10. XCTest isn't going away, and a suite in XCTest is
perfectly sound, but a new suite started today would probably use Swift Testing.

### Async tests

```swift
func testCreatedTodoReachesTheServerAndReadsBack() async throws {
    let rig = try Rig()
    let lists = try await rig.sync.listIndex()
    // ...
}
```

A test method can be `async throws`, and XCTest awaits it. Nothing special is needed to
test actor-isolated code: the test calls into `JournalSync` with `await` exactly as the
app does. A thrown error fails the test.

### The scripted server, injected through a protocol

The interesting tests exercise the whole path: encode a todo, hand it to the sync
engine, push it to a server, read it back. The server is
`JinxScriptedServer.ScriptedServer`, an in-process fake that implements just enough
JMAP for Tasks, lets a test configure per-type behavior, and can be told to misbehave
on purpose (fail a request, lose a response, return a method error).

What makes it pluggable is `JournalSync`'s second initializer:

```swift
// The production wiring: an HTTP client against `settings`, signalled
// to other processes on `databasePath`.
public init(writer: any DatabaseWriter, databasePath: String, settings: SyncSettings) throws {
    try self.init(
        writer: writer,
        settings: settings,
        transport: JMAPClient(sessionUrl: settings.sessionURL, authenticator: NoAuthentication()),
        signalName: Self.signalName(forDatabaseAt: databasePath)
    )
}

// The wiring with the transport supplied, for tests against a scripted
// server. A nil signal name disables cross-process notification.
public init(writer: any DatabaseWriter, settings: SyncSettings, transport: any JMAPTransport, signalName: String?) throws
```

The engine talks to the network only through `JMAPTransport`, a protocol in
`JinxWire` with five requirements (fetch the session, send a request, upload, download,
open an event stream). The real `JMAPClient` implements it over `URLSession`.
`ScriptedServer` implements it in memory. The production initializer chooses the real
one; the test initializer takes whichever you pass. That's dependency injection without
a framework: one protocol at the boundary that matters, and an initializer that lets the
caller supply the other side.

`ScriptedServer` is also a small study in `Sendable`. `JMAPTransport` requires
`Sendable`, because the engine actor holds the transport and calls it across isolation
domains. A server fake has mutable state (its objects, its request log, its queued
faults), and a class with mutable state isn't `Sendable` by default. The fake is a
`final class` that keeps all of its state in one stored property,
`private let state: Mutex<State>`, using `Mutex` from the standard library's
`Synchronization` module. The class's only stored state is an immutable reference to
something internally locked, so the compiler accepts the `Sendable` claim. That's the
third way to be `Sendable`, after value types and actors: a final class whose mutable
state is behind a lock.

Each test builds its world with a small `Rig`:

```swift
private struct Rig {
    let server: ScriptedServer
    let db: DatabaseQueue
    let sync: JournalSync
    // ...
    init() throws {
        server = ScriptedServer(accountId: "rjbs", capabilities: [TaskTypes.capability])
        server.configure("Task", .init(uniqueProperty: "uid"))
        listId = server.create("TaskList", ["name": "Journal", "isDefault": true])
        workId = server.create("TaskList", ["name": "Work", "color": "blue", "sortOrder": 1])
        db = try DatabaseQueue()
        try NerfSchema.migrate(db)
        sync = try JournalSync(writer: db, settings: …, transport: server, signalName: nil)
    }
}
```

`DatabaseQueue()` with no path is an in-memory SQLite database, gone when the test ends.
The real schema migration runs against it, so the tests check the actual schema, not a
hand-made copy. `signalName: nil` turns off cross-process notification, so tests can't
signal each other or a running app. Every test gets a fresh server and a fresh database,
and no test depends on another's leftovers.

### Table-style cases with call-site failure reporting

The codec tests are the other pattern worth copying. Each test case is one call to a
helper that takes the inputs and the expected output:

```swift
func testEncodesPendingMigratingTodo() throws {
    try checkEncodeNew(
        Todo(id: nil, title: "Review the release notes", shouldMigrate: true,
             start: day("2026-09-13"), categoryID: 1, externalURL: "https://example.com/pr/42"),
        uid: "9d2f5b1e-3e4a-4c5b-8f7e-1a2b3c4d5e6f",
        expecting: [
            "@type": "Task",
            "taskListIds": ["L1": true],
            "title": "Review the release notes",
            // ...
        ]
    )
}
```

and the helper hides the mechanics:

```swift
private func checkEncodeNew(_ todo: Todo, uid: String, expecting expected: JSONValue,
                            file: StaticString = #filePath, line: UInt = #line) throws {
    let actual = try TaskCodec.encodeNew(todo, lists: lists, uid: uid)
    XCTAssertEqual(actual, expected, file: file, line: line)
}
```

The `file:` and `line:` parameters are the trick. `#filePath` and `#line` are
*magic literals* that, as **default argument values**, evaluate at the *call site*, not
where they're written. So each `checkEncodeNew(…)` call passes in its own file and
line, and the helper forwards them to `XCTAssertEqual`. When an assertion fails, Xcode
and `swift test` put the failure on the test case's line, not inside the helper that
every case shares. Without it, a table of twenty cases sharing one helper would report
every failure at the same line inside the helper. Perl's `Test::Builder` has the same
need, met with `local $Test::Builder::Level = $Test::Builder::Level + 1`. Swift does it
with default arguments.

The expected values are written as JSON literals: `["taskListIds": ["L1": true]]` is a
`JSONValue`, Jinx's JSON enum, built from a dictionary literal because the type conforms
to `ExpressibleByDictionaryLiteral` and its relatives. Each case therefore reads like
the wire format it checks. In several cases these are the worked examples from
`JMAP-SPEC.md`, copied in so that the spec and the code can't silently drift apart.

### Testing only through the public API

No test file says `@testable import NerfCore`. That attribute would let a test module see
the library's `internal` declarations, a common convenience. NerfCore's tests skip it.
`TaskCodec` has internal helpers (`parseRFC3339`, `isEnded(progress:)`, the start-day
fallback chain), and none is called directly. Each is tested through the public
`encode` and `decode`. A test like `testProgressValues` feeds `decode` a Task with each
`progress` value and checks the resulting `Todo`.

The result is a suite that sees NerfCore exactly as the app and the CLI do. Internal
helpers can be renamed, split, or merged without touching a test. And if something
can't be tested through the public API, that's a sign the public API is missing
something the app will also need.

---

## How this maps to Rust, and to Perl

- **Package / product / target ≈ Cargo workspace / crate / module tree.** A
  `.library` product is a library crate's public face. `.package(path:)` is a Cargo
  `path = "../jinx"` dependency, with the same reproducibility trade: neither
  `Cargo.lock` nor `Package.resolved` pins the revision of a path dependency.
- **Internal memberwise init ≈ Rust's private fields.** A Rust struct with private
  fields can't be built with a struct literal outside its crate, so you write a `pub fn
  new`. Swift reaches the same place from the other side: the fields may be public, but
  the generated initializer isn't.
- **Shadowing by your own module ≈ Rust's local items beating glob imports.** A local
  `struct Category` wins over `use objc::*;`. Two glob imports of the same name are an
  ambiguity error only when used, which is exactly what Swift reported.
- **Extensions on a foreign type ≈ extension traits**, minus the trait.
- **`package` access ≈ `pub(crate)` stretched across a workspace**, and **`@testable`
  ≈ putting tests in a `#[cfg(test)] mod tests` inside the crate**, which NerfCore
  deliberately doesn't do. Its tests are like Rust's `tests/` directory integration
  tests, which can only see the crate's public API.
- **`#filePath`/`#line` defaults ≈ `#[track_caller]`.** Both make a helper's failure
  report its caller's location.

For Perl, NerfCore is the move every Perl programmer has made many times: factoring
shared code out of an application and a cron script into a module both can `use`. The
differences are the ones this unit is about. Perl has no `public` to forget, so
nothing forces you to decide what the module's interface is, and no compiler stops a
consumer from poking at the internals. `@EXPORT_OK` and a leading underscore are
conventions. Swift's access levels are checked.

---

## Reading

- [Swift Package Manager](https://www.swift.org/documentation/package-manager/) and
  [`PackageDescription`](https://developer.apple.com/documentation/packagedescription)
  — products, targets, test targets, and dependency kinds
- [Access Control](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/)
  — the Swift book chapter, including the rule about memberwise initializers
- [Adding package dependencies to your app](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app)
  — the Xcode side, including local packages
- [XCTest](https://developer.apple.com/documentation/xctest) and
  [Swift Testing](https://developer.apple.com/documentation/testing)
- [`Mutex`](https://developer.apple.com/documentation/synchronization/mutex)
  — the `Synchronization` module's lock, used to make the scripted server `Sendable`

---

## Code Tour

### `NerfCore/Package.swift` lines 10–33

The product, the two dependencies (one by URL and version, one by path), the library
target, and the test target. Count the Jinx products the library links, then the one
only the tests do.

### `cli/Package.swift` lines 8 and 16; `NerfJournal.xcodeproj/project.pbxproj` lines 543–548

The two ways of consuming the same local package: a SwiftPM path dependency and an
Xcode local package reference.

### `NerfCore/Sources/NerfCore/Models.swift` lines 175–198

`Todo`: `public` on every member, and the hand-written `public init` that replaces the
internal memberwise one.

### `NerfJournal/CategoryColor+Swatch.swift`

The whole file is two answers to module-boundary problems: an app-side extension that
keeps SwiftUI out of NerfCore, and the `typealias` that resolves the `ObjectiveC.Category`
ambiguity. Compare `cli/Sources/nerf/Database.swift` line 9.

### `NerfCore/Sources/NerfCore/JournalSync.swift` lines 108–130

The two initializers: production wiring and injected transport.

### `NerfCore/Tests/NerfCoreTests/JournalSyncTests.swift` lines 13–75

`Rig`, then a schema test and an end-to-end test that pushes a todo through the engine
to the scripted server and reads it back.

### `NerfCore/Tests/NerfCoreTests/TaskCodecTests.swift` lines 30–49 and 294–325

One table-style case, then the helpers with their `file:`/`line:` parameters.

---

## Exercises

**1.** Delete `Todo`'s hand-written `public init` from `Models.swift`. Run `swift build`
in `NerfCore/`: the library still compiles. Run `swift test` in the same directory: it
fails, though the tests live in NerfCore's own package. Build the app: it fails too.
Explain all three results with one rule, and say what the test target has in common with
the app that the library target doesn't.

**2.** Remove `typealias Category = NerfCore.Category` from
`CategoryColor+Swatch.swift` and build the app. Read the ambiguity error and find both
candidates it names. Then explain why the same app code compiled before `Category` moved
into NerfCore, using the shadowing rule.

**3.** Add `@testable import NerfCore` to `TaskCodecTests.swift` and write a direct test
of `TaskCodec.parseRFC3339`. It will work. Now argue against keeping it: what does the
existing test of `decode` already cover, and what would a refactor of the parsing
helpers cost if direct tests like yours existed?

**4.** In `checkEncodeNew`, remove the `file:` and `line:` arguments from the
`XCTAssertEqual` call (leave the parameters in place), then break one expected value in
`testEncodesPendingMigratingTodo` and run the tests. Where is the failure reported? Put
the arguments back and compare.

**5.** NerfCore depends on Jinx with `.package(path: "../../Jinx")`. Describe what
happens when someone clones NerfJournal alone and runs `swift build` in `cli/`. Then
weigh switching to a URL dependency with a version: what does it buy, and what does it
cost while Jinx and NerfJournal are being changed together?

**6.** `ScriptedServer` is a `final class` declared `Sendable`, with its mutable state in
a `Mutex<State>`. Sketch what the compiler would say if it held its state as ordinary
`var` properties instead. Then consider making it an `actor`: what would that do to
`JMAPTransport`'s requirements, which are already `async`, and to the test code that
calls `server.create(…)` synchronously in `Rig.init`?

**7.** The app has no tests. Using `Rig` as a model, sketch a test for `PageStore`: what
would it need to construct, where would the `@MainActor` default from Unit 12 show up in
the test, and which of `PageStore`'s dependencies would you want to inject instead of
using `AppDatabase.shared`?
