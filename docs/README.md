# Understanding Swift and macOS App Development Through Hush

A comprehensive learning guide for Rust developers, using the Hush codebase
(~800 lines, macOS menu bar app for per-app audio muting) as the primary teaching example.

Every concept includes a Rust analogy, real code from the Hush codebase, diagrams,
and links to Apple documentation and WWDC sessions.

---

## Reading order

| Part | Title | Lines | What you will learn |
|---|---|---|---|
| **[Part 0](part0-thinking-in-ui-architecture.md)** | Thinking in UI: How to Architect a macOS Application | 656 | The mental shift from CLI to GUI. Event loops, state management, MVC vs MVVM vs TCA, what Apple recommends. |
| **[Part 1](part1-swift-through-rust-colored-glasses.md)** | Swift Through Rust-Colored Glasses | 1754 | The Swift language mapped to Rust: structs, classes, ARC vs ownership, enums, optionals, error handling, protocols, generics, closures, access control. |
| **[Part 2](part2-how-macos-apps-work.md)** | How macOS Applications Work | 955 | App bundles, Info.plist, entitlements, code signing, the app lifecycle, menu bar apps, XcodeGen, the build system, logging. |
| **[Part 3](part3-swiftui-and-declarative-ui.md)** | SwiftUI and Declarative UI | 1029 | The View protocol, composition, modifiers, @State, @Observable, Bindings, @ViewBuilder, ForEach, accessibility, the render cycle. |
| **[Part 4](part4-concurrency-and-thread-safety.md)** | Concurrency and Thread Safety | 908 | The main thread, @MainActor, Sendable, Task, async/await, weak references, timers and callbacks, the full concurrency model. |
| **[Part 5](part5-core-audio-and-system-frameworks.md)** | Core Audio and System Frameworks | 1400 | The HAL object model, unsafe pointer operations, error handling, process enumeration, HAL listeners, process taps, aggregate devices, TCC permissions, device switching. |
| **[Part 6](part6-putting-it-all-together.md)** | Putting It All Together | 591 | Five end-to-end walkthroughs (launch, mute, pause, device change, quit) tracing data through every layer. Architectural patterns. What to build next. |

**Total**: ~7,300 lines across 7 documents.

---

## How to use this guide

1. **Read Part 0 first.** It establishes the mental model that everything else builds on.
2. **Read Part 1 with the Swift files open.** Have `Hush/` open in your editor and follow along.
3. **Parts 2–5 can be read in any order**, though the suggested order builds knowledge progressively.
4. **Read Part 6 last.** It ties everything together through concrete walkthroughs.
5. **Modify the code.** The best way to learn is to change something and see what breaks. Try adding a feature from the "What to build next" section in Part 6.
