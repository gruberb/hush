# Part 4 — Concurrency and Thread Safety

Swift's concurrency model solves the same problem as Rust's `Send`/`Sync` traits and
Tokio runtime — preventing data races at compile time and giving you structured tools for
asynchronous work. But the approach is different. Rust uses ownership and borrowing. Swift
uses **actors**, **isolation annotations**, and **cooperative cancellation**.

This part covers every concurrency concept used in Hush, starting with the fundamental
constraint that all GUI frameworks share: the main thread.

---

## Table of contents

- [The main thread: why UI frameworks care](#the-main-thread-why-ui-frameworks-care)
- [@MainActor: compile-time thread pinning](#mainactor-compile-time-thread-pinning)
  - [What @MainActor looks like in Hush](#what-mainactor-looks-like-in-hush)
  - [Why everything in Hush is @MainActor](#why-everything-in-hush-is-mainactor)
  - [The deinit problem](#the-deinit-problem)
- [Sendable: Swift's Send trait](#sendable-swifts-send-trait)
  - [AudioProcess: @unchecked Sendable](#audioprocess-unchecked-sendable)
- [Task: structured concurrency](#task-structured-concurrency)
  - [Debouncing with Task cancellation](#debouncing-with-task-cancellation)
- [async/await](#asyncawait)
- [Weak references and \[weak self\]: preventing retain cycles](#weak-references-and-weak-self-preventing-retain-cycles)
  - [Every \[weak self\] in Hush, explained](#every-weak-self-in-hush-explained)
  - [The retain cycle that would occur without \[weak self\]](#the-retain-cycle-that-would-occur-without-weak-self)
  - [guard let self else { return }](#guard-let-self-else--return-)
- [Timers and callbacks from system APIs](#timers-and-callbacks-from-system-apis)
- [The concurrency model of Hush: a complete diagram](#the-concurrency-model-of-hush-a-complete-diagram)
- [Swift concurrency vs Rust concurrency: a comparison table](#swift-concurrency-vs-rust-concurrency-a-comparison-table)
- [Key resources](#key-resources)

---

## The main thread: why UI frameworks care

Every macOS (and iOS) application has a **main thread**. This thread runs the **run loop**
(`NSRunLoop` / `CFRunLoop`) — the event loop that processes user interactions, timer
callbacks, and system notifications. All UI rendering happens on this thread.

```
┌──────────────────────────────────────────────────────────────────┐
│                      macOS Application                            │
│                                                                   │
│   Main Thread (thread 0)                                         │
│   ┌────────────────────────────────────────────────────────┐     │
│   │                    Run Loop                             │     │
│   │                                                         │     │
│   │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────┐ │     │
│   │  │  User    │  │  Timer   │  │  System  │  │ Render │ │     │
│   │  │  events  │  │  fires   │  │  notifs  │  │  pass  │ │     │
│   │  └────┬─────┘  └────┬─────┘  └────┬─────┘  └───┬────┘ │     │
│   │       │              │              │             │      │     │
│   │       └──────────────┴──────────────┴─────────────┘      │     │
│   │                         │                                │     │
│   │                  process event                           │     │
│   │                  update state                            │     │
│   │                  re-render UI                            │     │
│   │                  wait for next event...                  │     │
│   └────────────────────────────────────────────────────────┘     │
│                                                                   │
│   Background threads                                             │
│   ┌────────────────────────────────────────────────────────┐     │
│   │  Core Audio HAL callbacks                               │     │
│   │  Network responses                                      │     │
│   │  File I/O completions                                   │     │
│   │  ... must NOT touch UI state                            │     │
│   └────────────────────────────────────────────────────────┘     │
└──────────────────────────────────────────────────────────────────┘
```

If you mutate UI state from a background thread, the results are **undefined behavior** in
the practical sense: you get visual glitches, crashes, corrupted state, or race conditions
that are impossible to reproduce. Before Swift concurrency, this was the most common source
of bugs in macOS and iOS applications. Developers had to remember to dispatch to the main
thread manually using `DispatchQueue.main.async { ... }`, and forgetting to do so produced
bugs that only appeared under specific timing conditions.

> **Rust parallel**: Most Rust GUI frameworks have the same constraint. In
> [winit](https://docs.rs/winit/), the `EventLoop` must run on the main thread and you
> cannot send window handles across threads (they are `!Send`). In
> [gtk-rs](https://gtk-rs.org/), calling GTK functions from a non-main thread is undefined
> behavior. The difference is that Rust enforces this through the type system (`!Send` /
> `!Sync`), while Swift enforces it through **actor isolation** (`@MainActor`).

---

## @MainActor: compile-time thread pinning

`@MainActor` is an annotation that tells the Swift compiler: **this type or function must
run on the main thread.** The compiler enforces this at compile time — it will reject code
that tries to call a `@MainActor` function from a non-isolated context without `await`.

```swift
@MainActor
final class AudioTapManager {
    private var sessions: [String: TapSession] = [:]
    // ...
}
```

Every method on `AudioTapManager` — `mute(processID:objectIDs:)`, `unmute(processID:)`,
`teardownAll()` — is guaranteed to run on the main thread. The `sessions` dictionary is
guaranteed to be accessed from a single thread. No locks needed. No `Mutex`. No `Arc`.

> **Rust parallel**: Think of `@MainActor` as the inverse of `Send`. In Rust, you mark
> types that *can* move between threads with `Send`. In Swift, you mark types that *must
> stay* on a specific thread with `@MainActor`. The effect is similar — the compiler
> prevents unsafe cross-thread access — but the direction is reversed:
>
> | Rust | Swift |
> |---|---|
> | `Send` — "this type can be sent to another thread" | `Sendable` — "this type can be sent across actor boundaries" |
> | `!Send` — "this type must stay on its current thread" | `@MainActor` — "this type must stay on the main thread" |
> | `Sync` — "this type can be shared across threads via `&T`" | (no direct equivalent — actors enforce exclusive access) |

### What @MainActor looks like in Hush

All three core classes in Hush are annotated `@MainActor`:

**`AudioProcessMonitor`** (`Hush/Audio/AudioProcessMonitor.swift`):
```swift
@MainActor
final class AudioProcessMonitor {
    var onChange: (([AudioProcess]) -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var pollTimer: Timer?
    // ...
}
```

**`AudioTapManager`** (`Hush/Audio/AudioTapManager.swift`):
```swift
@MainActor
final class AudioTapManager {
    private var sessions: [String: TapSession] = [:]
    // ...
}
```

**`AppListViewModel`** (`Hush/ViewModel/AppListViewModel.swift`):
```swift
@Observable
@MainActor
final class AppListViewModel {
    var processes: [AudioProcess] = []
    var mutedProcessIDs: Set<String> = []
    var error: HushError?
    // ...
}
```

When you put `@MainActor` on a class, **every stored property and every method** on that
class inherits the annotation. You do not need to mark individual methods.

### Why everything in Hush is @MainActor

Hush is a UI-driven application where all state is UI state. The `processes` array drives
the list view. The `mutedProcessIDs` set drives the mute icons. The `error` value drives
the error banner. Even the internal `sessions` dictionary in `AudioTapManager` needs to be
consistent with the UI state, because muting and unmuting happen in response to user clicks.

There is no background computation in Hush. Core Audio's C API is synchronous — calls like
`AudioHardwareCreateProcessTap` block until they complete, but they complete in
microseconds. There is no network I/O. There is no file I/O. Everything fits on the main
thread.

This is a design choice, not a requirement. A more complex audio application might process
audio buffers on a real-time thread and use actors to communicate back to the UI. But for
Hush, the single-actor model is the right fit: all state lives on the main actor, all
mutations happen on the main actor, and the compiler guarantees this at build time.

### The deinit problem

There is one place where `@MainActor` isolation breaks down: **`deinit`**.

In Swift, `deinit` (the equivalent of Rust's `Drop::drop`) is always **nonisolated**. It
cannot call `@MainActor` methods because the runtime does not guarantee which thread
will deallocate an object. This is similar to how Rust's `Drop::drop` takes `&mut self`
but cannot assume anything about which thread calls it.

Look at `AudioProcessMonitor.deinit` in `Hush/Audio/AudioProcessMonitor.swift`:

```swift
deinit {
    pollTimer?.invalidate()
    if let block = listenerBlock {
        var addr = processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            .main,
            block
        )
    }
}
```

Notice what this does **not** do: it does not call `stopListening()`. The `stopListening()`
method is `@MainActor`-isolated (it inherits isolation from the class), so calling it from
`deinit` would be a compiler error. Instead, `deinit` inlines the cleanup logic directly,
accessing the stored properties that it needs.

This works because `deinit` has exclusive access to the object — no other code can be
reading or writing the object's properties at this point (the reference count reached zero).
The Core Audio C functions being called (`AudioObjectRemovePropertyListenerBlock`,
`Timer.invalidate`) are thread-safe at the C level.

> **Rust parallel**: This is like the tension between `Drop` and async Rust. You cannot
> call `.await` inside `Drop::drop()`. If you need async cleanup, you must provide an
> explicit `async fn close(self)` method and ensure callers use it. Swift has the same
> problem — `deinit` cannot participate in actor isolation. The workaround is the same:
> provide an explicit `teardown()` or `stopListening()` method for orderly shutdown, and
> use `deinit` only as a safety net for leaked resources.

---

## Sendable: Swift's Send trait

The `Sendable` protocol is Swift's answer to Rust's `Send` trait. A type that conforms to
`Sendable` can be safely transferred across concurrency boundaries — passed to another
actor, captured in a `Task`, or sent through an async channel.

The rules for automatic `Sendable` conformance mirror Rust's auto-trait rules for `Send`:

| Swift | Rust |
|---|---|
| Structs are `Sendable` if all stored properties are `Sendable` | Structs are `Send` if all fields are `Send` |
| Enums are `Sendable` if all associated values are `Sendable` | Enums are `Send` if all variants' fields are `Send` |
| Classes are never automatically `Sendable` (they are reference types) | `Arc<T>` is `Send` if `T: Send + Sync` |
| `@MainActor` classes are `Sendable` (the actor guarantees safe access) | No direct equivalent |
| `@unchecked Sendable` — programmer asserts safety | `unsafe impl Send for T {}` |

Swift 6's strict concurrency mode (enabled with the `StrictConcurrency` build setting)
makes `Sendable` checking mandatory. The compiler will reject code that passes non-Sendable
values across actor boundaries. This is the same shift that Rust made when stabilizing
`Send` and `Sync` — moving thread-safety checking from "programmer discipline" to "compiler
enforcement."

### AudioProcess: @unchecked Sendable

Look at the `AudioProcess` struct in `Hush/Model/AudioProcess.swift`:

```swift
/// `@unchecked Sendable` because `NSImage` is not formally `Sendable`,
/// but instances here are only read after creation, and the struct is
/// exclusively used from `@MainActor` context.
struct AudioProcess: Identifiable, Hashable, @unchecked Sendable {
    let id: String
    let objectIDs: [AudioObjectID]
    let pid: pid_t
    let bundleID: String?
    let name: String
    let icon: NSImage?
    var isRunningOutput: Bool
    // ...
}
```

`AudioProcess` is a struct — a value type. All its fields are `Sendable` except one:
`NSImage`. Apple's `NSImage` class predates Swift concurrency and has not been annotated as
`Sendable`. The compiler cannot verify that `NSImage` is safe to send across threads.

But the programmer *knows* the usage is safe:

1. `NSImage` instances are created once during `enumerateProcesses()` and never mutated
2. The entire struct is used exclusively within `@MainActor` context
3. The `icon` field is a `let` constant — it cannot be reassigned after initialization

So `@unchecked Sendable` tells the compiler: "I have verified the safety. Trust me." This
is exactly `unsafe impl Send for AudioProcess {}` in Rust — an escape hatch for when you
know more than the compiler about the safety of your data.

> **When to use `@unchecked Sendable`**: Use it sparingly, and always with a comment
> explaining *why* it is safe. If Apple later annotates `NSImage` as `Sendable` (or
> provides a `Sendable` image type), you can remove the `@unchecked`. Until then, the
> comment serves as documentation of the safety invariant.

---

## Task: structured concurrency

`Task { }` creates a new unit of concurrent work. It is the Swift equivalent of
`tokio::spawn()`:

| Swift | Rust (Tokio) |
|---|---|
| `Task { work() }` | `tokio::spawn(async { work() })` |
| `Task { @MainActor in work() }` | `tokio::spawn(async { main_handle.spawn(work()) })` |
| `Task.sleep(for: .milliseconds(500))` | `tokio::time::sleep(Duration::from_millis(500))` |
| `Task.isCancelled` | `CancellationToken.is_cancelled()` |
| `task.cancel()` | `token.cancel()` |

Key differences from `tokio::spawn()`:

1. **Inheritance**: A `Task` created inside a `@MainActor` context inherits that isolation
   by default. You do not need to specify `@MainActor in` if you are already on the main
   actor.

2. **Cooperative cancellation**: Calling `task.cancel()` does not kill the task. It sets a
   flag that the task must check via `Task.isCancelled`. This is identical to Tokio's
   `CancellationToken` — cancellation is cooperative, not preemptive. The task decides
   when and how to stop.

3. **Return values**: Tasks can return values and throw errors. You can `await` a task's
   result, unlike Tokio's `JoinHandle` which returns a `Result<T, JoinError>`.

### Debouncing with Task cancellation

The most interesting use of `Task` in Hush is the debounced device change handler in
`AppListViewModel.handleDeviceChange()` (`Hush/ViewModel/AppListViewModel.swift`):

```swift
private func handleDeviceChange() {
    guard anyMuted else { return }

    // Debounce rapid device switches (e.g. connecting AirPods)
    deviceChangeTask?.cancel()
    deviceChangeTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self else { return }

        logger.info("Output device changed, recreating \(self.mutedProcessIDs.count) tap(s)")

        let saved = self.mutedObjectIDs

        self.tapManager.teardownAll()

        var newMutedIDs: Set<String> = []
        var newObjectIDs: [String: [AudioObjectID]] = [:]

        for (processID, objectIDs) in saved {
            do {
                try self.tapManager.mute(processID: processID, objectIDs: objectIDs)
                newMutedIDs.insert(processID)
                newObjectIDs[processID] = objectIDs
            } catch {
                logger.error("Re-mute failed for \(processID): \(error.localizedDescription)")
                self.mutedProcessCache.removeValue(forKey: processID)
            }
        }

        self.mutedProcessIDs = newMutedIDs
        self.mutedObjectIDs = newObjectIDs
    }
}
```

Here is the pattern, step by step:

```
handleDeviceChange() called (event 1)
    │
    ├── deviceChangeTask?.cancel()       ← cancel any pending task (no-op first time)
    ├── deviceChangeTask = Task { ... }  ← start new task
    │       │
    │       ├── sleep 500ms              ← wait (can be interrupted by cancellation)
    │       └── ...                      ← (sleeping)
    │
handleDeviceChange() called (event 2, 200ms later)
    │
    ├── deviceChangeTask?.cancel()       ← cancel event 1's task (still sleeping)
    ├── deviceChangeTask = Task { ... }  ← start new task for event 2
    │       │
    │       ├── sleep 500ms
    │       ├── guard !Task.isCancelled  ← check: am I still alive?
    │       ├── YES → proceed with work  ← recreate audio taps
    │       └── done
```

When you switch audio devices (plugging in AirPods, for example), macOS fires the device
change notification multiple times in rapid succession. Without debouncing, Hush would tear
down and recreate all audio taps for each notification — a wasteful sequence of Core Audio
calls. The debounce pattern ensures that the work happens only once, 500ms after the last
notification.

This is a reusable pattern you will see across Swift codebases. In Rust with Tokio, the
equivalent would be:

```rust
// Rust equivalent (conceptual)
fn handle_device_change(&mut self) {
    if let Some(token) = self.cancel_token.take() {
        token.cancel();
    }
    let token = CancellationToken::new();
    self.cancel_token = Some(token.clone());
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::time::sleep(Duration::from_millis(500)) => {
                // do the work
            }
            _ = token.cancelled() => {
                // cancelled, do nothing
            }
        }
    });
}
```

The Swift version is more concise because `Task.sleep` automatically checks for
cancellation — if the task is cancelled while sleeping, the `try? await` swallows the
`CancellationError` and execution continues to the `guard !Task.isCancelled` check, which
catches it and returns.

---

## async/await

Swift's `async`/`await` syntax is nearly identical to Rust's:

| Concept | Swift | Rust |
|---|---|---|
| Declare an async function | `func fetch() async -> Data` | `async fn fetch() -> Data` |
| Call an async function | `let data = await fetch()` | `let data = fetch().await` |
| Async + error handling | `let data = try await fetch()` | `let data = fetch().await?` |
| Sleep | `try await Task.sleep(for: .seconds(1))` | `tokio::time::sleep(Duration::from_secs(1)).await` |

The keyword placement differs — Swift uses `await` as a prefix, Rust uses `.await` as a
postfix — but the mental model is the same: `await` marks a **suspension point** where the
current function yields control and may resume later.

The deeper differences are architectural:

1. **Runtime**: Swift has a built-in cooperative thread pool. Rust requires an external
   runtime (Tokio, async-std, smol). Swift's runtime is always available; you do not need
   to annotate `main` with a macro.

2. **Actor integration**: Swift's `async`/`await` integrates with the actor isolation
   system. When you `await` a call to a `@MainActor` function from a background context,
   the runtime automatically switches to the main thread. In Rust, you must explicitly
   spawn onto the right executor.

3. **Ownership**: Rust's async functions produce `Future` types that must satisfy lifetime
   and ownership rules. Swift's async functions do not have this constraint because ARC
   handles memory management. This makes Swift's async code easier to write but gives you
   less control over when allocations happen.

Hush uses minimal async code because Core Audio is a synchronous C API. The primary async
operation is `Task.sleep(for: .milliseconds(500))` in the debounce handler. If Hush needed
to make network requests, read files, or call other async APIs, you would see `async`
functions throughout the codebase.

---

## Weak references and [weak self]: preventing retain cycles

This is the most important Swift-specific concurrency topic for a Rust developer, because
Rust does not have this problem at all.

In Rust, the ownership system prevents dangling references and memory leaks at compile time.
When an object goes out of scope, it is dropped. When two objects need to reference each
other, you use `Weak<T>` (from `Arc`/`Weak`) explicitly, and the compiler forces you to
handle the "what if it was already dropped?" case via `upgrade()` returning `Option<Arc<T>>`.

Swift uses **Automatic Reference Counting (ARC)** instead of ownership. Every reference to
a class instance increments a counter. When the counter reaches zero, the instance is
deallocated. This works well until two objects hold **strong references** to each other:

```
┌──────────────────────────────────────────────────────────┐
│                   Retain Cycle                            │
│                                                           │
│   ┌───────────────────┐     strong      ┌──────────────┐ │
│   │   Object A        │ ──────────────► │   Object B   │ │
│   │   (refcount: 1)   │                 │  (refcount: 1)│ │
│   │                   │ ◄────────────── │              │ │
│   └───────────────────┘     strong      └──────────────┘ │
│                                                           │
│   Both have refcount ≥ 1. Neither can be deallocated.    │
│   Memory leak.                                            │
└──────────────────────────────────────────────────────────┘
```

In Hush, the most common source of potential retain cycles is **closures**. Closures in
Swift capture variables from their surrounding scope. By default, they capture **strong
references** to class instances. If an object stores a closure that captures `self`, you
have a cycle: the object owns the closure, and the closure owns the object.

The fix is `[weak self]` in the closure's **capture list**:

```swift
// Strong capture (DEFAULT) — potential retain cycle
monitor.onChange = { processes in
    self.handleProcessUpdate(processes)  // closure holds strong ref to self
}

// Weak capture — no retain cycle
monitor.onChange = { [weak self] processes in
    self?.handleProcessUpdate(processes)  // closure holds weak ref to self
}
```

> **Rust parallel**: `[weak self]` is exactly `Weak::clone(&arc_self)` passed into a
> closure. The `self?.method()` syntax is `weak.upgrade().map(|s| s.method())`. The
> `guard let self else { return }` pattern is
> `let Some(this) = weak.upgrade() else { return; }`.

### Every [weak self] in Hush, explained

Hush has five distinct `[weak self]` captures. Each one prevents a specific retain cycle.

**1. Process list change callback** (`AppListViewModel.init()` in `AppListViewModel.swift`):

```swift
monitor.onChange = { [weak self] processes in
    Task { @MainActor [weak self] in
        self?.handleProcessUpdate(processes)
    }
}
```

Why: `AppListViewModel` owns `monitor` (strong reference). If `monitor.onChange` captured
`self` strongly, you would have: ViewModel → monitor → closure → ViewModel. Cycle. The
`[weak self]` breaks it.

Note the **double** `[weak self]` — once for the outer closure and once for the `Task`
closure. The outer closure is the `onChange` callback stored on the monitor. The inner
closure is the `Task` body. Both need weak capture because both outlive the call site.

**2. Poll timer callback** (`AudioProcessMonitor.startListening()` in
`AudioProcessMonitor.swift`):

```swift
pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.fireUpdate()
    }
}
```

Why: `AudioProcessMonitor` stores `pollTimer` (strong reference). If the timer's closure
captured `self` strongly: Monitor → pollTimer → closure → Monitor. Cycle. The timer would
keep the monitor alive forever (the timer repeats, so it is never deallocated while active).

**3. HAL property listener** (`AudioProcessMonitor.startListening()` in
`AudioProcessMonitor.swift`):

```swift
let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    Task { @MainActor [weak self] in
        self?.fireUpdate()
    }
}
listenerBlock = block
```

Why: The monitor stores `listenerBlock` (strong reference) so it can remove the listener
later. If the block captured `self` strongly: Monitor → listenerBlock → closure → Monitor.
Cycle. Additionally, Core Audio holds its own reference to the block — if the monitor were
deallocated, the block could fire and try to access freed memory. The weak reference
handles both problems: no cycle, and safe "already deallocated" handling.

**4. Device change listener** (`AppListViewModel.startDeviceListener()` in
`AppListViewModel.swift`):

```swift
let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    Task { @MainActor [weak self] in
        self?.handleDeviceChange()
    }
}
deviceListenerBlock = block
```

Why: Same pattern as #3, but for the default output device change notification. ViewModel →
deviceListenerBlock → closure → ViewModel.

**5. Debounced device change task** (`AppListViewModel.handleDeviceChange()` in
`AppListViewModel.swift`):

```swift
deviceChangeTask = Task { @MainActor [weak self] in
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled, let self else { return }
    // ... use self ...
}
```

Why: `AppListViewModel` stores `deviceChangeTask` (strong reference). If the `Task`
closure captured `self` strongly: ViewModel → deviceChangeTask → closure → ViewModel.
Cycle. The task might be sleeping for 500ms — during that time, if the view model should
be deallocated (e.g., the app is quitting), the strong reference would keep it alive.

### The retain cycle that would occur without [weak self]

Here is the cycle for the `monitor.onChange` case, visualized:

```
WITHOUT [weak self] — RETAIN CYCLE:

┌──────────────────────────┐
│   AppListViewModel       │
│                          │
│   monitor ───────────────┼──► ┌───────────────────────┐
│   (strong ref)           │    │  AudioProcessMonitor  │
│                          │    │                       │
│                          │    │  onChange ─────────────┼──► ┌─────────────────┐
│                          │    │  (strong ref)         │    │  Closure         │
│   ◄──────────────────────┼────┼───────────────────────┼────┤                 │
│   (captured strong ref   │    │                       │    │  captures: self │
│    to ViewModel)         │    └───────────────────────┘    │  (= ViewModel)  │
│                          │                                  └─────────────────┘
└──────────────────────────┘

ViewModel.refcount = 2 (SwiftUI's @State + closure)
Closure.refcount = 1 (onChange property)
Monitor.refcount = 1 (ViewModel's property)

When SwiftUI releases the ViewModel:
  ViewModel.refcount = 1 (closure still holds it) → NOT deallocated
  Monitor.refcount = 1 (ViewModel still holds it) → NOT deallocated
  Closure.refcount = 1 (Monitor still holds it)   → NOT deallocated

  → Memory leak. None of the three objects are freed.


WITH [weak self] — NO CYCLE:

┌──────────────────────────┐
│   AppListViewModel       │
│                          │
│   monitor ───────────────┼──► ┌───────────────────────┐
│   (strong ref)           │    │  AudioProcessMonitor  │
│                          │    │                       │
│                          │    │  onChange ─────────────┼──► ┌─────────────────┐
│                          │    │  (strong ref)         │    │  Closure         │
│   ◄ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┼─ ─ ┼ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─┼─ ─ ┤                 │
│   (weak ref, does NOT    │    │                       │    │  captures: self │
│    increment refcount)   │    └───────────────────────┘    │  (weak)         │
│                          │                                  └─────────────────┘
└──────────────────────────┘

When SwiftUI releases the ViewModel:
  ViewModel.refcount = 0 → DEALLOCATED
  Monitor.refcount = 0   → DEALLOCATED (ViewModel no longer holds it)
  Closure.refcount = 0   → DEALLOCATED (Monitor no longer holds it)

  → Clean deallocation. No leak.
```

### guard let self else { return }

After a `[weak self]` capture, `self` has type `Optional<ClassName>` (like
`Option<Weak<T>>` in Rust). You need to unwrap it before using it. Swift provides two
patterns:

**Optional chaining** (for one-off calls):
```swift
self?.fireUpdate()
// Equivalent Rust: weak.upgrade().map(|s| s.fire_update());
```

**guard let** (when you need `self` multiple times):
```swift
Task { @MainActor [weak self] in
    try? await Task.sleep(for: .milliseconds(500))
    guard !Task.isCancelled, let self else { return }
    // From this point, `self` is a strong reference (non-optional).
    // Equivalent Rust: let Some(this) = weak.upgrade() else { return; };
    self.tapManager.teardownAll()
    self.mutedProcessIDs = newMutedIDs
}
```

The `guard let self else { return }` pattern does two things:

1. **Unwraps** the optional — if the object was deallocated, the weak reference is `nil`,
   and the `guard` exits early.
2. **Temporarily creates a strong reference** — for the remainder of the scope, `self` is
   non-optional and the object cannot be deallocated. This is exactly `Weak::upgrade()`
   in Rust, which returns an `Arc<T>` that keeps the object alive for as long as you hold
   it.

---

## Timers and callbacks from system APIs

Hush receives events from two kinds of system APIs, both of which fire outside of
`@MainActor` isolation:

**1. Timer.scheduledTimer** — fires on the main run loop, but the closure is nonisolated:

```swift
pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
    Task { @MainActor [weak self] in
        self?.fireUpdate()
    }
}
```

**2. AudioObjectPropertyListenerBlock** — Core Audio's callback for property changes:

```swift
let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
    Task { @MainActor [weak self] in
        self?.fireUpdate()
    }
}
```

Both use the same bridging pattern: **wrap the work in `Task { @MainActor in }`** to hop
back to the main actor.

```
┌──────────────────────────────────────────────────────────────┐
│                    Bridging Pattern                            │
│                                                               │
│   System API callback fires                                  │
│   (nonisolated — might be any thread)                        │
│           │                                                   │
│           ▼                                                   │
│   ┌─────────────────────────────────────────┐                │
│   │  Task { @MainActor [weak self] in       │                │
│   │      // Now on the main thread.          │                │
│   │      // Safe to access @MainActor state. │                │
│   │      self?.fireUpdate()                  │                │
│   │  }                                       │                │
│   └─────────────────────────────────────────┘                │
│           │                                                   │
│           ▼                                                   │
│   Main actor processes the Task                              │
│   on the next run loop iteration                             │
└──────────────────────────────────────────────────────────────┘
```

The older approach you will encounter in pre-Swift-concurrency code uses Grand Central
Dispatch (GCD):

```swift
// Old pattern (pre-Swift 5.5):
DispatchQueue.main.async {
    self.fireUpdate()
}

// Modern pattern (Swift 5.5+):
Task { @MainActor in
    self.fireUpdate()
}
```

Both achieve the same thing — scheduling work on the main thread — but `Task { @MainActor
in }` integrates with Swift's concurrency checking. The compiler can verify that the code
inside the `Task` respects actor isolation, which it cannot do with `DispatchQueue`.

> **Rust parallel**: This bridging pattern is like receiving a callback from a C library
> (which runs on an arbitrary thread) and using `tokio::spawn` or a channel to send the
> event to your main task:
> ```rust
> // Rust equivalent (conceptual)
> let tx = main_channel.clone();
> c_library_set_callback(move || {
>     let _ = tx.send(Event::ProcessListChanged);
> });
> ```
> In Rust you would use a channel or `tokio::sync::mpsc` to bridge between the callback
> thread and your async task. In Swift, `Task { @MainActor in }` serves the same purpose
> with less boilerplate.

---

## The concurrency model of Hush: a complete diagram

Hush has four sources of concurrent events. All of them converge on the main actor through
the same `Task { @MainActor in }` bridge:

```
┌──────────────────────────────────────────────────────────────────────────┐
│                    Hush Concurrency Model                                 │
│                                                                          │
│  Event Sources                          Main Actor                       │
│  (nonisolated)                          (@MainActor)                     │
│                                                                          │
│  ┌─────────────────────┐                                                 │
│  │ HAL Property        │   Task { @MainActor in }                        │
│  │ Listener            │ ─────────────────────────►  fireUpdate()        │
│  │ (process list       │                              │                  │
│  │  changed)           │                              ▼                  │
│  └─────────────────────┘                         onChange?(processes)    │
│                                                       │                  │
│  ┌─────────────────────┐                              ▼                  │
│  │ Timer               │   Task { @MainActor in }                        │
│  │ (every 2 seconds)   │ ─────────────────────────►  fireUpdate()        │
│  │                     │                              │                  │
│  └─────────────────────┘                              ▼                  │
│                                                  handleProcessUpdate()   │
│  ┌─────────────────────┐                              │                  │
│  │ Device Change       │   Task { @MainActor in }     ▼                  │
│  │ Listener            │ ─────────────────────────►  handleDeviceChange()│
│  │ (output device      │                              │                  │
│  │  switched)          │                              ▼                  │
│  └─────────────────────┘                         (debounce 500ms)       │
│                                                       │                  │
│                                                       ▼                  │
│  ┌─────────────────────┐                         recreate taps          │
│  │ User Interaction    │                                                 │
│  │ (button click)      │ ─── already on ──────►  toggleMute(for:)       │
│  │                     │     main thread          unmuteAll()            │
│  └─────────────────────┘                          toggleLaunchAtLogin()  │
│                                                       │                  │
│                                                       ▼                  │
│                                              ┌────────────────────┐     │
│                                              │  @Observable state  │     │
│                                              │                    │     │
│                                              │  processes          │     │
│                                              │  mutedProcessIDs    │     │
│                                              │  error              │     │
│                                              │  launchAtLogin      │     │
│                                              └────────┬───────────┘     │
│                                                       │                  │
│                                                  SwiftUI observes        │
│                                                       │                  │
│                                                       ▼                  │
│                                              ┌────────────────────┐     │
│                                              │    UI re-renders    │     │
│                                              └────────────────────┘     │
│                                                                          │
│  Legend:                                                                  │
│    ──────► = Task { @MainActor in } bridge                               │
│    ── ──► = already on main thread (user interaction)                    │
└──────────────────────────────────────────────────────────────────────────┘
```

Note what Hush does **not** use:

- **No locks** — no `NSLock`, no `os_unfair_lock`, no `pthread_mutex`
- **No mutexes** — no `DispatchSemaphore`, no `Mutex<T>` equivalent
- **No channels** — no `AsyncStream`, no `AsyncChannel`
- **No multiple actors** — no custom `actor` types

This is a **single-actor model**. All mutable state lives on the main actor. All events
bridge to the main actor before touching state. The compiler enforces this at build time
through `@MainActor` annotations. The result is a concurrency model that is impossible to
deadlock, impossible to data-race, and requires zero synchronization primitives.

> **Rust parallel**: The closest Rust equivalent is a `tokio::sync::mpsc` channel where all
> events are sent to a single receiver task that owns all mutable state. The receiver
> processes events one at a time, so there are no data races. The difference is that in
> Rust you build this pattern yourself; in Swift, `@MainActor` gives it to you as a
> language feature with compile-time checking.

---

## Swift concurrency vs Rust concurrency: a comparison table

| Concept | Swift | Rust | Notes |
|---|---|---|---|
| **Thread safety marker** | `Sendable` protocol | `Send` trait | Both mean "safe to transfer across concurrency boundaries" |
| **Shared access marker** | (Actor isolation) | `Sync` trait | Swift uses actors instead of a trait. Actors enforce exclusive access at runtime. |
| **Pin to main thread** | `@MainActor` | `!Send` + runtime affinity | Swift checks at compile time. Rust prevents sending but does not enforce which thread. |
| **Opt out of safety** | `@unchecked Sendable` | `unsafe impl Send for T {}` | Both: "I assert this is safe, compiler trust me" |
| **Spawn concurrent work** | `Task { }` | `tokio::spawn()` | Both return a handle. Both run on a thread pool. |
| **Spawn on main thread** | `Task { @MainActor in }` | `handle.spawn_on_main()` (framework-specific) | Swift has first-class support. Rust depends on the framework. |
| **Async function** | `async func f()` | `async fn f()` | Nearly identical syntax. |
| **Await** | `await f()` (prefix) | `f().await` (postfix) | Different syntax, same semantics. |
| **Async + error** | `try await f()` | `f().await?` | Swift combines `try` and `await`. Rust combines `.await` and `?`. |
| **Sleep** | `Task.sleep(for:)` | `tokio::time::sleep()` | Both are async, both are cancellation-aware. |
| **Cancellation** | `Task.isCancelled` | `CancellationToken` | Both cooperative. Neither kills the task immediately. |
| **Weak reference** | `[weak self]` / `weak var` | `Weak<T>` from `Arc`/`Weak` | Same concept. Swift needs it for closures to prevent retain cycles. Rust needs it for shared ownership cycles. |
| **Unwrap weak ref** | `guard let self else { return }` | `weak.upgrade().ok_or(...)` | Both convert a weak reference to a strong one, with a "was it deallocated?" check. |
| **Actor** | `actor MyActor { }` | `Arc<Mutex<T>>` or `tokio::sync::mpsc` channel | Swift actors are a language feature. Rust achieves the same with library primitives. |
| **Global actor** | `@MainActor`, `@globalActor` | No direct equivalent | Swift's global actors are singletons that pin code to a specific executor. |
| **Structured concurrency** | `async let`, `TaskGroup` | `tokio::join!`, `FuturesUnordered` | Both allow concurrent execution of multiple tasks with structured lifetimes. |
| **Memory management** | ARC (automatic reference counting) | Ownership + `Drop` | Fundamentally different models. ARC can leak (retain cycles). Ownership cannot. |

The philosophical difference: **Rust prevents data races through ownership — you cannot
have shared mutable state because the type system forbids it.** Swift prevents data races
through isolation — you *can* have shared mutable state, but the actor system ensures that
only one execution context accesses it at a time.

Both approaches achieve the same goal (no data races at compile time), but they impose
different constraints on how you structure your code:

- In Rust, you choose between exclusive ownership (`&mut T`), shared immutable access
  (`Arc<T>` where `T: Sync`), or synchronized shared access (`Arc<Mutex<T>>`).
- In Swift, you choose between value types (structs, copied on assignment), actor-isolated
  reference types (`actor` or `@MainActor class`), or `Sendable` types that can cross
  boundaries.

---

## Key resources

### Apple documentation

- **[Swift Concurrency](https://developer.apple.com/documentation/swift/concurrency)** — Apple's top-level documentation hub for async/await, tasks, and actors.

- **[The Swift Programming Language — Concurrency](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/)** — The official language guide chapter on concurrency. Covers async/await, structured concurrency, and actors with clear examples.

- **[Sendable (Swift standard library)](https://developer.apple.com/documentation/swift/sendable)** — Reference documentation for the `Sendable` protocol, including the rules for automatic conformance.

### WWDC sessions

| Session | Year | Why watch it |
|---|---|---|
| **[Meet async/await in Swift](https://developer.apple.com/videos/play/wwdc2021/10132/)** | 2021 | The foundational session that introduces Swift's async/await. Covers suspension points, async sequences, and how the runtime schedules work. Start here. |
| **[Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/)** | 2022 | Covers `Sendable`, actor isolation, and the path to Swift 6 strict concurrency. Directly relevant to understanding `@MainActor` and `@unchecked Sendable`. |
| **[Protect mutable state with Swift actors](https://developer.apple.com/videos/play/wwdc2021/10133/)** | 2021 | Deep dive into the actor model — what actors are, how isolation works, and when to use `@MainActor` vs custom actors. |
| **[Swift concurrency: Behind the scenes](https://developer.apple.com/videos/play/wwdc2021/10254/)** | 2021 | How the Swift concurrency runtime actually works — the cooperative thread pool, continuation stealing, and why it avoids thread explosion. Watch this if you want to understand the runtime, not the syntax. |

### Swift Evolution proposals

- **[SE-0306: Actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0306-actors.md)** — The proposal that introduced actors to Swift. Explains the design rationale, how actor isolation works, and the relationship between actors and `Sendable`.

- **[SE-0302: Sendable and @Sendable closures](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0302-concurrent-value-and-concurrent-closures.md)** — The proposal that introduced `Sendable` (originally called `ConcurrentValue`). Covers the automatic conformance rules and `@unchecked Sendable`.

- **[SE-0316: Global actors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0316-global-actors.md)** — The proposal that introduced `@MainActor` and the `@globalActor` attribute. Explains how global actors provide compile-time isolation for types that need to run on a specific thread.
