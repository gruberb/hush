# Part 0 — Thinking in UI: How to Architect a macOS Application

Before you read a single line of Swift, you need to understand *how* GUI applications
work — because it is fundamentally different from how you have been writing Rust programs.

This part covers no code. It covers the mental model. Get this right first, and every
line of Swift you read afterward will click into place.

---

## Table of contents

- [The mental shift: from sequential to reactive](#the-mental-shift-from-sequential-to-reactive)
- [The event loop: you have already seen this](#the-event-loop-you-have-already-seen-this)
- [State is the center of everything](#state-is-the-center-of-everything)
- [UI = f(state) — the core equation](#ui--fstate--the-core-equation)
- [Architectural patterns: a brief history](#architectural-patterns-a-brief-history)
  - [MVC — Model-View-Controller](#mvc--model-view-controller)
  - [MVVM — Model-View-ViewModel](#mvvm--model-view-viewmodel)
  - [The Composable Architecture (TCA)](#the-composable-architecture-tca)
- [What Apple recommends today](#what-apple-recommends-today)
- [How Hush implements MVVM](#how-hush-implements-mvvm)
- [Decision framework: choosing a pattern](#decision-framework-choosing-a-pattern)
- [Key resources](#key-resources)

---

## The mental shift: from sequential to reactive

A Rust CLI program looks like this, conceptually:

```
fn main() {
    let input = read_args();
    let data = process(input);
    let output = format(data);
    print(output);
    // program ends
}
```

You control the flow. You call functions in order. Data moves top to bottom.
When `main` returns, the process exits.

A GUI application is the opposite. **You do not control the flow. The framework does.**
Your code sits and waits. When something happens — the user clicks a button, a timer
fires, an audio device changes — the framework calls *your* code. Then your code
finishes, and the framework goes back to waiting.

This is called **inversion of control**, and it is the single biggest conceptual
difference between writing a CLI tool and writing a GUI application.

```
┌─────────────────────────────────────────────────────┐
│                  Your Rust CLI                       │
│                                                      │
│   main() ──► parse ──► process ──► output ──► exit   │
│                                                      │
│   You drive. Linear. Predictable.                    │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│                  A macOS GUI App                     │
│                                                      │
│   ┌──────────────────────────────┐                   │
│   │       Framework Run Loop     │ ◄── always running│
│   │                              │                   │
│   │  wait for event...           │                   │
│   │  ├─ user clicked? ──► call your onClick handler  │
│   │  ├─ timer fired?  ──► call your onTimer handler  │
│   │  ├─ data changed? ──► re-render the UI           │
│   │  └─ nothing?      ──► keep waiting               │
│   │                              │                   │
│   └──────────────────────────────┘                   │
│                                                      │
│   Framework drives. Event-driven. Asynchronous.      │
└─────────────────────────────────────────────────────┘
```

Your "application code" is the collection of handlers and state that the framework
orchestrates. You never write a `while` loop that polls for user input. The framework
does that. You register what you care about, and it calls you.

---

## The event loop: you have already seen this

If you have used **Tokio** in Rust, you already understand this pattern:

```rust
#[tokio::main]
async fn main() {
    // You don't write the event loop.
    // Tokio runs it. You register futures.
    let listener = TcpListener::bind("0.0.0.0:8080").await.unwrap();
    loop {
        let (socket, _) = listener.accept().await.unwrap();
        tokio::spawn(handle_connection(socket));
    }
}
```

Tokio's runtime is an event loop. It waits for I/O readiness, then dispatches your
futures. A macOS application works identically — except instead of I/O readiness events,
it waits for **user interactions**, **system notifications**, and **timer callbacks**.

The macOS event loop is called the **run loop** (specifically, `NSRunLoop` / `CFRunLoop`).
SwiftUI abstracts this away entirely — you never interact with it directly. But knowing
it exists helps you understand why:

- UI updates must happen on the **main thread** (the run loop runs there)
- Long-running work must be dispatched elsewhere (to avoid freezing the UI)
- Callbacks and timers fire *between* UI rendering passes

> **Rust parallel**: Think of `@MainActor` in Swift as similar to requiring `Send` in
> Rust — it is a compile-time annotation that guarantees code runs in a specific
> execution context. The difference is that `@MainActor` pins code to a single thread
> (the main thread), while Rust's `Send` allows movement *between* threads.

---

## State is the center of everything

In a CLI tool, data flows through functions and comes out the other end. You often do
not need to "store" intermediate state — the call stack holds it.

In a GUI application, **state persists across interactions**. The user clicks "Mute" on
Spotify. Five minutes later, they click "Unmute." Your application needs to remember that
Spotify was muted, which audio objects were involved, and what the current output device
is — across those five minutes of idle time.

This leads to a question that does not exist in CLI programming:

> **Where does the state live, who owns it, and how does the UI know when it changed?**

Every GUI architecture pattern is, at its core, an answer to that question.

```
┌─────────────────────────────────────────────────────────────┐
│                    The State Problem                         │
│                                                              │
│   User clicks "Mute Spotify"                                │
│          │                                                   │
│          ▼                                                   │
│   ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│   │    WHERE?     │    │     WHO?     │    │     HOW?     │  │
│   │              │    │              │    │              │  │
│   │ Where is the │    │ Who can      │    │ How does the │  │
│   │ "muted" flag │    │ read/write   │    │ UI know to   │  │
│   │ stored?      │    │ this state?  │    │ re-render?   │  │
│   └──────────────┘    └──────────────┘    └──────────────┘  │
│                                                              │
│   Every architectural pattern answers these three questions. │
└─────────────────────────────────────────────────────────────┘
```

In Rust terms: this is the ownership question, but for *long-lived mutable state* that
multiple parts of the system need to observe. In Rust, you would reach for
`Arc<Mutex<T>>`, or channels, or an actor model. In Swift UI frameworks, you reach for
**observable state** — a mechanism where the framework automatically watches your data
and re-renders the UI when it changes.

---

## UI = f(state) — the core equation

Modern UI frameworks (SwiftUI, React, Elm, Yew) share a single core idea:

> **The UI is a function of the current state.**

You do not manually update labels, show/hide buttons, or toggle colors. You describe
*what the UI should look like for a given state*, and the framework figures out what
changed and updates the screen.

```
┌────────────┐                    ┌────────────────┐
│            │   your declared    │                │
│   State    │ ──── mapping ────► │   UI on Screen │
│            │   (View body)      │                │
└────────────┘                    └────────────────┘
       ▲                                  │
       │                                  │
       │          user interaction        │
       └──────────────────────────────────┘
              (button tap, toggle, etc.)
```

This is a **cycle**:

1. State has some initial value
2. The framework calls your view code, which reads the state and produces a UI description
3. The framework renders that description to the screen
4. The user interacts with the UI (clicks a button, types text)
5. Your event handler mutates the state
6. The framework detects the state change and goes back to step 2

In SwiftUI, the "mapping" is the `body` property of your `View`:

```swift
// This is conceptually: fn render(state: &AppState) -> UIDescription
var body: some View {
    if viewModel.anyMuted {
        Text("Something is muted")   // ← shown when state says so
    } else {
        Text("Nothing is muted")     // ← shown otherwise
    }
}
```

You never write `label.text = "Something is muted"`. You never call `label.hide()`.
You declare intent, and the framework reconciles the current screen with your
declaration. This is called **declarative UI**.

> **Rust parallel**: If you have used the [Yew](https://yew.rs/) framework for
> WebAssembly, or the [Elm architecture](https://guide.elm-lang.org/architecture/),
> this is the same model — `view(model) -> Html`. If you have used
> [Ratatui](https://ratatui.rs/) for terminal UIs, it follows the same principle:
> you render the entire frame from state on every tick.

---

## Architectural patterns: a brief history

Apple's platform has gone through three major architectural eras. Understanding all three
helps you read blog posts, StackOverflow answers, and older documentation without
confusion.

### MVC — Model-View-Controller

**Era**: 2008–2019 (UIKit / AppKit dominant)
**Status**: Still works, but Apple no longer promotes it for new apps

```
┌─────────────────────────────────────────────────────┐
│                       MVC                            │
│                                                      │
│  ┌─────────┐    ┌──────────────┐    ┌─────────┐    │
│  │  Model   │◄───│  Controller  │───►│  View   │    │
│  │          │    │              │    │          │    │
│  │ Data &   │    │ Glue code.  │    │ UIKit    │    │
│  │ business │    │ Reads model,│    │ objects: │    │
│  │ logic    │    │ updates     │    │ buttons, │    │
│  │          │    │ views       │    │ labels,  │    │
│  │          │    │ manually.   │    │ tables   │    │
│  └─────────┘    └──────────────┘    └─────────┘    │
│                        ▲                             │
│                        │                             │
│                   User action                        │
│                  (tap, scroll)                        │
└─────────────────────────────────────────────────────┘
```

**How it works**: The Controller sits between the Model (data) and the View (screen
elements). When the user taps a button, the controller handles it, updates the model,
then *manually* tells the view to update: `label.text = newValue`.

**Why developers moved away**: The controller ends up doing everything. It handles user
input, data transformation, network calls, navigation, and view updates. Apple's own
view controllers (`UIViewController`, `NSViewController`) routinely grew to thousands of
lines. The community called this **"Massive View Controller."**

**The Rust analogy**: MVC is like writing a single function that owns a data struct,
handles all input events, and manually updates a terminal UI by calling individual draw
commands. It works for small programs, but the function becomes unmanageable.

> **You will encounter MVC** when reading older Apple tutorials, Stack Overflow answers
> from before 2020, and any code that uses `UIViewController` or `NSViewController`.
> Hush does not use MVC.

### MVVM — Model-View-ViewModel

**Era**: 2019–present (SwiftUI era)
**Status**: Apple's de facto recommended pattern for SwiftUI apps

```
┌──────────────────────────────────────────────────────────────────┐
│                            MVVM                                   │
│                                                                   │
│  ┌──────────┐    ┌────────────────┐    ┌───────────────────┐     │
│  │  Model    │    │   ViewModel    │    │      View         │     │
│  │          │    │                │    │                   │     │
│  │ Plain    │◄───│ Owns state.   │◄───│ Reads ViewModel   │     │
│  │ data     │    │ Exposes       │    │ properties.       │     │
│  │ structs. │    │ properties    │    │ Declares UI       │     │
│  │ No UI    │    │ the View      │    │ based on state.   │     │
│  │ logic.   │    │ reads.        │    │ Calls ViewModel   │     │
│  │          │    │ Contains      │    │ methods for       │     │
│  │          │    │ business      │    │ user actions.     │     │
│  │          │    │ logic.        │    │                   │     │
│  └──────────┘    └────────────────┘    └───────────────────┘     │
│                         ▲                        │                │
│                         │    user action          │                │
│                         └────────────────────────┘                │
│                                                                   │
│  Data flows:  Model ──► ViewModel ──► View (one direction)       │
│  Actions:     View ──► ViewModel ──► Model (one direction)       │
└──────────────────────────────────────────────────────────────────┘
```

**How it works**: The ViewModel is an *observable* object that owns your application
state. The View *subscribes* to the ViewModel's properties. When a property changes,
SwiftUI automatically re-renders only the parts of the UI that depend on it. The View
never writes to the Model directly — it calls methods on the ViewModel.

**Key insight**: The View does not need to know *how* muting works. It reads
`viewModel.mutedProcessIDs` and calls `viewModel.toggleMute(for: process)`. The
ViewModel handles Core Audio, error management, and state updates. The View handles
layout, colors, and user interaction.

**The Rust analogy**: MVVM is like splitting your program into:
- A `struct AppState` (Model) — plain data, derives `Clone`, `Serialize`, etc.
- An `impl AppState` block with all business logic (ViewModel)
- A `fn render(state: &AppState) -> Frame` function (View)

The key difference from Rust: in Swift, the "subscription" between the ViewModel and
View is automatic. You do not need to call `render()` after each state change. The
framework watches your ViewModel properties and triggers re-renders when they change.
This is what the `@Observable` macro provides.

**Why MVVM fits SwiftUI**: SwiftUI's `View` protocol is designed to be a pure function
of state — you declare what it looks like, you do not imperatively mutate it. MVVM's
separation ensures that the `body` property has a clean, observable data source to read
from, with no side effects.

### The Composable Architecture (TCA)

**Era**: 2020–present (community project by Point-Free)
**Status**: Popular in the community, not an Apple pattern

```
┌──────────────────────────────────────────────────────────────┐
│                  The Composable Architecture                  │
│                                                               │
│  ┌─────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐  │
│  │  View   │──►│  Action  │──►│ Reducer  │──►│  State   │  │
│  │         │   │          │   │          │   │          │  │
│  │ Sends   │   │ An enum  │   │ Pure     │   │ Single   │  │
│  │ actions │   │ of every │   │ function:│   │ source   │  │
│  │         │   │ possible │   │ (State,  │   │ of truth │  │
│  │         │   │ event    │   │ Action)  │   │          │  │
│  │         │   │          │   │ -> State │   │          │──┐│
│  └─────────┘   └──────────┘   └──────────┘   └──────────┘  ││
│       ▲                                                      ││
│       └──────────────────────────────────────────────────────┘│
│                     State drives View re-render               │
└──────────────────────────────────────────────────────────────┘
```

TCA is an opinionated architecture inspired by Redux (JavaScript) and the Elm
Architecture (Haskell/Elm). All state mutations go through a single `Reducer` function
that takes the current state and an action, and returns the new state.

**Why you should know about it**: If you come from the Elm/Redux world, or if you value
the "state machine" approach where every possible transition is an explicit enum case,
TCA will feel natural. Many Swift developers use it for large applications.

**Why Hush does not use it**: TCA adds significant infrastructure (Store, Reducer,
Effect, Dependency injection) that is overkill for an app with one screen, one view
model, and ~800 lines of code. MVVM gives Hush clean separation with zero dependencies.

**When to consider TCA**:
- Apps with complex navigation (multiple screens, deep linking)
- Apps where testability of every state transition is critical
- Teams that want enforced architectural consistency

> **Rust parallel**: TCA is structurally identical to the Elm Architecture. If you have
> used [Iced](https://iced.rs/) for Rust GUI applications, you have used this exact
> pattern — `update(state, message) -> Command`.

---

## What Apple recommends today

Apple does not publish a document titled "Use MVVM." Instead, their recommendations are
implicit in how SwiftUI is designed and what their WWDC sessions teach. Here is what they
steer you toward:

### 1. Use `@Observable` for your data models (Swift 5.9+, iOS 17 / macOS 14)

The `@Observable` macro (introduced at WWDC 2023) replaces the older `ObservableObject`
protocol. It turns a regular Swift class into one that SwiftUI can automatically watch
for changes:

```swift
// Old way (pre-2023): explicit protocol, explicit @Published on each property
class ViewModel: ObservableObject {
    @Published var count = 0        // must mark every property
}

// New way (2023+): just add the macro
@Observable
class ViewModel {
    var count = 0                   // all stored properties tracked automatically
}
```

> **Rust parallel**: `@Observable` is like a derive macro (`#[derive(Observable)]`)
> that rewrites property getters and setters to notify the framework when values change.
> Unlike Rust derive macros which add trait implementations, Swift's `@Observable` macro
> actually rewrites the *body* of your class — it injects tracking code into every
> stored property's getter and setter.

### 2. Use value types (structs) for models, reference types (classes) for ViewModels

Apple recommends:

| Layer | Swift type | Why |
|---|---|---|
| Model (data) | `struct` | Value semantics. Copying is safe. No shared mutable state. Comparable to Rust structs. |
| ViewModel (logic) | `class` with `@Observable` | Needs to be shared by reference between the view and the system. The class is the single owner of mutable state. |
| View | `struct` conforming to `View` | Views are lightweight, recreated frequently. They are descriptions, not long-lived objects. |

This is exactly what Hush does:
- `AudioProcess` is a **struct** (model — pure data)
- `AppListViewModel` is an **@Observable class** (viewModel — owns mutable state)
- `MenuContentView` is a **struct** (view — reads state, describes UI)

### 3. Establish a single source of truth

Every piece of state should have exactly one owner. Other parts of the system read it
or receive a binding to it, but they do not create their own copy.

```
┌──────────────────────────────────────────────────────────┐
│                 Source of Truth Hierarchy                  │
│                                                           │
│  ┌───────────────────────┐                                │
│  │    AppListViewModel   │  ← OWNS processes, mutedIDs,  │
│  │    (@Observable)      │    error, launchAtLogin         │
│  └───────────┬───────────┘                                │
│              │                                            │
│         passes down                                       │
│              │                                            │
│  ┌───────────▼───────────┐                                │
│  │   MenuContentView     │  ← READS viewModel properties  │
│  │   (View)              │    CALLS viewModel methods      │
│  └───────────┬───────────┘                                │
│              │                                            │
│         passes down                                       │
│              │                                            │
│  ┌───────────▼───────────┐                                │
│  │   AudioProcessRow     │  ← READS process, isMuted      │
│  │   (View)              │    CALLS onToggle closure       │
│  └───────────────────────┘                                │
│                                                           │
│  Data always flows DOWN. Actions always flow UP.          │
└──────────────────────────────────────────────────────────┘
```

> **Rust parallel**: This is the ownership model applied to application state. Just as
> Rust enforces single ownership at compile time, SwiftUI encourages single ownership of
> state by convention. The `@Observable` ViewModel is the `&mut` owner; views get the
> equivalent of `&` (shared reference) to read, and closures to request mutations.

### 4. Keep views small and focused

Apple's sample code consistently splits views into small, composable pieces. Each view
does one thing. Hush follows this:

- `MenuContentView` — orchestrates layout (header, list, error banner, footer)
- `AudioProcessRow` — renders one row in the process list
- `HushApp` — just the `MenuBarExtra` entry point

This is similar to how you structure Rust code: small functions with clear inputs and
outputs, composed together.

---

## How Hush implements MVVM

Here is the complete architecture of Hush, mapped to the MVVM pattern:

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Hush Architecture                            │
│                                                                      │
│  ┌─────────────────────┐                                             │
│  │       MODELS         │                                             │
│  │                      │                                             │
│  │  AudioProcess        │  A struct: id, name, icon, pid, objectIDs  │
│  │  HushError           │  An enum: .permissionDenied, .muteFailed   │
│  │  TapSession          │  A struct: tapID, aggregateDeviceID, ioProc│
│  └──────────┬───────────┘                                             │
│             │ used by                                                  │
│             ▼                                                          │
│  ┌─────────────────────────────────────────────┐                      │
│  │              VIEWMODEL                       │                      │
│  │                                              │                      │
│  │  AppListViewModel (@Observable, @MainActor)  │                      │
│  │  ├── processes: [AudioProcess]               │ ◄─ drives the list  │
│  │  ├── mutedProcessIDs: Set<String>            │ ◄─ drives mute icons│
│  │  ├── error: HushError?                       │ ◄─ drives error UI  │
│  │  ├── launchAtLogin: Bool                     │ ◄─ drives checkbox  │
│  │  ├── anyMuted: Bool (computed)               │ ◄─ drives menu icon │
│  │  │                                           │                      │
│  │  │   Methods (actions the View can trigger):  │                      │
│  │  ├── toggleMute(for:)                        │                      │
│  │  ├── unmuteAll()                             │                      │
│  │  ├── toggleLaunchAtLogin()                   │                      │
│  │  └── teardown()                              │                      │
│  │                                              │                      │
│  │  Owns (private):                             │                      │
│  │  ├── AudioProcessMonitor  (enumerates audio) │                      │
│  │  ├── AudioTapManager      (mutes/unmutes)    │                      │
│  │  ├── Device change listener                  │                      │
│  │  └── Muted process cache                     │                      │
│  └──────────────────┬──────────────────────────┘                      │
│                     │ observed by                                      │
│                     ▼                                                  │
│  ┌─────────────────────────────────────────────┐                      │
│  │                  VIEWS                        │                      │
│  │                                              │                      │
│  │  HushApp                                     │                      │
│  │  └── MenuBarExtra (icon depends on anyMuted) │                      │
│  │      └── MenuContentView                     │                      │
│  │          ├── header  (shows "Unmute All" if   │                      │
│  │          │            anyMuted)               │                      │
│  │          ├── processList (iterates processes,  │                      │
│  │          │   └── AudioProcessRow (per app)    │                      │
│  │          ├── errorBanner (shows if error set) │                      │
│  │          └── footer (toggle, quit)            │                      │
│  └──────────────────────────────────────────────┘                      │
│                                                                        │
│  ┌─────────────────────────────────────────────┐                      │
│  │           SYSTEM LAYER (not MVVM)            │                      │
│  │                                              │                      │
│  │  CoreAudioHelper     (HAL property queries)  │                      │
│  │  CoreAudioError      (structured errors)     │                      │
│  │  Core Audio HAL      (Apple's C API)         │                      │
│  │  ServiceManagement   (launch at login)       │                      │
│  └──────────────────────────────────────────────┘                      │
└──────────────────────────────────────────────────────────────────────┘
```

### What makes this work in practice

1. **The ViewModel is the single source of truth.** The `processes` array, the
   `mutedProcessIDs` set, and the `error` value all live in `AppListViewModel`. No
   view creates its own copy.

2. **Views are pure functions of state.** `MenuContentView.body` reads the ViewModel
   and produces a description. It has no `if wasClicked { }` tracking. No stored state
   beyond what SwiftUI manages for hover effects.

3. **Actions flow through the ViewModel.** When a user clicks a row,
   `AudioProcessRow` calls its `onToggle` closure, which calls
   `viewModel.toggleMute(for: process)`. The ViewModel handles the Core Audio work,
   updates its state, and SwiftUI re-renders the affected views.

4. **The ViewModel hides complexity.** The View does not know about Core Audio, process
   taps, aggregate devices, or HAL listeners. It knows about processes, muted IDs, and
   errors. The ViewModel translates between the system layer and the UI layer.

### Mapping files to responsibilities

| File | MVVM Role | Responsibility |
|---|---|---|
| `AudioProcess.swift` | Model | Data struct representing an audio process |
| `AppListViewModel.swift` | ViewModel | Owns state, orchestrates monitoring and muting |
| `HushError` (in ViewModel file) | Model | Structured error type for UI display |
| `MenuContentView.swift` | View | Main menu bar UI layout |
| `AudioProcessRow.swift` | View | Single row in the process list |
| `HushApp.swift` | View (entry point) | App launch, menu bar icon |
| `AudioTapManager.swift` | Service (used by ViewModel) | Core Audio tap lifecycle |
| `AudioProcessMonitor.swift` | Service (used by ViewModel) | Process enumeration and listening |
| `CoreAudioHelpers.swift` | Infrastructure | Low-level Core Audio property access |

> **Rust parallel**: This is like having `models/`, `handlers/`, and `views/` in a web
> application. The ViewModel is your request handler — it receives actions, calls into
> domain logic, and returns the state that the response (UI) is built from.

---

## Decision framework: choosing a pattern

When starting a new macOS or iOS app, use this decision tree:

```
                    How complex is your app?
                            │
              ┌─────────────┼─────────────┐
              ▼             ▼             ▼
         1 screen      2-5 screens    Many screens,
         simple state  moderate state deep navigation
              │             │             │
              ▼             ▼             ▼
           MVVM          MVVM         Consider TCA
        (like Hush)   (still works)   or MVVM + Router
              │             │             │
              ▼             ▼             ▼
         1 ViewModel   1-3 ViewModels  Formalized state
                                       management
```

**For your first apps, use MVVM.** It is what Apple's tools are designed for, what their
sample code demonstrates, and what the `@Observable` macro naturally supports. You can
always adopt TCA later if your app's complexity warrants it.

---

## Key resources

### Apple documentation (start here)

- **[Choosing Between Structures and Classes](https://developer.apple.com/documentation/swift/choosing-between-structures-and-classes)** — Apple's guidance on when to use value types vs reference types. Directly relevant to understanding why models are structs and ViewModels are classes.

- **[Managing Model Data in Your App](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)** — Apple's primary documentation on `@Observable`, `@State`, and how data flows through a SwiftUI app. Read this alongside Part 3 of this guide.

- **[The Swift Programming Language — Structures and Classes](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/)** — The Swift book chapter on value types vs reference types. Essential background for Part 1.

- **[Value and Reference Types (swift.org)](https://www.swift.org/documentation/articles/value-and-reference-types.html)** — Clear explanation of value semantics vs reference semantics, with the "document copy vs shared link" analogy.

### WWDC sessions (watch these)

| Session | Year | Why watch it |
|---|---|---|
| **[Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/)** | 2023 | Introduces `@Observable`, explains migration from `ObservableObject`. Covers `@State`, `@Environment`, `@Bindable`. This is the most important session for understanding how Hush's ViewModel works. |
| **[Data Essentials in SwiftUI](https://developer.apple.com/videos/play/wwdc2020/10040/)** | 2020 | Foundational session on SwiftUI data flow. Covers `@State`, `@Binding`, `@StateObject`, `@EnvironmentObject`. Uses the older `ObservableObject` pattern, but the data flow concepts are timeless. |
| **[Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/)** | 2021 | Deep dive into how SwiftUI decides identity, lifetime, and when to update views. Essential for understanding performance and debugging unexpected re-renders. |
| **[Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2023/102/)** | 2023 | Overview of Swift 5.9 macros, Observation framework, and SwiftData. Gives you the big picture of the modern Apple platform. |

### Books and community resources

- **[The Swift Programming Language (swift.org)](https://docs.swift.org/swift-book/)** — The official language reference. Free, comprehensive, and well-written. Read the "A Swift Tour" chapter first, then "The Basics" through "Closures." As a Rust developer, you can skip the introductory explanations of concepts like generics and enums — focus on the *syntax differences*.

- **[Hacking with Swift — 100 Days of SwiftUI](https://www.hackingwithswift.com/100/swiftui)** — Paul Hudson's free course that builds a new small app each day. The best way to build muscle memory with SwiftUI after understanding the concepts.

- **[Point-Free](https://www.pointfree.co/)** — Advanced Swift video series. Created by the authors of TCA. Excellent for understanding functional programming patterns in Swift, but save this for after you are comfortable with the basics.

- **[Swift by Sundell](https://www.swiftbysundell.com/)** — Articles and podcast about Swift development patterns. Strong focus on architecture and best practices.

### For Rust developers specifically

- **[Yew (Rust WebAssembly framework)](https://yew.rs/)** — If you want to see the `UI = f(state)` model implemented in Rust, Yew follows the Elm Architecture. Studying it before SwiftUI can help bridge the mental model.

- **[Iced (Rust native GUI)](https://iced.rs/)** — A Rust-native cross-platform GUI library that uses the Elm Architecture (state, message, update, view). The closest Rust equivalent to SwiftUI's declarative model.

---

## Summary

Before writing your first SwiftUI view, internalize these principles:

1. **You do not control execution flow.** The framework runs the event loop. Your code responds to events and declares UI based on state.

2. **State is the center of everything.** Every architectural pattern is an answer to "where does state live, who owns it, and how does the UI know when it changed?"

3. **UI = f(state).** You declare what the UI looks like for a given state. You do not imperatively modify the UI. The framework handles the diff.

4. **Use MVVM for SwiftUI apps.** Models are structs (data). ViewModels are `@Observable` classes (state + logic). Views are structs (UI declarations). Data flows down, actions flow up.

5. **Apple's tools are designed for this.** `@Observable`, `@State`, `Binding`, and SwiftUI's view diffing all assume you are following this pattern. Fighting it leads to pain.

With this mental model in place, you are ready for Part 1 — where you will see how
Swift's type system, memory management, and error handling compare to Rust, using the
Hush codebase as the reference.
