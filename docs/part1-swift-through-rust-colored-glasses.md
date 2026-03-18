# Part 1 — Swift Through Rust-Colored Glasses

You know Rust. You know its type system, its ownership model, its traits, its enums.
This part teaches you Swift by mapping every concept back to what you already understand.

The examples come from Hush — the same codebase you explored in Part 0. Every code
snippet references a real file, so you can open it and read the full context.

---

## Table of contents

- [Structs: value types (like Rust's Copy types)](#structs-value-types-like-rusts-copy-types)
- [Classes: reference types (like Rust's Box or Arc)](#classes-reference-types-like-rusts-box-or-arc)
- [Memory management: ARC vs Ownership](#memory-management-arc-vs-ownership)
- [Enums with associated values (nearly identical to Rust)](#enums-with-associated-values-nearly-identical-to-rust)
- [Optionals: Optional vs Option](#optionals-optional-vs-option)
- [Error handling: throws / do-catch vs Result](#error-handling-throws--do-catch-vs-result)
- [Protocols vs Traits](#protocols-vs-traits)
- [Generics](#generics)
- [Closures](#closures)
- [Access control](#access-control)
- [Property observers and computed properties](#property-observers-and-computed-properties)
- [Key syntax differences cheat sheet](#key-syntax-differences-cheat-sheet)

---

## Structs: value types (like Rust's Copy types)

In Rust, a struct that derives `Copy` has value semantics — assigning it to a new
variable copies the bits, and both copies are independent. In Swift, **all structs**
behave this way. There is no opt-in `Copy` trait. Every struct assignment, every function
argument pass, every return creates an independent copy (the compiler optimizes away
copies that are not needed, through copy-on-write for large types like `Array` and
`String`).

### Hush's AudioProcess struct

From `Hush/Model/AudioProcess.swift`:

```swift
struct AudioProcess: Identifiable, Hashable, @unchecked Sendable {
    let id: String              // bundleID, or "pid:<N>" for unbundled processes
    let objectIDs: [AudioObjectID]
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    var isRunningOutput: Bool

    static func == (lhs: AudioProcess, rhs: AudioProcess) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
```

The Rust equivalent would look like this:

```rust
#[derive(Clone)]
struct AudioProcess {
    id: String,
    object_ids: Vec<AudioObjectID>,
    pid: pid_t,
    bundle_id: Option<String>,
    name: String,
    icon: Option<NSImage>,
    is_running_output: bool,
}

impl PartialEq for AudioProcess {
    fn eq(&self, other: &Self) -> bool {
        self.id == other.id
    }
}

impl Hash for AudioProcess {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.id.hash(state);
    }
}
```

Key differences to notice:

| Concept | Rust | Swift |
|---|---|---|
| Value type | Must derive `Copy` or `Clone` | All structs are value types, always |
| Fields | Private by default | Internal (module-visible) by default |
| Naming | `snake_case` | `camelCase` |
| Optional fields | `Option<String>` | `String?` |
| Method receiver | `&self`, `&mut self` | `self` (immutable) or `mutating` |

### Mutability: `var` vs `let`

Swift splits mutability into two keywords at the binding site, much like Rust:

```
Rust:     let x = 5;       // immutable binding
          let mut x = 5;   // mutable binding

Swift:    let x = 5        // immutable binding  (like Rust's `let`)
          var x = 5        // mutable binding    (like Rust's `let mut`)
```

In `AudioProcess`, most fields use `let` (immutable after initialization), but
`isRunningOutput` uses `var` because the monitor updates it over time.

There is a critical difference, though. In Rust, `let x = some_struct;` means `x` is
immutable — you cannot mutate any of its fields. In Swift, the same rule applies to
`let`, but with **value types**, `let` means the entire value is frozen:

```swift
let process = AudioProcess(/* ... */)
process.isRunningOutput = true  // ERROR: cannot assign to property of 'let' value

var process = AudioProcess(/* ... */)
process.isRunningOutput = true  // OK: var binding allows mutation
```

This is analogous to Rust's behavior: you cannot mutate a field of a `let` binding
without `mut`.

### Method syntax: `func` and `mutating func`

Swift methods take an implicit `self` parameter, like Rust's `&self`. But because structs
are value types, mutating a struct method requires the `mutating` keyword — otherwise the
compiler prevents you from changing `self`.

```swift
struct Counter {
    var count = 0

    func display() {           // like fn display(&self) in Rust
        print(count)
    }

    mutating func increment() { // like fn increment(&mut self) in Rust
        count += 1
    }
}
```

In `AudioProcess`, the `hash(into:)` method takes `inout Hasher` — that `inout` keyword
is Swift's version of `&mut`. The hasher is passed by mutable reference, modified, and
the caller sees the changes:

```swift
func hash(into hasher: inout Hasher) {   // hasher: &mut Hasher
    hasher.combine(id)
}
```

> **Rust parallel**: `inout` is the closest Swift gets to `&mut`. The difference is that
> Swift implements `inout` as copy-in/copy-out — the value is copied into the function,
> mutated, then copied back. The compiler optimizes this to pass-by-reference in practice,
> but the semantics are copy-based, not borrow-based. There is no borrow checker ensuring
> exclusive access at compile time.

### Further reading

- [The Swift Programming Language — Structures and Classes](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/)
- [Value and Reference Types (swift.org)](https://www.swift.org/documentation/articles/value-and-reference-types.html)

---

## Classes: reference types (like Rust's Box or Arc)

While structs copy on assignment, **classes** share on assignment. When you assign a class
instance to a new variable, both variables point to the same heap-allocated object. This
is like Rust's `Arc<T>` — multiple owners, shared reference, heap-allocated.

```
┌──────────────────────────────────────────────────────────┐
│                    Value Type (struct)                     │
│                                                           │
│   let a = AudioProcess(...)                               │
│   var b = a              // b is an independent copy      │
│                                                           │
│   Stack:   ┌─────┐      ┌─────┐                          │
│            │  a  │      │  b  │   (separate memory)       │
│            └─────┘      └─────┘                           │
│                                                           │
│   Mutating b does NOT affect a.                           │
├──────────────────────────────────────────────────────────┤
│                   Reference Type (class)                   │
│                                                           │
│   let a = AudioTapManager()                               │
│   let b = a              // b points to the SAME object   │
│                                                           │
│   Stack:   ┌─────┐      ┌─────┐                          │
│            │  a ─┼──┐   │  b ─┼──┐                       │
│            └─────┘  │   └─────┘  │                        │
│                     │            │                         │
│   Heap:             └──►┌───────┐◄┘                       │
│                         │ Object │  (refcount: 2)         │
│                         └───────┘                         │
│                                                           │
│   Mutating through b DOES affect what a sees.             │
└──────────────────────────────────────────────────────────┘
```

### Hush's classes

Hush uses classes for two things: objects with identity that manage long-lived system
resources.

From `Hush/Audio/AudioTapManager.swift`:

```swift
@MainActor
final class AudioTapManager {
    private var sessions: [String: TapSession] = [:]

    func mute(processID: String, objectIDs: [AudioObjectID]) throws { ... }
    func unmute(processID: String) { ... }
    func teardownAll() { ... }
    private func teardown(_ session: TapSession) { ... }
}
```

From `Hush/Audio/AudioProcessMonitor.swift`:

```swift
@MainActor
final class AudioProcessMonitor {
    var onChange: (([AudioProcess]) -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var pollTimer: Timer?

    func enumerateProcesses() -> [AudioProcess] { ... }
    func startListening() { ... }
    func stopListening() { ... }
}
```

In Rust terms, these would be:

```rust
// You would not write this exact code — Rust uses ownership, not ref-counting.
// But conceptually, sharing a class instance is like sharing an Arc.
let tap_manager = Arc::new(Mutex::new(AudioTapManager::new()));
let shared = Arc::clone(&tap_manager);  // both point to the same allocation
```

### When to use class vs struct

Apple provides clear guidance in
[Choosing Between Structures and Classes](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes).
The summary:

| Use a **struct** when... | Use a **class** when... |
|---|---|
| The type represents data (a value) | The type represents a unique resource |
| You want copies to be independent | You need shared mutable state |
| Equality is based on values | Identity matters (this *specific* object) |
| No inheritance needed | You need inheritance or `deinit` |

In Hush:
- `AudioProcess` is a **struct** — it is data. Two processes with the same `id` are
  equivalent regardless of where they live in memory.
- `AudioTapManager` is a **class** — it owns Core Audio tap sessions. You do not want
  two copies of a tap manager independently tearing down the same audio taps.
- `AudioProcessMonitor` is a **class** — it holds a Core Audio listener registration
  and a timer. These are system resources tied to *this specific instance*.

### The `final` keyword

Both `AudioTapManager` and `AudioProcessMonitor` are marked `final`. In Swift, classes
can be subclassed by default (unlike Rust, where there is no inheritance). `final` prevents
subclassing — it locks the class down.

```swift
final class AudioTapManager { ... }   // cannot be subclassed

class AudioTapManager { ... }         // can be subclassed (default)
```

Think of `final` as the *default* behavior in Rust. Rust structs cannot be "subclassed"
at all. In Swift, `final` is what you use to opt into that rigidity. Apple recommends
starting with `final` and removing it only when you have a concrete need for subclassing.
The compiler can also generate faster method dispatch for `final` classes (static dispatch
instead of vtable lookup, like Rust's monomorphization vs `dyn Trait`).

### Further reading

- [Choosing Between Structures and Classes](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes)
- [The Swift Programming Language — Structures and Classes](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/)

---

## Memory management: ARC vs Ownership

This is where Swift and Rust diverge the most. Rust uses ownership and borrowing — a
compile-time system with zero runtime cost. Swift uses **Automatic Reference Counting
(ARC)** — a runtime system that tracks how many references point to each heap object.

```
┌───────────────────────────────────────────────────────────────────┐
│                    Rust: Compile-time Ownership                    │
│                                                                    │
│   let a = Box::new(Object::new());                                │
│   let b = a;            // MOVE. a is now invalid.                │
│   // println!("{}", a); // ERROR: use of moved value              │
│   drop(b);              // Object freed here. Deterministic.      │
│                                                                    │
│   The compiler tracks ownership. No runtime overhead.             │
├───────────────────────────────────────────────────────────────────┤
│                    Swift: Automatic Reference Counting             │
│                                                                    │
│   let a = Object()      // refcount = 1                           │
│   let b = a             // refcount = 2 (both point to same obj)  │
│   // a goes out of scope → refcount = 1                           │
│   // b goes out of scope → refcount = 0 → object freed            │
│                                                                    │
│   The runtime maintains a counter. Small overhead per assign/copy.│
└───────────────────────────────────────────────────────────────────┘
```

ARC applies only to **class instances** (reference types). Structs are value types — they
live on the stack (or are inlined) and are freed when they go out of scope, exactly like
Rust structs that do not implement `Drop` with heap allocations.

### Reference counting lifecycle

```
   let a = MyClass()         refcount: 1
        │
        ▼
   let b = a                 refcount: 2
        │
        ▼
   b goes out of scope       refcount: 1
        │
        ▼
   a goes out of scope       refcount: 0  →  deinit called  →  memory freed
```

This is deterministic — unlike garbage collection (Java, Go, Python), you know exactly
when the object will be freed: the moment the last reference disappears. This is the
same guarantee Rust gives with `Drop`, but achieved through counting rather than
compile-time analysis.

### Strong, weak, and unowned references

Here is where it gets interesting. ARC's default references are **strong** — they
increment the reference count. But sometimes you need a reference that does *not* keep
the object alive.

| Reference type | Rust analogy | Increments refcount? | What happens when object is freed? |
|---|---|---|---|
| Strong (default) | `Arc<T>` | Yes | Keeps object alive |
| `weak` | `Weak<T>` (from `Arc::downgrade`) | No | Becomes `nil` automatically |
| `unowned` | Raw pointer with a contract | No | Crash if accessed (undefined behavior) |

Rust's `Weak<T>` requires you to call `.upgrade()` to get an `Option<Arc<T>>`. Swift's
`weak` does the same thing — the reference becomes an optional that is `nil` when the
object has been freed:

```swift
weak var delegate: SomeClass?   // becomes nil when SomeClass is freed
```

`unowned` is the dangerous option. It is like a raw pointer that promises the object will
outlive the reference. If that promise is broken, your program crashes. Use it only when
you can guarantee the lifetime relationship.

### The `[weak self]` pattern in Hush

This is the most important Swift memory pattern you will encounter. When a closure
captures `self` (a class instance) strongly, and the class also holds a reference to the
closure, you get a **retain cycle** — a circular reference where the refcount never
reaches zero and the object is never freed.

From `Hush/ViewModel/AppListViewModel.swift`:

```swift
init() {
    // ...
    monitor.onChange = { [weak self] processes in
        Task { @MainActor [weak self] in
            self?.handleProcessUpdate(processes)
        }
    }
    monitor.startListening()
    startDeviceListener()
    // ...
}
```

Why `[weak self]`? Because `AppListViewModel` owns the `monitor`, and the `monitor` holds
the `onChange` closure. If that closure captured `self` strongly, you would get:

```
WITHOUT [weak self] — retain cycle (memory leak):

   ┌────────────────────┐         ┌────────────────────────┐
   │ AppListViewModel   │ ──────► │ AudioProcessMonitor    │
   │                    │  strong │                        │
   │  refcount: 2       │         │  onChange closure ──┐  │
   └────────────────────┘         └────────────────────┤──┘
            ▲                                          │
            │                 strong                    │
            └──────────────────────────────────────────┘

   Neither refcount ever reaches 0. Both objects leak.

WITH [weak self] — no cycle:

   ┌────────────────────┐         ┌────────────────────────┐
   │ AppListViewModel   │ ──────► │ AudioProcessMonitor    │
   │                    │  strong │                        │
   │  refcount: 1       │         │  onChange closure ──┐  │
   └────────────────────┘         └────────────────────┤──┘
            ▲                                          │
            │                  weak                     │
            └ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┘

   When AppListViewModel is freed, refcount → 0.
   The weak reference becomes nil. No cycle.
```

The same pattern appears in `startDeviceListener()`:

```swift
private func startDeviceListener() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.handleDeviceChange()
        }
    }
    // ...
}
```

And in `AudioProcessMonitor.startListening()`:

```swift
func startListening() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.fireUpdate()
        }
    }
    // ...
    pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
            self?.fireUpdate()
        }
    }
}
```

Notice the pattern: `{ [weak self] ... in self?.someMethod() }`. Because `self` is weak,
it becomes an optional — you must use `self?.` (optional chaining) to call methods on it.
If the object has already been freed, `self` is `nil`, and the call does nothing.

> **Rust parallel**: This entire category of bugs — retain cycles — does not exist in
> Rust. The ownership model makes circular references impossible without explicit escape
> hatches like `Rc<RefCell<T>>` or `Arc<Mutex<T>>`, and even those require deliberate
> effort to create cycles. In Swift, retain cycles are the most common source of memory
> leaks, and `[weak self]` is your primary defense.

### Further reading

- [The Swift Programming Language — Automatic Reference Counting](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/)
- [WWDC 2021 — ARC in Swift: Basics and beyond](https://developer.apple.com/videos/play/wwdc2021/10216/)

---

## Enums with associated values (nearly identical to Rust)

If there is one feature where Swift and Rust feel almost identical, it is enums. Swift
enums are algebraic data types (sum types) — each variant can carry different associated
data, and you pattern-match to extract it.

### Hush's error enums

From `Hush/Audio/CoreAudioHelpers.swift`:

```swift
enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus)
    case propertyNotFound
    case ioProcCreationFailed

    var errorDescription: String? {
        switch self {
        case .osStatus(let code):
            if let meaning = Self.knownCodes[code] {
                return "CoreAudio: \(meaning) (\(code))"
            }
            return "CoreAudio error: \(code)"
        case .propertyNotFound:
            return "Audio property not found"
        case .ioProcCreationFailed:
            return "Failed to create audio IO procedure"
        }
    }
}
```

The Rust equivalent:

```rust
#[derive(Debug)]
enum CoreAudioError {
    OsStatus(OSStatus),
    PropertyNotFound,
    IoProcCreationFailed,
}

impl Display for CoreAudioError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            CoreAudioError::OsStatus(code) => {
                if let Some(meaning) = KNOWN_CODES.get(code) {
                    write!(f, "CoreAudio: {} ({})", meaning, code)
                } else {
                    write!(f, "CoreAudio error: {}", code)
                }
            }
            CoreAudioError::PropertyNotFound => write!(f, "Audio property not found"),
            CoreAudioError::IoProcCreationFailed => {
                write!(f, "Failed to create audio IO procedure")
            }
        }
    }
}
```

From `Hush/ViewModel/AppListViewModel.swift`:

```swift
enum HushError {
    case permissionDenied
    case muteFailed(processName: String, detail: String)

    var message: String {
        switch self {
        case .permissionDenied:
            return "Hush needs Screen & System Audio Recording permission..."
        case .muteFailed(let name, let detail):
            return "Failed to mute \(name): \(detail)"
        }
    }
}
```

Notice the syntax differences:

| Concept | Rust | Swift |
|---|---|---|
| Variant with data | `OsStatus(OSStatus)` | `case osStatus(OSStatus)` |
| Variant without data | `PropertyNotFound` | `case propertyNotFound` |
| Named associated values | Not supported | `case muteFailed(processName: String, detail: String)` |
| Pattern match keyword | `match` | `switch` |

Swift allows **named** associated values (`processName: String`), while Rust enum
variants use positional fields or struct-like variants. Named associated values make
pattern matching more readable — `case .muteFailed(let name, let detail)` reads like
documentation.

### Pattern matching with `switch`

Swift's `switch` is exhaustive, like Rust's `match` — the compiler forces you to handle
every case, or provide a `default`:

```swift
switch self {
    case .osStatus(let code):   // binds the associated value to `code`
        // handle it
    case .propertyNotFound:
        // handle it
    case .ioProcCreationFailed:
        // handle it
}
// No `default` needed — all cases covered. Compiler enforces this.
```

This is identical to Rust:

```rust
match self {
    CoreAudioError::OsStatus(code) => { /* ... */ }
    CoreAudioError::PropertyNotFound => { /* ... */ }
    CoreAudioError::IoProcCreationFailed => { /* ... */ }
}
```

### `if case let` and `guard case let`

When you want to check a single variant without writing a full `switch`, Swift provides
`if case let` and `guard case let`. These are partial matches — **not** exhaustive.

From `Hush/Audio/CoreAudioHelpers.swift` — the `isPermissionError` property:

```swift
var isPermissionError: Bool {
    guard case .osStatus(let code) = self else { return false }
    return code == -66753 || code == -66748
}
```

This reads as: "If `self` is `.osStatus`, bind the associated value to `code` and
continue. Otherwise, return `false`."

In Rust, you would write:

```rust
fn is_permission_error(&self) -> bool {
    if let CoreAudioError::OsStatus(code) = self {
        code == -66753 || code == -66748
    } else {
        false
    }
}
```

And from `Hush/Views/MenuContentView.swift` — the error banner:

```swift
if case .permissionDenied = error {
    Button("Open System Settings") {
        viewModel.openAudioPrivacySettings()
    }
}
```

This checks whether `error` is the `.permissionDenied` variant without binding any
values. In Rust: `if let HushError::PermissionDenied = error { ... }`.

### Further reading

- [The Swift Programming Language — Enumerations](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/enumerations/)
- [The Swift Programming Language — Patterns](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/patterns/)

---

## Optionals: `Optional<T>` vs `Option<T>`

Swift's `Optional<T>` is syntactically and semantically almost identical to Rust's
`Option<T>`. It is an enum with two cases:

```swift
enum Optional<Wrapped> {
    case none       // Rust: None
    case some(Wrapped)  // Rust: Some(T)
}
```

The syntax sugar `T?` is equivalent to `Optional<T>`, and `nil` is equivalent to `.none`.

### Unwrapping patterns

Here is every way to work with optionals in Swift, mapped to the Rust equivalent:

**`if let` — conditional unwrapping (identical to Rust)**

From `Hush/Views/AudioProcessRow.swift`:

```swift
if let icon = process.icon {
    Image(nsImage: icon)      // icon is NSImage, not NSImage?
} else {
    Image(systemName: "app.fill")
}
```

Rust:
```rust
if let Some(icon) = process.icon {
    Image::new(icon)
} else {
    Image::system("app.fill")
}
```

**`guard let` — early return on nil (like Rust's `let ... else`)**

From `Hush/Audio/AudioProcessMonitor.swift`:

```swift
guard let onChange else { return }
let processes = enumerateProcesses()
onChange(processes)
```

This says: "If `onChange` is `nil`, return early. Otherwise, bind the unwrapped value to
`onChange` for the rest of the scope." Rust's equivalent (stabilized in Rust 1.65):

```rust
let Some(on_change) = self.on_change.as_ref() else { return };
let processes = self.enumerate_processes();
on_change(processes);
```

**`??` — nil-coalescing (like `.unwrap_or()`)**

From `Hush/Audio/AudioProcessMonitor.swift`:

```swift
let isRunning: UInt32 = (try? CoreAudioHelper.propertyData(from: oid, address: runAddr)) ?? 0
```

If the property query fails or returns `nil`, use `0` as the default. In Rust:

```rust
let is_running: u32 = CoreAudioHelper::property_data(oid, &run_addr).unwrap_or(0);
```

And from `Hush/Views/MenuContentView.swift`:

```swift
Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
```

Multiple optionals chained together — get the info dictionary (optional), subscript it
(returns optional `Any?`), cast to `String` (optional), and if any step fails, use
`"1.0"`. In Rust you would chain `.and_then()` calls or use `?` in an inner block.

**`!` — force unwrap (like `.unwrap()`)**

```swift
let value: String = optionalString!   // crashes if nil
```

This is Swift's `.unwrap()`. It crashes at runtime with a fatal error if the optional is
`nil`. Treat it with the same caution you treat `.unwrap()` in Rust — it has legitimate
uses (in tests, or when you can prove the value is non-nil), but reach for `if let` or
`guard let` first.

Hush avoids force unwraps in most places, preferring `guard let` and `??`.

**`?.` — optional chaining**

From the `[weak self]` patterns throughout Hush:

```swift
self?.handleProcessUpdate(processes)
self?.fireUpdate()
self?.handleDeviceChange()
```

Optional chaining propagates `nil` through a chain of calls. If `self` is `nil`, the
entire expression evaluates to `nil` and nothing happens. This is like Rust's `.map()`
on `Option`, but with method-call syntax:

```rust
// Rust doesn't have optional chaining syntax, but the concept is:
if let Some(this) = self_weak.upgrade() {
    this.handle_process_update(processes);
}
```

There is another example from `Hush/ViewModel/AppListViewModel.swift`:

```swift
if let url = URL(string: "x-apple.systempreferences:...") {
    NSWorkspace.shared.open(url)
}
```

`URL(string:)` returns an `Optional<URL>` — the string might not be a valid URL. The
`if let` unwraps it safely.

### Summary table

| Operation | Rust | Swift |
|---|---|---|
| Declare optional | `Option<T>` | `T?` or `Optional<T>` |
| None/nil value | `None` | `nil` or `.none` |
| Conditional unwrap | `if let Some(x) = opt` | `if let x = opt` |
| Early return on none | `let Some(x) = opt else { return }` | `guard let x = opt else { return }` |
| Default value | `.unwrap_or(default)` | `?? default` |
| Force unwrap (crash) | `.unwrap()` | `!` |
| Map/transform | `.map(\|x\| x.foo())` | `opt?.foo()` (chaining) |
| Flat map | `.and_then(\|x\| x.bar())` | `opt?.bar()` (auto-flattening) |

### Further reading

- [The Swift Programming Language — Optionals](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/thebasics/#Optionals)
- [The Swift Programming Language — Optional Chaining](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/optionalchaining/)

---

## Error handling: `throws` / `do-catch` vs `Result<T, E>`

Rust uses `Result<T, E>` as the primary error handling mechanism. Errors are values.
You return them, match on them, propagate them with `?`.

Swift takes a different approach: **thrown errors**. A function marked `throws` can
throw an error, and the caller must handle it with `do { try ... } catch { ... }`.

The key insight: Swift's `throws` is syntactic sugar for something very close to Rust's
`Result`. Under the hood, a `throws` function either returns a value or returns an error.
The `try` keyword at the call site is like Rust's `?` — it marks the point where an
error can occur.

### Hush's throwing functions

From `Hush/Audio/CoreAudioHelpers.swift`:

```swift
static func propertyData<T>(from objectID: AudioObjectID,
                             address: AudioObjectPropertyAddress) throws -> T {
    var address = address
    var size: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                 alignment: MemoryLayout<T>.alignment)
    defer { data.deallocate() }

    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, data)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    return data.load(as: T.self)
}
```

The Rust equivalent:

```rust
fn property_data<T>(object_id: AudioObjectID,
                    address: &AudioObjectPropertyAddress) -> Result<T, CoreAudioError> {
    // ...
    if status != NO_ERR {
        return Err(CoreAudioError::OsStatus(status));
    }
    // ...
    Ok(data)
}
```

Notice `defer { data.deallocate() }` — this is Swift's equivalent of Rust's `Drop` trait
or a scoped guard. It runs when the current scope exits, regardless of whether it exits
normally or via a thrown error. Like Rust's RAII, `defer` ensures cleanup happens.

### Calling throwing functions

From `Hush/ViewModel/AppListViewModel.swift` — the `toggleMute` method:

```swift
func toggleMute(for process: AudioProcess) {
    if mutedProcessIDs.contains(process.id) {
        tapManager.unmute(processID: process.id)
        // ... cleanup ...
    } else {
        do {
            try tapManager.mute(processID: process.id, objectIDs: process.objectIDs)
            mutedProcessIDs.insert(process.id)
            // ... more state updates ...
        } catch let err {
            if let caErr = err as? CoreAudioError, caErr.isPermissionError {
                self.error = .permissionDenied
            } else {
                self.error = .muteFailed(processName: process.name,
                                         detail: err.localizedDescription)
            }
        }
    }
}
```

In Rust:

```rust
fn toggle_mute(&mut self, process: &AudioProcess) {
    if self.muted_process_ids.contains(&process.id) {
        self.tap_manager.unmute(&process.id);
        // ...
    } else {
        match self.tap_manager.mute(&process.id, &process.object_ids) {
            Ok(()) => {
                self.muted_process_ids.insert(process.id.clone());
                // ...
            }
            Err(err) => {
                if let Some(ca_err) = err.downcast_ref::<CoreAudioError>() {
                    if ca_err.is_permission_error() {
                        self.error = Some(HushError::PermissionDenied);
                    }
                } else {
                    self.error = Some(HushError::MuteFailed { ... });
                }
            }
        }
    }
}
```

### `try?` — converting errors to optionals

Swift's `try?` discards the error and converts the result to an optional. It is exactly
like Rust's `.ok()` method on `Result`:

From `Hush/Audio/AudioProcessMonitor.swift`:

```swift
guard let pid: pid_t = try? CoreAudioHelper.propertyData(from: oid, address: pidAddr)
    else { continue }
```

Rust: `let Some(pid) = CoreAudioHelper::property_data(oid, &pid_addr).ok() else { continue };`

And:

```swift
let bundleID = try? CoreAudioHelper.stringProperty(from: oid, address: bidAddr)
```

Rust: `let bundle_id = CoreAudioHelper::string_property(oid, &bid_addr).ok();`

### Error propagation — `try` vs `?`

In Rust, `?` propagates the error to the caller. Swift uses `try` at the call site with a
`throws` on the function signature:

```swift
// Swift: try marks the call, throws marks the function
static func defaultOutputDeviceUID() throws -> String {
    let deviceID: AudioObjectID = try propertyData(
        from: AudioObjectID(kAudioObjectSystemObject),
        address: AudioObjectPropertyAddress(...)
    )
    return try stringProperty(from: deviceID, address: AudioObjectPropertyAddress(...))
}
```

```rust
// Rust: ? propagates the error, Result marks the return type
fn default_output_device_uid() -> Result<String, CoreAudioError> {
    let device_id: AudioObjectID = property_data(
        AudioObjectID(AUDIO_OBJECT_SYSTEM_OBJECT),
        &AudioObjectPropertyAddress { ... },
    )?;
    string_property(device_id, &AudioObjectPropertyAddress { ... })
}
```

The mental model is the same — mark where errors can happen, and the compiler ensures
the caller deals with them. The syntactic difference is that Rust puts the `?` *after* the
call, while Swift puts `try` *before* it.

One important difference: Swift does not have Rust's `?` operator for *composing* errors
up through call chains in the same terse way. Each `try` call either succeeds inline or
jumps to the nearest `catch` block. There is no automatic `From` conversion between error
types like Rust's `impl From<IoError> for MyError`.

### Comparison table

| Concept | Rust | Swift |
|---|---|---|
| Function that can fail | `fn foo() -> Result<T, E>` | `func foo() throws -> T` |
| Call a fallible function | `foo()?` | `try foo()` |
| Handle the error | `match foo() { Ok(v) => ..., Err(e) => ... }` | `do { try foo() } catch { ... }` |
| Discard error, get optional | `foo().ok()` | `try? foo()` |
| Crash on error | `foo().unwrap()` | `try! foo()` |
| Scoped cleanup | `Drop` trait / scope guards | `defer { }` |

### Further reading

- [The Swift Programming Language — Error Handling](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/)

---

## Protocols vs Traits

Swift's **protocols** are Rust's **traits**. They define a set of requirements (methods,
properties, associated types) that conforming types must implement. The analogy is close
enough that you can read "protocol" as "trait" almost everywhere.

### Hush's protocol conformances

From `Hush/Model/AudioProcess.swift`:

```swift
struct AudioProcess: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    // ...
}
```

This declares that `AudioProcess` conforms to three protocols. In Rust:

```rust
// Identifiable requires an `id` property
// Hashable requires hash(into:)
// Sendable is a marker trait for thread safety
struct AudioProcess: Identifiable + Hash + Send { ... }
// (not real Rust syntax, but the concept)
```

**`Identifiable`** requires a property `var id: SomeType`. It is used by SwiftUI's
`ForEach` to track items in a list — similar to needing a key in React, or implementing a
stable ID for diffing algorithms. In Rust, you might express this as:

```rust
trait Identifiable {
    type ID: Hashable;
    fn id(&self) -> &Self::ID;
}
```

**`Hashable`** requires `func hash(into hasher: inout Hasher)`. Identical to Rust's
`Hash` trait:

```rust
trait Hash {
    fn hash<H: Hasher>(&self, state: &mut H);
}
```

### `LocalizedError` — like implementing Display for errors

From `Hush/Audio/CoreAudioHelpers.swift`:

```swift
enum CoreAudioError: LocalizedError {
    // ...
    var errorDescription: String? {
        switch self {
        case .osStatus(let code):
            return "CoreAudio error: \(code)"
        case .propertyNotFound:
            return "Audio property not found"
        case .ioProcCreationFailed:
            return "Failed to create audio IO procedure"
        }
    }
}
```

`LocalizedError` is a protocol that provides a human-readable error description. This is
Swift's equivalent of implementing `Display` (and `Error`) for your error types in Rust:

```rust
impl fmt::Display for CoreAudioError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        match self {
            Self::OsStatus(code) => write!(f, "CoreAudio error: {}", code),
            Self::PropertyNotFound => write!(f, "Audio property not found"),
            Self::IoProcCreationFailed => write!(f, "Failed to create audio IO procedure"),
        }
    }
}

impl Error for CoreAudioError {}
```

### Protocol extensions (default trait implementations)

Swift protocols can have default implementations through **protocol extensions**. This
is exactly like Rust's default method implementations in traits:

```swift
// Swift
protocol Describable {
    var description: String { get }
}

extension Describable {
    var description: String { "No description" }  // default implementation
}
```

```rust
// Rust
trait Describable {
    fn description(&self) -> &str {
        "No description"  // default implementation
    }
}
```

Many of Swift's standard library protocols use extensions to provide default behavior.
`Equatable` can auto-synthesize `==` for structs (like Rust's `#[derive(PartialEq)]`),
`Hashable` can auto-synthesize `hash(into:)` (like `#[derive(Hash)]`).

### `some View` — opaque return types (like `impl Trait`)

From `Hush/Views/MenuContentView.swift`:

```swift
private var header: some View {
    HStack(alignment: .firstTextBaseline) {
        Text("Hush")
            .font(.headline)
        // ...
    }
}
```

The `some View` return type means "this property returns a value that conforms to the
`View` protocol, but the caller does not know the concrete type." This is identical to
Rust's `impl Trait` in return position:

```rust
fn header(&self) -> impl View {
    HStack::new(/* ... */)
}
```

The compiler knows the concrete type (it is fixed per call site), which enables static
dispatch and optimization. But the caller works with it only through the `View` protocol.

Why not name the concrete type? Because SwiftUI view types are deeply nested generic
types like `VStack<TupleView<(HStack<...>, Text, Spacer)>>`. Writing them out would be
impractical. `some View` hides this complexity, exactly as `impl Iterator<Item = u32>`
saves you from writing `std::iter::Map<std::slice::Iter<'_, i32>, fn(&i32) -> u32>` in
Rust.

### Further reading

- [The Swift Programming Language — Protocols](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/)
- [The Swift Programming Language — Opaque and Boxed Types](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/opaquetypes/)

---

## Generics

Swift generics work almost identically to Rust generics. The syntax is so similar that
you can read Swift generic code with minimal translation.

### Hush's generic functions

From `Hush/Audio/CoreAudioHelpers.swift`:

```swift
static func propertyData<T>(from objectID: AudioObjectID,
                             address: AudioObjectPropertyAddress) throws -> T {
    // ...
    let data = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<T>.alignment
    )
    defer { data.deallocate() }
    // ...
    return data.load(as: T.self)
}
```

Rust equivalent:

```rust
fn property_data<T>(object_id: AudioObjectID,
                    address: &AudioObjectPropertyAddress) -> Result<T, CoreAudioError> {
    // ...
    let layout = Layout::from_size_align(size, align_of::<T>()).unwrap();
    let data = alloc(layout);
    // ...
}
```

And the array variant:

```swift
static func propertyArray<T>(from objectID: AudioObjectID,
                              address: AudioObjectPropertyAddress) throws -> [T] {
    // ...
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }

    let data = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<T>.alignment
    )
    defer { data.deallocate() }
    // ...
    let buffer = data.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}
```

Notice `MemoryLayout<T>.stride` and `MemoryLayout<T>.alignment` — these are Swift's
equivalents of `std::mem::size_of::<T>()` and `std::mem::align_of::<T>()`. The syntax
is different (`MemoryLayout<T>.stride` vs `size_of::<T>()`), but the semantics are the
same.

### Type constraints

Swift uses `:` where Rust uses `:` — the syntax is nearly identical:

```swift
// Swift
func process<T: Hashable>(items: [T]) -> Set<T> { ... }

// Rust
fn process<T: Hash>(items: &[T]) -> HashSet<T> { ... }
```

### `where` clauses

Both languages support `where` clauses for more complex constraints:

```swift
// Swift
func merge<T, U>(a: T, b: U) -> String where T: CustomStringConvertible, U: CustomStringConvertible {
    "\(a) and \(b)"
}

// Rust
fn merge<T, U>(a: T, b: U) -> String where T: Display, U: Display {
    format!("{} and {}", a, b)
}
```

### Key differences

| Concept | Rust | Swift |
|---|---|---|
| Syntax | `fn foo<T: Trait>()` | `func foo<T: Protocol>()` |
| Size info | `std::mem::size_of::<T>()` | `MemoryLayout<T>.size` |
| Stride info | `std::mem::size_of::<T>()` (same as size for most) | `MemoryLayout<T>.stride` (includes padding) |
| Alignment | `std::mem::align_of::<T>()` | `MemoryLayout<T>.alignment` |
| Turbofish | `foo::<u32>()` | Not needed — Swift infers or uses `foo() as Type` |
| Monomorphization | Yes (always) | Yes for most cases; dynamic dispatch for protocol existentials |

One notable difference: Swift does not have the turbofish syntax (`::<>`). When type
inference cannot determine the generic parameter, you use type annotation at the call
site:

```swift
let deviceID: AudioObjectID = try propertyData(from: systemObject, address: addr)
//            ^^^^^^^^^^^^^^  type annotation guides inference
```

In Rust, you would write: `let device_id = property_data::<AudioObjectID>(&system_object, &addr)?;`

### Further reading

- [The Swift Programming Language — Generics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/)

---

## Closures

Swift closures are anonymous functions, like Rust closures. The syntax is different, and
the capture semantics are fundamentally different due to the absence of a borrow checker.

### Syntax comparison

```swift
// Swift: { (parameters) -> ReturnType in body }
let double = { (x: Int) -> Int in x * 2 }

// Rust: |parameters| -> ReturnType { body }
let double = |x: i32| -> i32 { x * 2 };
```

Swift uses `{ }` as the outer delimiters and `in` to separate parameters from the body.
Rust uses `| |` for parameters and `{ }` for the body.

### Trailing closure syntax

When the last parameter of a function is a closure, Swift lets you write it outside the
parentheses. This is used extensively in SwiftUI.

From `Hush/Views/AudioProcessRow.swift`:

```swift
AudioProcessRow(
    process: process,
    isMuted: viewModel.mutedProcessIDs.contains(process.id)
) {
    viewModel.toggleMute(for: process)
}
```

The `{ viewModel.toggleMute(for: process) }` block is the `onToggle` closure passed as
the last parameter. Without trailing closure syntax, it would be:

```swift
AudioProcessRow(
    process: process,
    isMuted: viewModel.mutedProcessIDs.contains(process.id),
    onToggle: { viewModel.toggleMute(for: process) }
)
```

Rust does not have trailing closure syntax. You always pass closures as regular arguments.

### Capture semantics — the critical difference

In Rust, closures capture variables by reference (`Fn`/`FnMut`) or by move (`FnOnce`/
`move` keyword). The borrow checker enforces that references are valid.

In Swift, closures **capture reference types (classes) by strong reference** by default.
This means the closure keeps the object alive. There is no borrow checker to prevent
dangling references — instead, Swift uses `[weak self]` and `[unowned self]` capture
lists to control how `self` is captured.

### Capture lists in Hush

From `Hush/Audio/AudioProcessMonitor.swift`:

```swift
pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.fireUpdate()
    }
}
```

The `[weak self]` before the parameter list is a **capture list**. It tells the closure
to capture `self` weakly (not incrementing the reference count).

Without the capture list, the closure would capture `self` strongly, creating a retain
cycle: the timer holds the closure, the closure holds `self`, and `self` holds the timer.

```
Rust mental model:

   // In Rust, you would use Arc + Weak explicitly
   let weak_self = Arc::downgrade(&self_arc);
   timer.schedule(move || {
       if let Some(this) = weak_self.upgrade() {
           this.fire_update();
       }
   });
```

From `Hush/ViewModel/AppListViewModel.swift`:

```swift
monitor.onChange = { [weak self] processes in
    Task { @MainActor [weak self] in
        self?.handleProcessUpdate(processes)
    }
}
```

The pattern is always the same: `{ [weak self] parameters in ... self?.method() }`.
This is the single most common Swift idiom you will see in real codebases.

### `@escaping` closures

When a closure outlives the function that receives it — stored in a property, dispatched
asynchronously — it must be marked `@escaping`:

```swift
var onChange: (([AudioProcess]) -> Void)?   // stored property — escaping by nature
```

The `onChange` closure in `AudioProcessMonitor` is stored and called later, so it escapes
the scope where it was created. In Rust, this is like requiring a closure to be `'static`:

```rust
// Rust: closure must be 'static to be stored
on_change: Option<Box<dyn Fn(Vec<AudioProcess>) + 'static>>,
```

A non-escaping closure (the default in function parameters) is like a closure that borrows
from the current stack frame — it cannot outlive the function call. Swift's compiler
enforces this distinction at the type level.

### Higher-order function patterns

From `Hush/Audio/AudioProcessMonitor.swift`:

```swift
return grouped
    .filter { $0.value.isRunningOutput }
    .map { key, info in
        AudioProcess(
            id: key,
            objectIDs: info.objectIDs,
            // ...
        )
    }
    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
```

The `$0` and `$1` are Swift's shorthand for closure parameters by position. `$0` is the
first parameter, `$1` is the second. Rust does not have this — you always name your
closure parameters.

```rust
// Rust equivalent
grouped.into_iter()
    .filter(|(_, info)| info.is_running_output)
    .map(|(key, info)| AudioProcess {
        id: key,
        object_ids: info.object_ids,
        // ...
    })
    .sorted_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
    .collect()
```

And from `Hush/Audio/AudioTapManager.swift`:

```swift
sessions.values.forEach { teardown($0) }
```

### Further reading

- [The Swift Programming Language — Closures](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures/)

---

## Access control

Swift's access control model is simpler than Rust's, with fewer levels but a different
default.

### The levels

| Swift | Rust equivalent | Meaning |
|---|---|---|
| `private` | (no equivalent — closest is a private field) | Visible only within the enclosing declaration |
| `fileprivate` | `pub(super)` (approximate) | Visible within the same source file |
| `internal` (default) | `pub(crate)` | Visible within the same module (app/framework) |
| `public` | `pub` | Visible outside the module, but cannot be subclassed/overridden |
| `open` | (no Rust equivalent) | Visible outside the module AND can be subclassed/overridden |

The most important difference: **Swift defaults to `internal`**, while **Rust defaults to
private**. In a single-target app like Hush, `internal` means "visible everywhere in the
app." This is why Hush's code does not have `public` or `internal` keywords scattered
around — everything without an explicit modifier is already accessible within the app.

### How Hush uses access control

From `Hush/Audio/AudioTapManager.swift`:

```swift
@MainActor
final class AudioTapManager {
    private var sessions: [String: TapSession] = [:]   // private — implementation detail

    // MARK: - Public
    func mute(processID: String, objectIDs: [AudioObjectID]) throws { ... }  // internal (default)
    func unmute(processID: String) { ... }                                    // internal
    func teardownAll() { ... }                                                // internal

    // MARK: - Private
    private func teardown(_ session: TapSession) { ... }   // private — not called outside this class
}
```

`sessions` is `private` — the ViewModel does not need to know about the internal session
tracking. The `mute`/`unmute`/`teardownAll` methods are `internal` (the default) — they
are the public API of the class within the app. The `teardown` helper is `private` — it is
an implementation detail.

From `Hush/ViewModel/AppListViewModel.swift`:

```swift
@Observable
@MainActor
final class AppListViewModel {
    var processes: [AudioProcess] = []          // internal — views read this
    var mutedProcessIDs: Set<String> = []       // internal — views read this
    var error: HushError?                       // internal — views read this

    private let monitor = AudioProcessMonitor()     // private — views don't need this
    private let tapManager = AudioTapManager()      // private — views don't need this
    private var mutedObjectIDs: [String: [AudioObjectID]] = [:]  // private
    private var mutedProcessCache: [String: AudioProcess] = [:]  // private
```

The pattern is clear: properties that views need are `internal` (no modifier).
Implementation details are `private`. This is a deliberate architectural choice — the
ViewModel exposes exactly the surface area that the views need and nothing more.

### Swift's module system vs Rust's crate/module system

Rust has a rich hierarchical module system: `mod`, `pub(crate)`, `pub(super)`, re-exports
with `pub use`, and the file-system based module tree. Swift's module system is much
flatter.

In Swift, a **module** is typically an entire app target or framework. There are no
sub-modules, no `mod.rs` files, no path-based visibility. Every file in the module can
see every other file's `internal` declarations. You do not need `use` or `mod`
statements to bring types into scope — if it is in the same module, it is visible.

```
Rust module tree:                    Swift module:

src/                                 Hush/
├── main.rs                          ├── App/
├── model/                           │   └── HushApp.swift
│   ├── mod.rs                       ├── Model/
│   └── audio_process.rs             │   └── AudioProcess.swift
├── audio/                           ├── Audio/
│   ├── mod.rs                       │   ├── CoreAudioHelpers.swift
│   ├── helpers.rs                   │   ├── AudioProcessMonitor.swift
│   └── tap_manager.rs               │   └── AudioTapManager.swift
└── views/                           ├── ViewModel/
    ├── mod.rs                       │   └── AppListViewModel.swift
    └── menu.rs                      └── Views/
                                         ├── MenuContentView.swift
Each file must be declared             └── AudioProcessRow.swift
in a mod.rs. Visibility
is controlled per-item.              All files see each other.
                                     Folder structure is cosmetic.
```

The folder structure in a Swift project is for *human* organization. The compiler treats
all `.swift` files in a target as a single flat namespace. This is both freeing (no
boilerplate `mod` declarations) and limiting (no fine-grained visibility beyond
`private`/`fileprivate`).

### Further reading

- [The Swift Programming Language — Access Control](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/accesscontrol/)

---

## Property observers and computed properties

Swift has two property features that Rust does not: **property observers** (`willSet`/
`didSet`) and **computed properties** with property syntax.

### Computed properties

A computed property looks like a field but is actually a function. It has no storage — it
computes its value on every access.

From `Hush/ViewModel/AppListViewModel.swift`:

```swift
var anyMuted: Bool { !mutedProcessIDs.isEmpty }
```

This is a read-only computed property. Every time you access `viewModel.anyMuted`, it
evaluates `!mutedProcessIDs.isEmpty` and returns the result.

In Rust, you would write a method:

```rust
fn any_muted(&self) -> bool {
    !self.muted_process_ids.is_empty()
}
```

The difference is syntactic: Swift lets you call it as `viewModel.anyMuted` (property
syntax) instead of `viewModel.anyMuted()` (method syntax). This matters in SwiftUI because
views read properties, and computed properties integrate seamlessly with the observation
system — when `mutedProcessIDs` changes, SwiftUI knows that `anyMuted` might have changed
too.

From `Hush/Audio/CoreAudioHelpers.swift`:

```swift
var errorDescription: String? {
    switch self {
    case .osStatus(let code):
        // ...
    }
}
```

This is the `LocalizedError` protocol requirement — a computed property that returns a
human-readable description.

Computed properties can also have setters:

```swift
var celsius: Double {
    get { (fahrenheit - 32) / 1.8 }
    set { fahrenheit = newValue * 1.8 + 32 }
}
```

### `isPermissionError` — computed property on an enum

From `Hush/Audio/CoreAudioHelpers.swift`:

```swift
var isPermissionError: Bool {
    guard case .osStatus(let code) = self else { return false }
    return code == -66753 || code == -66748
}
```

This combines a computed property with pattern matching — it checks if the enum is the
`.osStatus` variant and if the code matches known permission error codes. Clean, readable,
and impossible to forget to handle (unlike checking a raw error code integer).

### Property observers: `willSet` and `didSet`

Property observers let you run code before or after a stored property changes. Rust has
nothing equivalent — you would use setter methods or interior mutability patterns.

```swift
var score: Int = 0 {
    willSet {
        print("Score is about to change from \(score) to \(newValue)")
    }
    didSet {
        print("Score changed from \(oldValue) to \(score)")
        if score > highScore { highScore = score }
    }
}
```

`willSet` fires before the value changes (with `newValue` available). `didSet` fires after
(with `oldValue` available). Hush does not use property observers directly because it
uses the `@Observable` macro, which provides more powerful observation through SwiftUI's
reactive system. But `willSet`/`didSet` are common in non-SwiftUI code and in UIKit apps.

In Rust, the closest pattern would be:

```rust
fn set_score(&mut self, new_value: i32) {
    let old_value = self.score;
    println!("Score about to change from {} to {}", old_value, new_value);
    self.score = new_value;
    println!("Score changed from {} to {}", old_value, self.score);
    if self.score > self.high_score {
        self.high_score = self.score;
    }
}
```

The difference is that in Swift, observers are attached to the *property itself*, so they
fire regardless of where the mutation happens. In Rust, you must route all mutations
through the setter method manually — there is no language-level hook on field assignment.

### Further reading

- [The Swift Programming Language — Properties](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/properties/)

---

## Key syntax differences cheat sheet

This table covers the most common operations you will encounter when reading and writing
Swift. Keep it open in a tab while you work through the Hush codebase.

### Variables and constants

| Operation | Rust | Swift |
|---|---|---|
| Immutable binding | `let x = 5;` | `let x = 5` |
| Mutable binding | `let mut x = 5;` | `var x = 5` |
| Type annotation | `let x: i32 = 5;` | `let x: Int = 5` |
| Constant | `const X: i32 = 5;` | `let x = 5` (or `static let` for type-level) |
| Static property | `const`/`static` | `static let` / `static var` |

### Types

| Type | Rust | Swift |
|---|---|---|
| Signed integers | `i8`, `i16`, `i32`, `i64` | `Int8`, `Int16`, `Int32`, `Int64` |
| Unsigned integers | `u8`, `u16`, `u32`, `u64` | `UInt8`, `UInt16`, `UInt32`, `UInt64` |
| Platform-sized int | `isize` / `usize` | `Int` / `UInt` |
| Float | `f32`, `f64` | `Float`, `Double` |
| Boolean | `bool` | `Bool` |
| String (owned) | `String` | `String` |
| String (borrowed) | `&str` | `Substring` (rarely used explicitly) |
| Array | `Vec<T>` | `[T]` or `Array<T>` |
| Dictionary | `HashMap<K, V>` | `[K: V]` or `Dictionary<K, V>` |
| Set | `HashSet<T>` | `Set<T>` |
| Optional | `Option<T>` | `T?` or `Optional<T>` |
| Tuple | `(i32, String)` | `(Int, String)` |
| Unit / Void | `()` | `Void` or `()` |

### Functions

| Concept | Rust | Swift |
|---|---|---|
| Function declaration | `fn foo(x: i32) -> i32` | `func foo(x: Int) -> Int` |
| No return value | `fn foo()` | `func foo()` |
| External param name | N/A | `func foo(for x: Int)` — called as `foo(for: 5)` |
| Omit param label | N/A | `func foo(_ x: Int)` — called as `foo(5)` |
| Mutable reference param | `fn foo(x: &mut i32)` | `func foo(x: inout Int)` |
| Variadic params | N/A (use slices) | `func foo(x: Int...)` |

### Control flow

| Concept | Rust | Swift |
|---|---|---|
| If/else | `if x > 0 { } else { }` | `if x > 0 { } else { }` (same) |
| Ternary | N/A (use `if` expression) | `x > 0 ? "yes" : "no"` |
| For loop (range) | `for i in 0..10 { }` | `for i in 0..<10 { }` |
| For loop (inclusive) | `for i in 0..=10 { }` | `for i in 0...10 { }` |
| For loop (collection) | `for x in &items { }` | `for x in items { }` |
| While | `while cond { }` | `while cond { }` (same) |
| Pattern match | `match x { ... }` | `switch x { ... }` |
| Break from loop | `break` | `break` (same) |
| Continue | `continue` | `continue` (same) |
| Early return | `return` | `return` (same) |
| Guard clause | `let ... else { return }` | `guard ... else { return }` |

### Error handling

| Concept | Rust | Swift |
|---|---|---|
| Fallible function | `fn f() -> Result<T, E>` | `func f() throws -> T` |
| Propagate error | `f()?` | `try f()` |
| Handle error | `match f() { Ok/Err }` | `do { try f() } catch { }` |
| Error to optional | `f().ok()` | `try? f()` |
| Crash on error | `f().unwrap()` | `try! f()` |
| Scope cleanup | `Drop` / scope guard | `defer { }` |

### Closures

| Concept | Rust | Swift |
|---|---|---|
| Closure syntax | `\|x\| x + 1` | `{ x in x + 1 }` |
| With type annotation | `\|x: i32\| -> i32 { x + 1 }` | `{ (x: Int) -> Int in x + 1 }` |
| Shorthand params | N/A | `{ $0 + 1 }` |
| Capture by move | `move \|\| { ... }` | Default for reference types |
| Capture weakly | `Weak::new()` + `upgrade()` | `{ [weak self] in ... }` |
| Stored closure type | `Box<dyn Fn(i32) -> i32>` | `(Int) -> Int` |
| Must outlive call | `T: 'static + Fn()` | `@escaping () -> Void` |

### Structs and classes

| Concept | Rust | Swift |
|---|---|---|
| Struct definition | `struct Foo { x: i32 }` | `struct Foo { var x: Int }` |
| Method | `impl Foo { fn bar(&self) }` | `struct Foo { func bar() }` |
| Mutating method | `fn bar(&mut self)` | `mutating func bar()` |
| Constructor | `Foo { x: 5 }` or `Foo::new(5)` | `Foo(x: 5)` (memberwise init) |
| Heap-allocated | `Box<T>` / `Arc<T>` | `class` |
| Prevent subclassing | Default (no inheritance) | `final class` |
| Destructor | `impl Drop for Foo` | `deinit { }` (classes only) |

### Protocols and generics

| Concept | Rust | Swift |
|---|---|---|
| Interface definition | `trait Foo { }` | `protocol Foo { }` |
| Implement interface | `impl Foo for Bar { }` | `extension Bar: Foo { }` or on declaration |
| Generic function | `fn foo<T: Trait>()` | `func foo<T: Protocol>()` |
| Opaque return type | `fn foo() -> impl Trait` | `func foo() -> some Protocol` |
| Type-erased | `Box<dyn Trait>` | `any Protocol` |
| Where clause | `where T: Trait` | `where T: Protocol` |
| Associated type | `type Item;` | `associatedtype Item` |

---

## What comes next

You now have the language foundations: types, memory management, enums, optionals, error
handling, protocols, generics, closures, and access control. These are the building blocks
that every line of Hush is built from.

Part 2 covers **SwiftUI and the reactive UI model** — how `@Observable`, `@State`, and
`Binding` work together to make the compiler re-render your views automatically when
state changes. You will see how `MenuContentView`, `AudioProcessRow`, and `HushApp` use
these mechanisms, and why the pattern feels so different from anything in the Rust
ecosystem.
