# Part 6 — Putting It All Together

You have now seen Swift's type system (Part 1), the macOS app model (Part 2), SwiftUI's
declarative UI (Part 3), the concurrency model (Part 4), and Core Audio's system APIs
(Part 5). This final part walks through how all of these pieces compose into Hush — a
working, production-quality macOS menu bar application.

Rather than re-explaining each concept, this part traces **concrete user interactions**
through the entire stack, from click to Core Audio to screen update. You will see how
the architectural decisions from Part 0 play out in practice.

---

## Table of contents

- [The complete data flow](#the-complete-data-flow)
- [Walkthrough 1: app launch](#walkthrough-1-app-launch)
- [Walkthrough 2: the user mutes Spotify](#walkthrough-2-the-user-mutes-spotify)
- [Walkthrough 3: Spotify stops playing (but is still muted)](#walkthrough-3-spotify-stops-playing-but-is-still-muted)
- [Walkthrough 4: the user plugs in headphones](#walkthrough-4-the-user-plugs-in-headphones)
- [Walkthrough 5: the user quits Hush](#walkthrough-5-the-user-quits-hush)
- [Architectural patterns worth internalizing](#architectural-patterns-worth-internalizing)
- [What to build next](#what-to-build-next)
- [Key resources: the complete reading list](#key-resources-the-complete-reading-list)

---

## The complete data flow

Before diving into walkthroughs, here is the full picture of how data moves through
Hush. Every arrow in this diagram corresponds to real code you have read in Parts 1–5.

```
┌─────────────────────────────────────────────────────────────────────────┐
│                        macOS / Core Audio HAL                           │
│                                                                         │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐  │
│  │ Process list     │  │ Default output   │  │ Process tap API      │  │
│  │ property         │  │ device property  │  │ (mute/unmute)        │  │
│  └────────┬─────────┘  └────────┬─────────┘  └──────────▲───────────┘  │
│           │ change              │ change                  │ create/     │
│           │ notification        │ notification            │ destroy     │
└───────────┼─────────────────────┼────────────────────────┼─────────────┘
            │                     │                        │
            ▼                     ▼                        │
┌───────────────────────┐  ┌─────────────────┐   ┌────────┴──────────┐
│ AudioProcessMonitor   │  │ Device change   │   │ AudioTapManager   │
│                       │  │ listener        │   │                   │
│ • HAL listener        │  │ (in ViewModel)  │   │ • mute()          │
│ • 2s poll timer       │  │ • Debounced     │   │ • unmute()        │
│ • enumerateProcesses()│  │   500ms         │   │ • teardownAll()   │
└───────────┬───────────┘  └────────┬────────┘   └────────▲──────────┘
            │                       │                      │
            │ onChange callback      │ handleDeviceChange() │ called by
            ▼                       ▼                      │
┌──────────────────────────────────────────────────────────────────────┐
│                    AppListViewModel (@Observable, @MainActor)        │
│                                                                      │
│  State (observed by views):          Actions (called by views):      │
│  ├── processes: [AudioProcess]       ├── toggleMute(for:)            │
│  ├── mutedProcessIDs: Set<String>    ├── unmuteAll()                 │
│  ├── error: HushError?              ├── toggleLaunchAtLogin()        │
│  └── launchAtLogin: Bool            └── teardown()                   │
│                                                                      │
│  Private:                                                            │
│  ├── mutedObjectIDs (for re-muting after device change)              │
│  ├── mutedProcessCache (for showing paused muted processes)          │
│  └── deviceChangeTask (debounce handle)                              │
└──────────────────────────────┬───────────────────────────────────────┘
                               │ @Observable properties
                               │ drive SwiftUI re-renders
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          SwiftUI Views                               │
│                                                                      │
│  HushApp                                                             │
│  └── MenuBarExtra (icon: speaker.slash.fill / speaker.wave.2.fill)   │
│      └── MenuContentView                                             │
│          ├── header ──── "Unmute All" button (if anyMuted)           │
│          ├── processList                                             │
│          │   └── ForEach: AudioProcessRow × N                        │
│          │       └── reads process + isMuted, calls onToggle         │
│          ├── errorBanner ── HushError.message + settings link        │
│          └── footer ──── Toggle "Launch at Login" + "Quit Hush"      │
└──────────────────────────────────────────────────────────────────────┘
```

Data flows **down** (system → ViewModel → Views). Actions flow **up** (Views →
ViewModel → system). This is the unidirectional data flow pattern from Part 0.

---

## Walkthrough 1: app launch

When the user opens Hush (or it starts automatically at login), this sequence executes:

```
   macOS                   HushApp              AppListViewModel         Core Audio
     │                       │                        │                      │
     │  launch binary        │                        │                      │
     ├──────────────────────►│                        │                      │
     │                       │  @State var viewModel  │                      │
     │                       │  = AppListViewModel()  │                      │
     │                       ├───────────────────────►│                      │
     │                       │                        │  init()              │
     │                       │                        │                      │
     │                       │                        │  1. Check SMAppService
     │                       │                        │     → set launchAtLogin
     │                       │                        │                      │
     │                       │                        │  2. enumerateProcesses()
     │                       │                        ├─────────────────────►│
     │                       │                        │◄─────────────────────┤
     │                       │                        │  → set processes     │
     │                       │                        │                      │
     │                       │                        │  3. register onChange │
     │                       │                        │  4. startListening() │
     │                       │                        ├─────────────────────►│
     │                       │                        │  (HAL listener +     │
     │                       │                        │   2s timer active)   │
     │                       │                        │                      │
     │                       │                        │  5. startDeviceListener()
     │                       │                        ├─────────────────────►│
     │                       │                        │                      │
     │                       │                        │  6. requestAudioTapPermission()
     │                       │                        ├─────────────────────►│
     │                       │                        │  (dummy tap → TCC    │
     │                       │                        │   prompt if needed)  │
     │                       │                        │◄─────────────────────┤
     │                       │                        │  (destroy dummy tap) │
     │                       │                        │                      │
     │  body evaluated       │◄───────────────────────┤                      │
     │                       │  MenuBarExtra created   │                      │
     │                       │  with speaker icon      │                      │
     │  menu bar icon        │                        │                      │
     │  appears              │                        │                      │
     ▼                       ▼                        ▼                      ▼
```

**Key files involved**:

| Step | File | What happens |
|---|---|---|
| App entry | `HushApp.swift` | `@main` triggers SwiftUI app lifecycle. `@State` creates the ViewModel. |
| ViewModel init | `AppListViewModel.swift:46-58` | Checks launch-at-login status, enumerates processes, starts listeners, requests permission. |
| Process enum | `AudioProcessMonitor.swift:34-107` | Queries HAL for all audio process objects, groups by bundle ID, resolves names and icons. |
| HAL listener | `AudioProcessMonitor.swift:119-135` | Registers for `kAudioHardwarePropertyProcessObjectList` changes on `.main` queue. |
| TCC prompt | `AppListViewModel.swift:62-71` | Creates and destroys a dummy tap to trigger the system permission dialog. |
| Icon render | `HushApp.swift:8` | `viewModel.anyMuted` is `false`, so the icon is `speaker.wave.2.fill`. |

**What the user sees**: A speaker icon appears in the menu bar. If this is the first
launch, macOS shows a "Screen & System Audio Recording" permission dialog.

---

## Walkthrough 2: the user mutes Spotify

The user clicks the menu bar icon, sees Spotify in the list, and clicks it.

```
   User          AudioProcessRow     MenuContentView    AppListViewModel    AudioTapManager    Core Audio
     │                 │                    │                  │                   │               │
     │  click row      │                    │                  │                   │               │
     ├────────────────►│                    │                  │                   │               │
     │                 │  onToggle()        │                  │                   │               │
     │                 ├───────────────────►│                  │                   │               │
     │                 │                    │  toggleMute(     │                   │               │
     │                 │                    │    for: spotify)  │                   │               │
     │                 │                    ├─────────────────►│                   │               │
     │                 │                    │                  │                   │               │
     │                 │                    │                  │  not in mutedIDs  │               │
     │                 │                    │                  │  → mute path      │               │
     │                 │                    │                  │                   │               │
     │                 │                    │                  │  tapManager.mute() │               │
     │                 │                    │                  ├──────────────────►│               │
     │                 │                    │                  │                   │  1. CATapDescription
     │                 │                    │                  │                   ├──────────────►│
     │                 │                    │                  │                   │  2. CreateProcessTap
     │                 │                    │                  │                   ├──────────────►│
     │                 │                    │                  │                   │  3. Get output UID
     │                 │                    │                  │                   ├──────────────►│
     │                 │                    │                  │                   │  4. Create aggregate
     │                 │                    │                  │                   ├──────────────►│
     │                 │                    │                  │                   │  5. Create IO proc
     │                 │                    │                  │                   ├──────────────►│
     │                 │                    │                  │                   │  6. Start device
     │                 │                    │                  │                   ├──────────────►│
     │                 │                    │                  │                   │◄──────────────┤
     │                 │                    │                  │◄──────────────────┤               │
     │                 │                    │                  │                   │               │
     │                 │                    │                  │  mutedProcessIDs  │               │
     │                 │                    │                  │    .insert(id)    │               │
     │                 │                    │                  │  mutedObjectIDs   │               │
     │                 │                    │                  │    [id] = objIDs  │               │
     │                 │                    │                  │  mutedProcessCache│               │
     │                 │                    │                  │    [id] = process │               │
     │                 │                    │                  │  error = nil      │               │
     │                 │                    │                  │                   │               │
     │                 │                    │    @Observable   │                   │               │
     │                 │                    │    triggers      │                   │               │
     │                 │                    │    re-render     │                   │               │
     │                 │                    │◄─────────────────┤                   │               │
     │                 │◄───────────────────┤                  │                   │               │
     │                 │  isMuted = true    │                  │                   │               │
     │                 │  icon → red slash  │                  │                   │               │
     │◄────────────────┤                   │                  │                   │               │
     │  Spotify is     │                   │                  │                   │               │
     │  silent, row    │                   │                  │                   │               │
     │  shows muted    │                   │                  │                   │               │
     ▼                 ▼                   ▼                  ▼                   ▼               ▼
```

**The state changes that trigger UI updates**:

1. `mutedProcessIDs.insert(spotify.id)` — `@Observable` notifies SwiftUI
2. SwiftUI re-evaluates views that read `mutedProcessIDs`:
   - `AudioProcessRow`: `isMuted` is now `true` → icon turns red, shows `speaker.slash.fill`
   - `MenuContentView.header`: `anyMuted` is now `true` → "Unmute All" button appears
   - `HushApp`: `anyMuted` is now `true` → menu bar icon changes to `speaker.slash.fill`

**What the user hears**: Spotify goes silent immediately. The audio tap intercepts
Spotify's output at the HAL level, before it reaches the speakers.

**What the user sees**: The row icon turns red, an "Unmute All" button appears in the
header, and the menu bar icon changes to a crossed-out speaker.

---

## Walkthrough 3: Spotify stops playing (but is still muted)

Spotify finishes a song and stops outputting audio. The 2-second poll timer fires.

```
   Timer       AudioProcessMonitor     AppListViewModel
     │                │                       │
     │  fire (2s)     │                       │
     ├───────────────►│                       │
     │                │  fireUpdate()         │
     │                │  enumerateProcesses() │
     │                │  → Spotify NOT in     │
     │                │    results (no output)│
     │                │                       │
     │                │  onChange(processes)   │
     │                ├──────────────────────►│
     │                │                       │
     │                │                       │  handleProcessUpdate()
     │                │                       │
     │                │                       │  1. Spotify in mutedProcessCache?
     │                │                       │     → YES
     │                │                       │  2. Spotify in activeProcesses?
     │                │                       │     → NO
     │                │                       │  3. kill(spotify_pid, 0) == 0?
     │                │                       │     → YES (process alive)
     │                │                       │
     │                │                       │  → Keep in list with
     │                │                       │    isRunningOutput = false
     │                │                       │
     │                │                       │  processes = merged + sorted
     │                │                       │
     │                │                       │  SwiftUI re-renders:
     │                │                       │  AudioProcessRow shows
     │                │                       │  "paused" label, name dimmed
     ▼                ▼                       ▼
```

**Key logic** (`AppListViewModel.swift:136-165`):

The `handleProcessUpdate` method performs a two-pass operation:

1. **First pass**: Find muted processes that have exited (`kill(pid, 0) != 0`). Clean
   up their taps.
2. **Second pass**: For muted processes still alive but not in the active list, add them
   back with `isRunningOutput = false`.

This is why `mutedProcessCache` exists — it preserves the process information (name,
icon, PID) even after Core Audio stops reporting it as active. Without the cache, a
muted app would vanish from the list the moment it paused playback.

**What the user sees**: Spotify's row dims slightly, and a "paused" label appears.
It is still muted — when Spotify plays the next song, it will remain silent.

---

## Walkthrough 4: the user plugs in headphones

The user connects AirPods. macOS fires multiple device change events in rapid succession.

```
   Core Audio         AppListViewModel              AudioTapManager
      │                      │                            │
      │  device change #1    │                            │
      ├─────────────────────►│                            │
      │                      │  handleDeviceChange()      │
      │                      │  cancel previous task      │
      │                      │  start Task: sleep 500ms   │
      │                      │                            │
      │  device change #2    │                            │
      │  (50ms later)        │                            │
      ├─────────────────────►│                            │
      │                      │  handleDeviceChange()      │
      │                      │  cancel task #1            │
      │                      │  start Task: sleep 500ms   │
      │                      │                            │
      │  device change #3    │                            │
      │  (80ms later)        │                            │
      ├─────────────────────►│                            │
      │                      │  handleDeviceChange()      │
      │                      │  cancel task #2            │
      │                      │  start Task: sleep 500ms   │
      │                      │                            │
      │    ... 500ms pass, no more changes ...            │
      │                      │                            │
      │                      │  Task #3 wakes up          │
      │                      │  Task.isCancelled? NO      │
      │                      │                            │
      │                      │  1. Save mutedObjectIDs    │
      │                      │  2. teardownAll()          │
      │                      ├───────────────────────────►│
      │                      │   (stop + destroy all      │
      │                      │    taps, agg devices,      │
      │                      │    IO procs)               │
      │                      │◄───────────────────────────┤
      │                      │                            │
      │                      │  3. Re-mute each process   │
      │                      │     with new output device  │
      │                      │                            │
      │                      │  for each saved process:   │
      │                      │    tapManager.mute()       │
      │                      ├───────────────────────────►│
      │                      │    (creates new tap with   │
      │                      │     AirPods as output)     │
      │                      │◄───────────────────────────┤
      │                      │                            │
      │                      │  4. Assign new state       │
      │                      │     atomically             │
      │                      │  mutedProcessIDs = newIDs  │
      │                      │  mutedObjectIDs = newObjIDs│
      │                      │                            │
      │                      │  SwiftUI re-renders        │
      │                      │  (no visible change —      │
      │                      │   same apps still muted)   │
      ▼                      ▼                            ▼
```

**Three patterns at work**:

1. **Debouncing** (Part 4): Task cancellation prevents redundant work. Only the last
   device change event within a 500ms window triggers the re-mute.

2. **Atomic state update** (Part 3): The new muted state is collected into local
   variables (`newMutedIDs`, `newObjectIDs`), then assigned to `@Observable` properties
   in one batch. This prevents a UI flicker where rows would briefly show as unmuted.

3. **Resource cleanup tower** (Part 5): `teardownAll()` destroys all existing taps,
   aggregate devices, and IO procs before creating new ones with the updated output
   device UID.

**What the user hears**: A brief moment of audio (during the 500ms debounce + re-mute),
then silence again. The previously muted apps remain muted through the AirPods.

**What the user sees**: Nothing changes in the UI. The muted apps stay muted.

---

## Walkthrough 5: the user quits Hush

The user clicks "Quit Hush" in the footer.

```
   User       MenuContentView      AppListViewModel    AudioProcessMonitor    AudioTapManager
     │              │                     │                    │                     │
     │  click       │                     │                    │                     │
     │  "Quit Hush" │                     │                    │                     │
     ├─────────────►│                     │                    │                     │
     │              │  teardown()         │                    │                     │
     │              ├────────────────────►│                    │                     │
     │              │                     │                    │                     │
     │              │                     │  unmuteAll()       │                     │
     │              │                     │  ├─ teardownAll() ─┼────────────────────►│
     │              │                     │  │                 │   destroy all taps  │
     │              │                     │  │                 │   and agg devices   │
     │              │                     │  │                 │◄────────────────────┤
     │              │                     │  ├─ clear mutedProcessIDs               │
     │              │                     │  ├─ clear mutedObjectIDs                │
     │              │                     │  └─ clear mutedProcessCache             │
     │              │                     │                    │                     │
     │              │                     │  stopListening()   │                     │
     │              │                     ├───────────────────►│                     │
     │              │                     │  (invalidate timer,│                     │
     │              │                     │   remove HAL       │                     │
     │              │                     │   listener)        │                     │
     │              │                     │◄───────────────────┤                     │
     │              │                     │                    │                     │
     │              │                     │  stopDeviceListener()                    │
     │              │                     │  (remove device    │                     │
     │              │                     │   change listener) │                     │
     │              │                     │                    │                     │
     │              │◄────────────────────┤                    │                     │
     │              │                     │                    │                     │
     │              │  NSApplication      │                    │                     │
     │              │  .terminate(nil)    │                    │                     │
     │              │                     │                    │                     │
     │  all audio   │                    │                    │                     │
     │  restored,   │                    │                    │                     │
     │  app exits   │                    │                    │                     │
     ▼              ▼                    ▼                    ▼                     ▼
```

**Key point**: Hush unmutes everything before quitting. If the app crashed or was force-
killed, macOS would also destroy the process taps (they are tied to the process lifetime),
so previously muted apps would regain audio automatically.

---

## Architectural patterns worth internalizing

After tracing five complete interactions, several patterns emerge that apply to *any*
macOS or iOS application:

### 1. The ViewModel is the funnel

Every external event — user click, HAL notification, timer tick — funnels through the
ViewModel. No view mutates state directly. No system callback updates the UI directly.
The ViewModel is the single chokepoint where all state transitions happen.

```
   HAL listener ──┐
   Timer tick ─────┤
   Device change ──┼──► AppListViewModel ──► SwiftUI
   User click ─────┤        (single owner       (pure render
   App launch ─────┘         of all state)        from state)
```

> **Rust parallel**: This is the actor model. The ViewModel is an actor with a single
> mailbox. All events are messages. The actor processes them sequentially on the main
> thread. There are no data races because there is only one writer.

### 2. Separate "what happened" from "what to show"

The ViewModel translates between two worlds:

| System world (what happened) | UI world (what to show) |
|---|---|
| `AudioObjectID` array from HAL | `[AudioProcess]` with names and icons |
| `OSStatus` error code | `HushError.permissionDenied` with a human message |
| Process tap created successfully | `mutedProcessIDs` set updated |
| `kill(pid, 0) != 0` | Process removed from list |

The View never sees `AudioObjectID`, `OSStatus`, or raw PIDs. It sees processes, errors,
and booleans. This separation is why the View code is so short — it does not need to
understand Core Audio.

### 3. Cache what the system forgets

Core Audio reports only processes that are *currently* outputting audio. Spotify between
songs has no output — it vanishes from the HAL. But the user muted it, and they expect
it to stay visible and stay muted.

The `mutedProcessCache` bridges this gap. It remembers what the HAL forgets, and uses
`kill(pid, 0)` as a heartbeat check to detect actual process exit.

This pattern — **caching state that an external system does not persist** — appears in
many applications:

- A chat app caching message read status that the server only stores temporarily
- A file browser caching directory contents between filesystem scans
- A network monitor caching connection state between SNMP polls

### 4. Debounce system events, batch UI updates

System events arrive at unpredictable rates. Device changes fire 3–5 times when AirPods
connect. Process list changes fire for every subprocess that starts or stops.

Hush handles this in two ways:

- **Debounce at the source**: The device change handler uses `Task` cancellation to
  collapse multiple rapid events into one action.
- **Batch at the sink**: The device change handler collects new state into local
  variables, then assigns to `@Observable` properties once. This prevents SwiftUI from
  rendering intermediate (incorrect) states.

### 5. Clean up resources in reverse order

Core Audio resources form a dependency chain:

```
Process Tap → Aggregate Device → IO Proc → Running Device
```

Creation goes left to right. Destruction must go right to left. If you destroy the
aggregate device before stopping the IO proc, the behavior is undefined.

This pattern appears whenever you work with C APIs that allocate and deallocate
resources manually (which is common on Apple platforms — Core Audio, Core Graphics,
Security framework, and IOKit all follow this pattern).

> **Rust parallel**: Rust's `Drop` trait handles this automatically — fields are
> dropped in reverse declaration order. In Swift interop with C APIs, you must manage
> this manually, as Hush does in `AudioTapManager.teardown()`.

---

## What to build next

You now have a complete understanding of a working macOS application. Here are
progressively more ambitious projects that build on what you have learned:

### Level 1: Modify Hush

- **Add per-app volume control**: Instead of muting (binary), add a slider that
  adjusts the tap's volume. This requires changing `CATapDescription.muteBehavior` and
  adding a volume property to the UI.
- **Add a global keyboard shortcut**: Use `CGEvent` taps or the `KeyboardShortcuts`
  Swift package to toggle mute for the focused app.
- **Persist mute state**: Save which apps are muted to `UserDefaults` and restore them
  on launch.

### Level 2: Build a new menu bar app

- **System monitor**: Show CPU, memory, and network usage in the menu bar. Uses
  `host_statistics`, `IOKit`, and `SystemConfiguration` frameworks. Same architecture:
  a polling monitor, a ViewModel, a `MenuBarExtra`.
- **Clipboard manager**: Watch `NSPasteboard` for changes, store history, show in a
  menu bar popup. Introduces `NSPasteboard` observation and local storage.

### Level 3: Build a windowed app

- **A full SwiftUI app with navigation**: `NavigationSplitView`, `NavigationStack`,
  multiple ViewModels, and `@Environment` for dependency injection. This is where
  you will encounter the more complex patterns discussed in Part 0 (TCA, coordinators).

---

## Key resources: the complete reading list

### Apple documentation

| Topic | Link | When to read |
|---|---|---|
| SwiftUI overview | [developer.apple.com/xcode/swiftui](https://developer.apple.com/xcode/swiftui/) | Starting point for all SwiftUI work |
| Managing Model Data | [developer.apple.com/documentation/swiftui/managing-model-data-in-your-app](https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app) | Before building your first ViewModel |
| Observation framework | [developer.apple.com/documentation/observation](https://developer.apple.com/documentation/observation) | When using `@Observable` |
| App lifecycle | [developer.apple.com/documentation/swiftui/app](https://developer.apple.com/documentation/swiftui/app) | When structuring your App struct |
| MenuBarExtra | [developer.apple.com/documentation/swiftui/menubarextra](https://developer.apple.com/documentation/swiftui/menubarextra) | When building menu bar apps |
| Core Audio | [developer.apple.com/documentation/coreaudio](https://developer.apple.com/documentation/coreaudio) | When working with audio |
| Hardened Runtime | [developer.apple.com/documentation/security/hardened-runtime](https://developer.apple.com/documentation/security/hardened-runtime) | Before distributing your app |

### WWDC sessions (in recommended viewing order)

1. **[Platforms State of the Union 2023](https://developer.apple.com/videos/play/wwdc2023/102/)** — Big picture of modern Apple development
2. **[Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/)** — `@Observable` explained
3. **[Data Essentials in SwiftUI](https://developer.apple.com/videos/play/wwdc2020/10040/)** — Foundation of state management
4. **[Demystify SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10022/)** — How SwiftUI decides what to re-render
5. **[Meet async/await in Swift](https://developer.apple.com/videos/play/wwdc2021/10132/)** — Swift concurrency fundamentals
6. **[Eliminate data races using Swift Concurrency](https://developer.apple.com/videos/play/wwdc2022/110351/)** — `Sendable`, actors, `@MainActor`

### Books

- **[The Swift Programming Language](https://docs.swift.org/swift-book/)** — The official language reference. Free. Start with "A Swift Tour."
- **[Hacking with Swift: 100 Days of SwiftUI](https://www.hackingwithswift.com/100/swiftui)** — Build a new small app each day. The best way to build muscle memory.
- **[Swift by Sundell](https://www.swiftbysundell.com/)** — Deep dives into Swift patterns and best practices.

### For Rust developers

- **[Yew](https://yew.rs/)** — Rust WebAssembly framework using the Elm Architecture. Closest to SwiftUI's model.
- **[Iced](https://iced.rs/)** — Rust native GUI with Elm Architecture. The Rust app most similar to a SwiftUI app.
- **[Ratatui](https://ratatui.rs/)** — Terminal UI framework. Same `UI = f(state)` model, different rendering target.

---

## Summary

You have now traced five complete user interactions through every layer of Hush:

1. **Launch**: ViewModel initializes, enumerates processes, starts listeners, triggers TCC prompt
2. **Mute**: User click → ViewModel → AudioTapManager → Core Audio. State update triggers SwiftUI re-render.
3. **Pause**: Timer detects missing process, cache keeps it visible, `kill()` confirms it is alive
4. **Device change**: Debounced with Task cancellation, taps destroyed and re-created, state updated atomically
5. **Quit**: All taps destroyed, listeners removed, app terminates cleanly

The architecture follows MVVM with three clear boundaries:

- **Views** know about state and user actions. They do not know about Core Audio.
- **ViewModel** knows about state, business logic, and system services. It does not know about layout or colors.
- **System services** know about Core Audio, HAL objects, and process taps. They do not know about the UI.

Each boundary makes the code easier to understand, test, and modify. A change to the
UI does not require touching Core Audio code. A change to the muting mechanism does not
require touching the Views.

This is the payoff of the architectural thinking from Part 0 — applied to ~800 lines
of working code.
