# Part 3 — SwiftUI and Declarative UI

This part covers how SwiftUI turns state into pixels. You will learn the View protocol,
view composition, modifiers, state management, observation, bindings, result builders,
conditional rendering, accessibility, and the rendering cycle — all grounded in the
Hush codebase.

If you have used Yew, Iced, or Ratatui in Rust, many of these ideas will feel familiar.
The syntax is different, but the mental model is the same: describe what the UI should
look like given the current state, and let the framework figure out the rest.

---

## Table of contents

- [The View protocol](#the-view-protocol)
- [View composition: building UIs from small pieces](#view-composition-building-uis-from-small-pieces)
- [View modifiers: the chaining pattern](#view-modifiers-the-chaining-pattern)
- [State management: the @State property wrapper](#state-management-the-state-property-wrapper)
- [The @Observable macro and observation](#the-observable-macro-and-observation)
- [Bindings: two-way data flow](#bindings-two-way-data-flow)
- [@ViewBuilder and result builders](#viewbuilder-and-result-builders)
- [Conditional rendering and ForEach](#conditional-rendering-and-foreach)
- [Accessibility](#accessibility)
- [The rendering cycle: what actually happens](#the-rendering-cycle-what-actually-happens)
- [Key resources](#key-resources)

---

## The View protocol

Every piece of UI in SwiftUI is a struct that conforms to the `View` protocol. The
protocol has a single requirement: a computed property called `body` that returns
`some View`.

```swift
protocol View {
    associatedtype Body: View
    @ViewBuilder var body: Self.Body { get }
}
```

This is analogous to implementing a trait in Rust. If you have used Iced, think of
`impl Widget for MyComponent`. The `body` property is the trait method you implement —
it returns a description of what this view should look like.

The return type `some View` is an **opaque return type**. It means "I return a specific
concrete type that conforms to `View`, but I do not expose which type it is." Rust has
the same concept: `-> impl Widget`. The compiler knows the exact type; callers do not.
This lets Swift erase complex nested generic types that would otherwise be unreadable.

A critical point: **views are value types**. They are structs, not classes. They are
cheap to create and destroy. SwiftUI recreates your view structs frequently — potentially
on every state change. Your `body` property is not called once; it is called whenever
the framework needs a fresh description of your UI. Views are *descriptions*, not the
actual pixels on screen. They are blueprints that SwiftUI reads, diffs against the
previous blueprint, and uses to update the real rendering tree.

Let us walk through `AudioProcessRow` (`Hush/Views/AudioProcessRow.swift`), line by line:

```swift
struct AudioProcessRow: View {                     // 1
    let process: AudioProcess                      // 2
    let isMuted: Bool                              // 3
    let onToggle: () -> Void                       // 4

    @State private var isHovering = false          // 5

    var body: some View {                          // 6
        HStack(spacing: 8) {                       // 7
            // ... icon, text, spacer, mute indicator
        }
        .padding(.horizontal, 12)                  // 8
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        // ... accessibility modifiers
    }
}
```

1. **`struct AudioProcessRow: View`** — a value type conforming to the `View` protocol.
2. **`let process: AudioProcess`** — input data, passed in by the parent view. Immutable.
3. **`let isMuted: Bool`** — another input. The parent decides whether this process is muted.
4. **`let onToggle: () -> Void`** — a closure the parent provides. When the row is tapped,
   it calls this closure. This is how actions flow *upward* — the row does not know how
   muting works, it delegates the action to whoever created it.
5. **`@State private var isHovering = false`** — view-local state managed by SwiftUI.
   Covered in detail in the [State management](#state-management-the-state-property-wrapper)
   section below.
6. **`var body: some View`** — the required protocol property. Returns the UI description.
7. **`HStack(spacing: 8)`** — a horizontal stack. Layout containers are views themselves.
8. **`.padding(...)`, `.background(...)`, etc.** — view modifiers, each wrapping the view
   in a new type. Covered in [View modifiers](#view-modifiers-the-chaining-pattern).

> **Rust parallel**: In Iced, you write a `view(&self) -> Element<Message>` method that
> returns a tree of widgets. `AudioProcessRow` is structurally identical — a struct with
> data fields and a method that returns a UI tree. The difference is that SwiftUI uses a
> protocol + computed property instead of a trait + method.

---

## View composition: building UIs from small pieces

SwiftUI's composition model is recursive: views contain views contain views. An `HStack`
is a view. A `Text` is a view. An `AudioProcessRow` is a view. A `MenuContentView` is
a view. You build complex UIs by assembling small, focused pieces.

### Layout primitives

SwiftUI provides built-in layout containers:

| Container | Purpose | Rust analogy |
|---|---|---|
| `VStack` | Vertical stack (top to bottom) | Ratatui `Layout::vertical` |
| `HStack` | Horizontal stack (left to right) | Ratatui `Layout::horizontal` |
| `ZStack` | Overlay stack (back to front) | Layered rendering |
| `Spacer` | Flexible empty space | Flex grow in CSS |
| `Divider` | Visual separator line | A horizontal rule |
| `ScrollView` | Scrollable container | — |
| `LazyVStack` | Like `VStack`, but only creates visible children | Virtual list |

### How MenuContentView composes sections

`MenuContentView` (`Hush/Views/MenuContentView.swift`) uses computed properties to
split its `body` into logical sections:

```swift
struct MenuContentView: View {
    var viewModel: AppListViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            processList
            errorBanner
            Divider()
            footer
        }
        .frame(width: 280)
    }

    private var header: some View { ... }

    @ViewBuilder
    private var processList: some View { ... }

    @ViewBuilder
    private var errorBanner: some View { ... }

    private var footer: some View { ... }
}
```

Each computed property — `header`, `processList`, `errorBanner`, `footer` — returns
`some View`. The `body` assembles them vertically. This pattern keeps `body` readable:
you see the layout structure at a glance, and each section's implementation lives in its
own focused block.

This is not a SwiftUI-specific feature. It is standard Swift: a computed property that
returns a value. But it works particularly well with SwiftUI because `some View` lets
you return different concrete types from each property without exposing the complexity.

### The complete Hush view tree

Here is every view in Hush, from the app entry point down to leaf elements:

```
HushApp
└── MenuBarExtra (icon: speaker.wave.2.fill / speaker.slash.fill)
    └── MenuContentView
        └── VStack(spacing: 0)
            ├── header
            │   └── HStack
            │       ├── Text("Hush")                    .font(.headline)
            │       ├── Text("v1.0")                    .font(.caption2)
            │       ├── Spacer
            │       └── [if anyMuted] Button("Unmute All")
            │
            ├── Divider
            │
            ├── processList
            │   ├── [if processes.isEmpty] VStack (empty state)
            │   │   ├── Image(systemName: "speaker.wave.2")
            │   │   ├── Text("No apps playing audio")
            │   │   └── Text("Apps will appear here...")
            │   │
            │   └── [else] ScrollView
            │       └── LazyVStack(spacing: 2)
            │           └── ForEach(processes)
            │               └── AudioProcessRow
            │                   └── HStack(spacing: 8)
            │                       ├── Image (app icon or placeholder)
            │                       ├── Text(process.name)
            │                       ├── [if paused & muted] Text("paused")
            │                       ├── Spacer
            │                       └── Image (speaker icon)
            │
            ├── errorBanner
            │   └── [if let error] VStack
            │       ├── Divider
            │       ├── Text(error.message)
            │       └── [if .permissionDenied] Button("Open System Settings")
            │
            ├── Divider
            │
            └── footer
                └── VStack(spacing: 0)
                    ├── Toggle("Launch at Login")
                    ├── Divider
                    └── Button("Quit Hush")
```

Every node in this tree is a `View` struct. The tree is rebuilt (in part or in whole)
whenever observed state changes. But — and this matters — SwiftUI does not rebuild the
*entire* tree every time. It identifies which parts changed and only re-evaluates those
subtrees. The [rendering cycle](#the-rendering-cycle-what-actually-happens) section
explains how.

---

## View modifiers: the chaining pattern

View modifiers are methods that take a view, wrap it, and return a new view. Each call
produces a new type:

```swift
Text("Hush")                     // Type: Text
    .font(.headline)             // Type: ModifiedContent<Text, _FontModifier>
    .foregroundStyle(.tertiary)  // Type: ModifiedContent<ModifiedContent<...>, ...>
```

You never see these nested types because `some View` erases them. But they exist at
compile time, and the compiler uses them to specialize rendering.

> **Rust parallel**: View modifiers work like iterator adapters. `iter.map().filter().take()`
> wraps each step in a new type (`Map<Filter<Take<...>>>`). The order of adapters matters.
> SwiftUI modifiers work identically — each wraps the previous result, and the order
> determines behavior.

### Order matters

The order of modifiers changes the result:

```swift
// Padding THEN background: the background includes the padding area
Text("Hello")
    .padding()
    .background(.blue)

// Background THEN padding: the background covers only the text, padding is outside
Text("Hello")
    .background(.blue)
    .padding()
```

The first produces a blue box with space between the text and the edges. The second
produces a tight blue box around the text with transparent padding around it. The modifier
wraps whatever came before it — so `.background` colors everything inside its input view,
including any padding already applied.

### Modifiers in Hush

Here is the complete modifier chain on `AudioProcessRow`'s outer `HStack`:

```swift
HStack(spacing: 8) { ... }
    .padding(.horizontal, 12)       // Add 12pt left/right padding
    .padding(.vertical, 6)          // Add 6pt top/bottom padding
    .background(                     // Fill background color (includes padding)
        isHovering ? Color.primary.opacity(0.06) : Color.clear
    )
    .clipShape(                      // Clip to rounded rectangle (visual masking)
        RoundedRectangle(cornerRadius: 4)
    )
    .contentShape(Rectangle())       // Hit-test shape (the entire rectangle is tappable)
    .onTapGesture(perform: onToggle) // Gesture recognizer
    .onHover { isHovering = $0 }     // Hover tracking (macOS)
```

Each modifier explained:

- **`.padding(.horizontal, 12)`** — adds 12 points of horizontal inset. The content area
  grows, and everything below this modifier (like `.background`) sees the padded frame.
- **`.background(...)`** — fills the background of the view with a color. Because this
  comes after `.padding()`, the colored area includes the padding.
- **`.clipShape(RoundedRectangle(cornerRadius: 4))`** — clips the rendered pixels to a
  rounded rectangle. Anything outside this shape is invisible.
- **`.contentShape(Rectangle())`** — defines the hit-testing area. Without this, only
  the visible content (text, icon) would respond to taps. With it, the entire rectangular
  area — including empty space from `Spacer` — is tappable.
- **`.onTapGesture(perform: onToggle)`** — attaches a tap gesture handler. When the user
  clicks anywhere in the content shape, the `onToggle` closure fires.
- **`.onHover { isHovering = $0 }`** — tracks mouse hover (macOS-specific). The closure
  receives `true` when the cursor enters and `false` when it leaves. This updates the
  `@State` property, which triggers a re-render of the background color.

The header in `MenuContentView` uses modifiers for typography:

```swift
Text("Hush")
    .font(.headline)                // System headline font (bold, ~17pt)

Text("v\(...)")
    .font(.caption2)               // System caption2 font (smallest, ~11pt)
    .foregroundStyle(.tertiary)     // Third-level gray (very subtle)
```

`.font()` sets the text size and weight. `.foregroundStyle()` sets the color. SwiftUI
uses semantic styles (`.secondary`, `.tertiary`, `.quaternary`) that adapt to light mode,
dark mode, and accessibility settings automatically.

---

## State management: the @State property wrapper

`@State` creates view-local mutable state that persists across re-renders. Without it,
all properties on a view struct would be immutable (structs are value types, and `body`
is a getter — you cannot mutate properties in a getter).

> **Rust parallel**: `@State` is like a `RefCell` that the framework manages for you.
> It provides interior mutability on an otherwise immutable struct. The framework owns
> the actual storage and hands your view a reference to it each time `body` is evaluated.

Here is how Hush uses `@State` in `AudioProcessRow`:

```swift
struct AudioProcessRow: View {
    let process: AudioProcess       // Immutable inputs from parent
    let isMuted: Bool
    let onToggle: () -> Void

    @State private var isHovering = false   // Mutable state owned by SwiftUI

    var body: some View {
        HStack(spacing: 8) { ... }
            .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
            .onHover { isHovering = $0 }    // Writes to @State
    }
}
```

When the cursor enters the row, `.onHover` sets `isHovering = true`. This writes to the
`@State` storage. SwiftUI detects the change and re-evaluates `body`. The background
expression now reads `true` and returns `Color.primary.opacity(0.06)` — a light highlight.
When the cursor leaves, the cycle repeats with `false`, and the background goes back to
`Color.clear`.

Key rules for `@State`:

1. **`@State` is for the view's own transient state** — hover effects, animation flags,
   local text field content. It is *not* for app-wide data. App data belongs in an
   `@Observable` object (your ViewModel).

2. **The initial value is set once.** When you write `@State private var isHovering = false`,
   SwiftUI creates the storage with `false` the first time it renders this view. Subsequent
   re-renders do *not* reset it to `false` — the storage persists as long as SwiftUI
   considers this the "same" view (same position in the view tree, same identity).

3. **Always mark `@State` as `private`.** Other views should not reach into your state.
   If a child view needs to write to state owned by a parent, use a `Binding` (covered
   in the next sections).

4. **Writing to `@State` triggers a re-render.** This is the mechanism that closes the
   `UI = f(state)` loop: mutate state, framework re-evaluates body, screen updates.

---

## The @Observable macro and observation

`@State` handles view-local state. But where does your application's *real* data live?
In Hush, the answer is `AppListViewModel` — and it uses the `@Observable` macro to let
SwiftUI watch it for changes.

### How @Observable works

The `@Observable` macro (Swift 5.9, macOS 14+) rewrites a class so that every stored
property automatically notifies observers when it changes. You do not mark individual
properties. The macro handles all of them:

```swift
@Observable
@MainActor
final class AppListViewModel {
    var processes: [AudioProcess] = []       // Tracked automatically
    var mutedProcessIDs: Set<String> = []    // Tracked automatically
    var error: HushError?                    // Tracked automatically
    var launchAtLogin = false                // Tracked automatically

    var anyMuted: Bool { !mutedProcessIDs.isEmpty }  // Computed — tracked via its dependency
    // ...
}
```

When you read a property of an `@Observable` class inside a SwiftUI `body`, the framework
records that access. Later, when that property changes, SwiftUI knows exactly which views
read it and re-evaluates only those views.

This observation is **fine-grained**. If `MenuContentView.body` reads `viewModel.processes`
and `viewModel.anyMuted`, but `AudioProcessRow.body` reads `process.name` and `isMuted`,
then:

- A change to `viewModel.processes` re-evaluates `MenuContentView.body` (and by extension,
  the `processList` section).
- A change to `viewModel.error` re-evaluates only the parts of `MenuContentView.body`
  that read `error` — the `errorBanner` section.
- A change to `viewModel.launchAtLogin` re-evaluates the `footer` section.

This is not a coarse "the whole screen re-renders" system. SwiftUI tracks property-level
read access and scopes invalidation to the views that depend on each property.

### Which properties drive which views

```
AppListViewModel                          Views that read it
──────────────────────────────────────────────────────────────

processes: [AudioProcess]  ──────────────► MenuContentView.processList
                                           (ForEach iterates this array)

mutedProcessIDs: Set<String> ────────────► MenuContentView.processList
                                           (each row checks .contains())
                                          MenuContentView.header
                                           (via anyMuted computed property)
                                          HushApp.body
                                           (menu bar icon via anyMuted)

error: HushError? ──────────────────────► MenuContentView.errorBanner
                                           (if let error = viewModel.error)

launchAtLogin: Bool ────────────────────► MenuContentView.footer
                                           (Toggle reads this via Binding)

anyMuted: Bool (computed) ──────────────► MenuContentView.header
                                           (controls "Unmute All" visibility)
                                          HushApp.body
                                           (controls menu bar icon)
```

Notice that `anyMuted` is a computed property: `var anyMuted: Bool { !mutedProcessIDs.isEmpty }`.
Because it reads `mutedProcessIDs`, observation tracks through the dependency chain.
When `mutedProcessIDs` changes, any view that read `anyMuted` also gets re-evaluated.

### How HushApp wires it up

In `HushApp.swift`, the ViewModel is created as `@State`:

```swift
@main
struct HushApp: App {
    @State private var viewModel = AppListViewModel()

    var body: some Scene {
        MenuBarExtra("Hush", systemImage: viewModel.anyMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") {
            MenuContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
```

`@State` here ensures the `AppListViewModel` instance survives across re-renders of
`HushApp.body`. The ViewModel is created once and persists for the lifetime of the app.
SwiftUI owns the storage; the view struct is recreated, but the `@State` storage is not.

> **Rust parallel**: There is no direct equivalent to `@Observable` in Rust. The closest
> analogy is a reactive signals system (like Leptos signals, or SolidJS in the web world).
> In Iced, your entire model is diffed on every update. In Elm, every state change runs
> through the update function and the view re-renders entirely. SwiftUI's observation
> system is more granular — it tracks individual property access at runtime and only
> invalidates the views that depend on the changed property. Think of it as automatic,
> compiler-assisted dependency tracking.

---

## Bindings: two-way data flow

Data normally flows one direction in SwiftUI: from owner to view. But some controls —
toggles, text fields, sliders — need to both *read* and *write* a value. That is what
`Binding<T>` provides.

> **Rust parallel**: A `Binding<T>` is conceptually like passing `&mut T`, but through
> a framework-managed indirection. The view does not own the data; it gets a handle that
> can read and write through getter and setter closures.

### Custom Binding in Hush

The `footer` in `MenuContentView` contains a `Toggle` for "Launch at Login":

```swift
Toggle("Launch at Login", isOn: Binding(
    get: { viewModel.launchAtLogin },
    set: { _ in viewModel.toggleLaunchAtLogin() }
))
```

`Toggle` requires a `Binding<Bool>` — it needs to read the current value (to show
checked/unchecked) and write back when the user clicks. But Hush does not want a direct
write to `viewModel.launchAtLogin`. The setter needs to call `SMAppService.register()` or
`unregister()`, which can fail. So the code creates a custom `Binding` with explicit
`get` and `set` closures:

- **`get`**: returns the current value of `viewModel.launchAtLogin`
- **`set`**: ignores the new value from the toggle and calls `viewModel.toggleLaunchAtLogin()`,
  which handles the registration logic, error handling, and then updates `launchAtLogin`
  only on success

This pattern — custom `Binding(get:set:)` — is common when you need validation, side
effects, or when the view model method handles the state update.

### @Bindable

When you have an `@Observable` object and want to create bindings to its properties,
you use the `@Bindable` property wrapper:

```swift
struct SomeView: View {
    @Bindable var viewModel: SomeViewModel

    var body: some View {
        TextField("Name", text: $viewModel.name)  // $ creates a Binding
    }
}
```

The `$` prefix syntax creates a `Binding` to the property. Hush does not use `@Bindable`
because it does not have any views that need direct two-way bindings to ViewModel
properties — its `Toggle` uses the custom `Binding(get:set:)` pattern instead, and
`AudioProcessRow` communicates through a closure.

### Bindings vs closures

Hush uses two different patterns for child-to-parent communication:

| Pattern | Used in | When to choose it |
|---|---|---|
| `Binding(get:set:)` | `footer` Toggle | The child control *requires* a `Binding` (like `Toggle`, `TextField`, `Slider`) |
| Closure `() -> Void` | `AudioProcessRow.onToggle` | The child fires a discrete action ("this happened"), and the parent decides what to do |

`AudioProcessRow` takes `onToggle: () -> Void` rather than a binding. The row does not
need to write a boolean — it fires an event: "the user tapped me." The parent
(`MenuContentView`) handles this by calling `viewModel.toggleMute(for: process)`. This
keeps the row decoupled from the muting logic.

Choose `Binding` when the child needs read-write access to a value. Choose closures when
the child reports events and the parent decides how to respond.

---

## @ViewBuilder and result builders

Look at the `body` property of any SwiftUI view. You list multiple views one after
another, without separating them with commas or wrapping them in an array:

```swift
var body: some View {
    VStack {
        Text("Hello")
        Text("World")
        Divider()
    }
}
```

In normal Swift, a function or computed property returns a *single* value. So how does
this work? The answer is **`@ViewBuilder`** — a *result builder* that transforms a block
of view expressions into a single composite view.

> **Rust parallel**: Result builders are like proc macros that transform syntax. If you
> have used `html!{}` in Yew, where you write what looks like HTML inside Rust code and
> a proc macro transforms it into `VNode` construction calls — `@ViewBuilder` does the
> same thing. It takes view expressions listed sequentially and transforms them into
> nested `TupleView` or conditional types at compile time.

### Why @ViewBuilder is needed

Swift functions return one value. But a view body wants to express "here are five child
views." `@ViewBuilder` bridges this gap. When you write:

```swift
VStack {
    Text("A")
    Text("B")
    Text("C")
}
```

The `@ViewBuilder` result builder transforms this into something like:

```swift
VStack {
    TupleView<(Text, Text, Text)>(Text("A"), Text("B"), Text("C"))
}
```

The `body` property on the `View` protocol is annotated with `@ViewBuilder` by default.
That is why you can list multiple views without any ceremony. You can also annotate your
own computed properties and functions with `@ViewBuilder`.

### @ViewBuilder in Hush

`MenuContentView` uses `@ViewBuilder` on two of its computed properties:

```swift
@ViewBuilder
private var processList: some View {
    if viewModel.processes.isEmpty {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.2")
            // ...
        }
    } else {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(viewModel.processes) { process in
                    AudioProcessRow(...)
                }
            }
        }
    }
}

@ViewBuilder
private var errorBanner: some View {
    if let error = viewModel.error {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text(error.message)
            // ...
        }
    }
}
```

These properties need `@ViewBuilder` because they use **conditional logic** (`if/else`,
`if let`) to produce different views depending on state. Without `@ViewBuilder`, the
compiler would see an `if` statement and expect both branches to return the same concrete
type — which they do not (an empty-state `VStack` is a different type from a `ScrollView`).

The `header` and `footer` properties do *not* need `@ViewBuilder` because they each
return a single root view (`HStack` and `VStack` respectively). There is no branching,
so the return type is unambiguous.

### if/else in @ViewBuilder

Inside a `@ViewBuilder` block, `if/else` does not behave like traditional control flow.
It produces a **conditional view** — a type that can be either the `if` branch or the
`else` branch. Both branches exist as possible types at compile time. At runtime, the
framework evaluates the condition and renders the appropriate branch.

This is how `processList` can show either an empty state *or* a scrollable list, without
type errors.

---

## Conditional rendering and ForEach

### Conditional views with if/else

The `errorBanner` in `MenuContentView` demonstrates conditional rendering:

```swift
@ViewBuilder
private var errorBanner: some View {
    if let error = viewModel.error {
        Divider()
        VStack(alignment: .leading, spacing: 4) {
            Text(error.message)
                .font(.caption)
                .foregroundStyle(.red)
            if case .permissionDenied = error {
                Button("Open System Settings") {
                    viewModel.openAudioPrivacySettings()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}
```

When `viewModel.error` is `nil`, this entire section produces *nothing* — no views are
added to the tree. When an error exists, the `Divider`, the error message, and
(conditionally) the "Open System Settings" button all appear.

The nested `if case .permissionDenied = error` uses Swift's pattern matching to check
which enum variant the error is. This is like Rust's `if let HushError::PermissionDenied = error`.

### ForEach for collections

`ForEach` iterates a collection and creates a view for each element. In `processList`:

```swift
ForEach(viewModel.processes) { process in
    AudioProcessRow(
        process: process,
        isMuted: viewModel.mutedProcessIDs.contains(process.id)
    ) {
        viewModel.toggleMute(for: process)
    }
}
```

`ForEach` requires the collection's elements to conform to `Identifiable` — it needs a
stable identity for each element so it can track insertions, deletions, and moves when
the collection changes.

`AudioProcess` conforms to `Identifiable` in `Hush/Model/AudioProcess.swift`:

```swift
struct AudioProcess: Identifiable, Hashable, @unchecked Sendable {
    let id: String    // bundleID, or "pid:<N>" for unbundled processes
    // ...
}
```

The `Identifiable` protocol requires a single property: `id`. It can be any `Hashable`
type. Hush uses the app's bundle identifier (e.g., `"com.spotify.client"`) or a
PID-based string for unbundled processes.

> **Rust parallel**: `Identifiable` is like requiring `Key` or `Id` on items in a
> virtual list. In Yew, you provide a `key` prop when rendering lists. In Iced, widget
> identity is implicit. SwiftUI makes it explicit through the `Identifiable` protocol —
> the framework uses the `id` to determine which rows were added, removed, or reordered.

### Empty state guards

The `processList` property handles the empty case before iterating:

```swift
if viewModel.processes.isEmpty {
    // Empty state UI
} else {
    ScrollView {
        LazyVStack(spacing: 2) {
            ForEach(viewModel.processes) { process in ... }
        }
    }
}
```

This pattern — check `.isEmpty` and show an informational message — is standard for any
list-based UI. The empty state includes an icon, a primary message, and a secondary hint:

```swift
VStack(spacing: 8) {
    Image(systemName: "speaker.wave.2")
        .font(.system(size: 24))
        .foregroundStyle(.quaternary)
    Text("No apps playing audio")
        .font(.callout)
        .foregroundStyle(.secondary)
    Text("Apps will appear here when they produce sound")
        .font(.caption)
        .foregroundStyle(.tertiary)
        .multilineTextAlignment(.center)
}
```

Three levels of visual hierarchy: `.quaternary` for the icon (faintest), `.secondary`
for the primary text, `.tertiary` for the hint. SwiftUI's semantic styles ensure this
looks correct in both light and dark mode.

---

## Accessibility

SwiftUI provides built-in accessibility support. Standard controls (`Button`, `Toggle`,
`Text`) are accessible by default — VoiceOver reads them, the accessibility inspector
can identify them, and keyboard navigation works. But custom interactive views — like
Hush's `AudioProcessRow`, which uses `.onTapGesture` instead of a `Button` — need
explicit accessibility annotations.

Here is how `AudioProcessRow` provides VoiceOver support:

```swift
HStack(spacing: 8) { ... }
    // ... layout and gesture modifiers ...
    .accessibilityElement(children: .combine)
    .accessibilityLabel("\(process.name), \(isMuted ? "muted" : "playing")")
    .accessibilityHint("Click to \(isMuted ? "unmute" : "mute")")
    .accessibilityAddTraits(.isButton)
```

Each modifier explained:

- **`.accessibilityElement(children: .combine)`** — tells VoiceOver to treat this entire
  `HStack` as a single accessible element, combining its children's labels rather than
  reading each child individually. Without this, VoiceOver would read the icon, the name,
  the status, and the speaker icon as separate elements.

- **`.accessibilityLabel(...)`** — provides the primary text VoiceOver reads. For a
  muted Spotify process, this would be "Spotify, muted." This replaces the default
  behavior of reading every `Text` child.

- **`.accessibilityHint(...)`** — tells the user what will happen if they activate this
  element: "Click to unmute." Hints are read after a pause, giving context about the
  action.

- **`.accessibilityAddTraits(.isButton)`** — marks this element as a button. Since the
  row uses `.onTapGesture` instead of `Button`, VoiceOver does not automatically know
  it is interactive. This trait tells assistive technology that the element can be
  activated.

### Why this matters

macOS users who rely on VoiceOver, Switch Control, or keyboard navigation need these
annotations to use the app. SwiftUI handles much of this automatically for standard
controls, but any view that uses gesture recognizers for interaction needs explicit
accessibility markup.

The cost of adding these four modifiers is minimal. The benefit is that the app works
for users who cannot see or use a mouse. SwiftUI's declarative accessibility model means
you describe *what* the element is, not *how* to make it accessible — the framework
handles the integration with the system's accessibility services.

> **Rust parallel**: Rust GUI frameworks vary widely in accessibility support. Iced has
> partial support. Most terminal UI frameworks (Ratatui, etc.) have none, since the
> terminal handles screen reader output. SwiftUI's approach — accessibility as modifiers
> you attach to views — is more integrated than what most Rust frameworks offer.

---

## The rendering cycle: what actually happens

Understanding the rendering cycle clarifies *why* views must be pure functions of state
and *why* `@Observable` tracks property access.

### The cycle

```
┌──────────────────────────────────────────────────────────────────┐
│                    SwiftUI Rendering Cycle                        │
│                                                                  │
│  1. STATE CHANGE                                                 │
│     viewModel.mutedProcessIDs.insert("com.spotify.client")       │
│          │                                                       │
│          ▼                                                       │
│  2. INVALIDATION                                                 │
│     SwiftUI checks: which views read mutedProcessIDs?            │
│     Answer: MenuContentView.processList (via .contains())        │
│             MenuContentView.header (via anyMuted)                │
│             HushApp.body (via anyMuted → menu bar icon)          │
│          │                                                       │
│          ▼                                                       │
│  3. RE-EVALUATION                                                │
│     SwiftUI calls body on the invalidated views.                 │
│     Each body returns a new view tree (struct values).            │
│          │                                                       │
│          ▼                                                       │
│  4. DIFFING                                                      │
│     SwiftUI compares the new tree against the previous tree.     │
│     It finds:                                                    │
│     - AudioProcessRow for Spotify now has isMuted = true         │
│     - The speaker icon changed from .wave.2.fill to .slash.fill  │
│     - The "Unmute All" button appeared in the header             │
│     - The menu bar icon changed                                  │
│          │                                                       │
│          ▼                                                       │
│  5. RENDER                                                       │
│     SwiftUI applies ONLY the differences to the actual screen.   │
│     Unchanged rows (Chrome, Firefox, etc.) are not touched.      │
│                                                                  │
│  Total time: typically under 16ms (one frame at 60fps)           │
└──────────────────────────────────────────────────────────────────┘
```

### A concrete example in Hush

The user clicks the Spotify row to mute it. Here is what happens:

1. **Tap gesture fires** — `.onTapGesture(perform: onToggle)` calls the closure.
2. **Closure calls ViewModel** — `viewModel.toggleMute(for: spotifyProcess)`.
3. **ViewModel mutates state** — `mutedProcessIDs.insert("com.spotify.client")` and
   performs the Core Audio tap.
4. **`@Observable` fires notifications** — the Observation framework detects that
   `mutedProcessIDs` changed.
5. **SwiftUI identifies affected views** — anything that read `mutedProcessIDs` or
   `anyMuted` (which depends on `mutedProcessIDs`) is flagged.
6. **`body` re-evaluates** — `MenuContentView.body` runs. It rebuilds the `processList`,
   including a new `AudioProcessRow` for Spotify with `isMuted: true`.
7. **Diff and patch** — SwiftUI compares the old Spotify row (unmuted) with the new one
   (muted). It finds the icon changed and the foreground color changed. It updates those
   two elements on screen.

Critically, rows for other processes (Chrome, Discord, etc.) are *not* re-rendered.
Their inputs did not change, so SwiftUI's diff finds nothing to update.

### Why views must be pure

The rendering cycle depends on a guarantee: **calling `body` with the same state produces
the same view tree.** If your `body` property has side effects — reading a file, making
a network request, generating a random number — the diff will produce incorrect results
because the old and new trees differ for reasons unrelated to state changes.

This is why:
- `body` should read state and return views. Nothing else.
- Side effects (network calls, file I/O, audio operations) belong in the ViewModel.
- `@State` changes are the *only* mutation that should happen during rendering, and even
  that should be limited to framework-driven updates (like `.onHover`).

> **Rust parallel**: If you have used Ratatui, the contract is the same — your `render`
> function reads state and draws widgets. It must not mutate state or perform I/O, because
> the framework may call it multiple times per frame. SwiftUI enforces this by making views
> structs (value types) whose `body` is a computed property — there is no natural place to
> stash side effects.

### SwiftUI's render tree vs your view structs

Your view structs are *descriptions*. SwiftUI maintains a separate, long-lived **render
tree** (sometimes called the "attribute graph") that represents the actual UI on screen.

```
Your view structs (ephemeral)        SwiftUI's render tree (persistent)
─────────────────────────────        ──────────────────────────────────

MenuContentView { ... }              ┌─ RenderNode: VStack
  recreated on each                  │  ├─ RenderNode: HStack (header)
  body evaluation                    │  │  ├─ TextNode: "Hush"
                                     │  │  └─ TextNode: "v1.0"
AudioProcessRow { ... }              │  ├─ RenderNode: Divider
  recreated on each                  │  ├─ RenderNode: ScrollView
  body evaluation                    │  │  └─ RenderNode: LazyVStack
                                     │  │     ├─ RenderNode: Row (Spotify)
                                     │  │     ├─ RenderNode: Row (Chrome)
                                     │  │     └─ RenderNode: Row (Discord)
                                     │  ├─ RenderNode: Divider
                                     │  └─ RenderNode: VStack (footer)
                                     └─────────────────────────────────

  Your structs are INPUTS.           The render tree is the OUTPUT.
  They describe what should          It represents what is on screen.
  be on screen.                      SwiftUI diffs your descriptions
                                     against this tree.
```

This is analogous to a virtual DOM in web frameworks (React, Yew). Your view structs
are the virtual representation. SwiftUI's render tree is the real representation. The
framework diffs them and applies minimal updates.

---

## Key resources

### Apple documentation

- **[View protocol](https://developer.apple.com/documentation/swiftui/view)** — The
  foundation of everything in SwiftUI. Read the overview and the list of built-in
  modifiers.

- **[ViewBuilder](https://developer.apple.com/documentation/swiftui/viewbuilder)** —
  Documentation on the result builder that enables SwiftUI's DSL syntax.

- **[Managing Model Data in Your App](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app)** —
  Apple's guide to `@Observable`, `@State`, `@Binding`, and data flow.

- **[Accessibility for SwiftUI](https://developer.apple.com/documentation/swiftui/accessibility)** —
  Complete reference for accessibility modifiers and best practices.

### WWDC sessions

| Session | Year | Why watch it |
|---|---|---|
| **[Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/)** | 2023 | The definitive session on `@Observable`. Explains how SwiftUI tracks property access and scopes re-renders. Directly relevant to understanding Hush's `AppListViewModel`. |
| **[Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/)** | 2021 | Deep dive into view identity, lifetime, and the rendering cycle. Explains *why* `ForEach` needs `Identifiable`, how SwiftUI decides two views are "the same," and what triggers re-evaluation. |
| **[Data Essentials in SwiftUI](https://developer.apple.com/videos/play/wwdc2020/10040/)** | 2020 | Covers `@State`, `@Binding`, and the single-source-of-truth principle. Uses the older `ObservableObject` pattern, but the data flow concepts apply directly to `@Observable`. |

### For Rust developers

- **[Yew (Rust WebAssembly framework)](https://yew.rs/)** — Uses `html!{}` proc macro
  for declarative UI. The closest Rust analogy to `@ViewBuilder`. Compare Yew's
  `html!{ <div>{ for items.iter().map(render_item) }</div> }` with SwiftUI's
  `VStack { ForEach(items) { item in ItemRow(item: item) } }`.

- **[Iced (Rust native GUI)](https://iced.rs/)** — `view(&self) -> Element<Message>` is
  structurally identical to SwiftUI's `var body: some View`. Iced's `Column`, `Row`,
  `Scrollable` map to SwiftUI's `VStack`, `HStack`, `ScrollView`. The composition model
  is the same — the syntax differs.

---

## Summary

The core ideas in this part:

1. **Views are structs conforming to the `View` protocol.** They are cheap value types,
   recreated frequently. The `body` computed property returns a description, not actual
   pixels.

2. **Composition is recursive.** Views contain views. Split complex views into computed
   properties (like Hush's `header`, `processList`, `errorBanner`, `footer`).

3. **Modifiers wrap views in new types.** Order matters. Each modifier transforms the
   view it is attached to. Think of iterator adapters in Rust.

4. **`@State` is for view-local transient state.** SwiftUI owns the storage. Changes
   trigger re-renders. Keep it private.

5. **`@Observable` enables fine-grained reactivity.** SwiftUI tracks which properties
   each view reads, and re-evaluates only the views affected by a property change.

6. **`Binding` provides two-way access.** Use `Binding(get:set:)` when you need custom
   logic. Use closures when the child reports events without needing read access.

7. **`@ViewBuilder` is a result builder** that lets you list multiple views and use
   `if/else` in view-producing contexts. It transforms your DSL-like code into concrete
   Swift types at compile time.

8. **`ForEach` requires `Identifiable`.** Stable identity lets SwiftUI efficiently diff
   collections.

9. **Accessibility modifiers describe what an element is.** SwiftUI handles integration
   with the system. Four modifiers on `AudioProcessRow` make it fully accessible.

10. **The rendering cycle is: state change → invalidation → body re-evaluation → diff → render.**
    Views must be pure functions of state because the framework depends on deterministic
    diffing.

With these foundations, you understand how Hush's UI is built from `HushApp` all the way
down to individual `Text` elements, how state flows through the system, and why the code
is structured the way it is.
