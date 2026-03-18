# Part 2 — How macOS Applications Work

When you run `cargo build --release` in Rust, you get a single binary. You can copy it to
another machine with the same OS and run it. There is no packaging, no manifest, no signing.
The binary *is* the program.

macOS does not work that way. A macOS application is a **bundle** — a directory with a specific
internal structure that the operating system reads before it ever executes your binary. This
part covers everything that happens *around* your code: the bundle, the manifest, entitlements,
code signing, the launch sequence, and the build system that produces all of it.

Understanding this infrastructure is essential. Without it, you will find yourself confused by
build errors, permission dialogs, and distribution requirements that have no equivalent in the
Rust ecosystem.

---

## Table of contents

- [What is an app bundle?](#what-is-an-app-bundle)
- [Info.plist: the application manifest](#infoplist-the-application-manifest)
- [The TCC system: privacy at the OS level](#the-tcc-system-privacy-at-the-os-level)
- [Entitlements: capability declarations](#entitlements-capability-declarations)
- [Code signing: why and how](#code-signing-why-and-how)
- [The app lifecycle](#the-app-lifecycle)
- [Menu bar apps (LSUIElement)](#menu-bar-apps-lsuielement)
- [XcodeGen and project.yml](#xcodegen-and-projectyml)
- [The build system: Xcode vs cargo](#the-build-system-xcode-vs-cargo)
- [Logging: os.Logger](#logging-oslogger)
- [Key resources](#key-resources)

---

## What is an app bundle?

On macOS, an application is not a single file. It is a directory with the extension `.app`.
Finder *displays* it as a single icon, but underneath it is a folder tree with a required
layout. Right-click any app in `/Applications` and choose "Show Package Contents" to see
this yourself.

Here is what `Hush.app` looks like inside:

```
Hush.app/
└── Contents/
    ├── Info.plist              ← application manifest (metadata)
    ├── MacOS/
    │   └── Hush               ← the actual compiled binary
    ├── Resources/
    │   └── AppIcon.icns        ← app icon and other assets
    ├── _CodeSignature/
    │   └── CodeResources       ← cryptographic hashes of every file
    └── PkgInfo                 ← legacy type marker ("APPL????")
```

**The binary lives at `Contents/MacOS/Hush`.** Everything else is metadata, resources, and
integrity verification data. The operating system reads `Contents/Info.plist` *before* it
launches the binary — it needs to know what the app requires, what permissions it declares,
and whether the code signature is valid.

### Why bundles exist

Bundles solve several problems that a bare binary cannot:

1. **Metadata before execution.** The OS knows your app's identifier, version, minimum OS
   requirement, and privacy descriptions without running a single line of your code.

2. **Resource co-location.** Icons, localizations, asset catalogs, and data files live
   alongside the binary in a predictable structure. Your code loads them by asking the
   framework for "the resource named X in my bundle" rather than hardcoding file paths.

3. **Integrity verification.** The `_CodeSignature` directory contains SHA-256 hashes of
   every file in the bundle. If anything is modified after signing — the binary, a resource,
   even the Info.plist — the OS refuses to launch the app.

4. **Drag-and-drop installation.** Because the bundle is self-contained, users install apps
   by dragging the `.app` to `/Applications`. No installer scripts, no package managers, no
   system-wide side effects.

> **Rust comparison**: `cargo build` produces `target/release/my_binary`. That is the entire
> deliverable. If you want an icon, a manifest, or co-located resources, you handle that
> yourself (or use a tool like `cargo-bundle`). On macOS, the build system produces the
> entire bundle structure for you.

---

## Info.plist: the application manifest

The `Info.plist` file is an XML property list that describes your application to the
operating system. It is the macOS equivalent of `Cargo.toml`'s `[package]` section — but
the OS itself reads it, not a build tool.

Here is Hush's `Info.plist` in full (`Hush/Resources/Info.plist`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Hush</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.2</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Bastian. All rights reserved.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Hush needs audio access to mute and unmute individual apps.</string>
</dict>
</plist>
```

Note the `$(EXECUTABLE_NAME)` and `$(PRODUCT_BUNDLE_IDENTIFIER)` values — these are Xcode
build variables that get substituted at compile time. The final `Info.plist` inside the
built `.app` bundle contains the resolved values.

### Every key explained

| Key | Value in Hush | Purpose |
|-----|---------------|---------|
| `CFBundleDevelopmentRegion` | `en` | Default language for localized resources. |
| `CFBundleExecutable` | `$(EXECUTABLE_NAME)` | Name of the binary in `Contents/MacOS/`. Resolved to `Hush` at build time. |
| `CFBundleIdentifier` | `$(PRODUCT_BUNDLE_IDENTIFIER)` | Reverse-DNS unique identifier: `com.bastian.Hush`. This is how macOS distinguishes your app from every other app on the system. |
| `CFBundleInfoDictionaryVersion` | `6.0` | Info.plist format version. Always `6.0`. |
| `CFBundleName` | `Hush` | The display name shown in Activity Monitor and elsewhere. |
| `CFBundlePackageType` | `APPL` | Bundle type. `APPL` = application. Others include `FMWK` (framework) and `BNDL` (generic bundle). |
| `CFBundleShortVersionString` | `1.0` | The user-facing version string (like `version` in `Cargo.toml`). |
| `CFBundleVersion` | `1` | The build number. Incremented with every build. Used by the App Store to distinguish builds of the same version. |
| `LSMinimumSystemVersion` | `14.2` | Minimum macOS version. The OS refuses to launch the app on anything older. Like setting `rust-version` in `Cargo.toml`. |
| `LSUIElement` | `true` | **Makes this a menu-bar-only app.** No Dock icon, no app menu bar. Covered in detail in the [Menu bar apps](#menu-bar-apps-lsuielement) section. |
| `NSHumanReadableCopyright` | `Copyright 2026 Bastian...` | Shown in the "Get Info" panel in Finder. |
| `NSAudioCaptureUsageDescription` | `Hush needs audio access...` | The string shown in the TCC permission dialog. Required for any app that accesses audio capture. |

### The bundle identifier

The `CFBundleIdentifier` deserves special attention. It is the **globally unique identity**
of your application. macOS uses it for:

- Storing per-app preferences (`~/Library/Preferences/com.bastian.Hush.plist`)
- Granting per-app permissions in the TCC database
- Identifying the app in the `ServiceManagement` framework (launch at login)
- Keychain access groups
- Push notification routing

The convention is reverse-DNS: `com.yourcompany.AppName`. Think of it as a crate name on
crates.io, but enforced at the OS level rather than a package registry.

### What is *not* in Hush's Info.plist

You will see two keys in many SwiftUI app tutorials that Hush does not have:

- **`NSPrincipalClass`** — In AppKit (pre-SwiftUI) apps, this specifies the application's
  main class (typically `NSApplication`). SwiftUI apps using `@main` do not need this; the
  `@main` attribute handles the entry point.

- **`NSMainStoryboardFile`** — Specifies a storyboard to load at launch. Storyboards are an
  Interface Builder concept from the AppKit/UIKit era. SwiftUI apps define their UI in code,
  so there is no storyboard.

> **Rust comparison**: `Cargo.toml` has `[package]` metadata (name, version, edition) plus
> `[[bin]]` to specify entry points. `Info.plist` serves the same role, but it is read by
> the operating system at launch time, not by a build tool at compile time. The OS makes
> real decisions based on this file — refusing to launch on an older OS version, presenting
> permission dialogs, hiding the Dock icon.

---

## The TCC system: privacy at the OS level

The `NSAudioCaptureUsageDescription` key in Hush's Info.plist exists because of **TCC** —
Transparency, Consent, and Control. TCC is macOS's privacy framework. Any app that accesses
a protected resource — camera, microphone, screen recording, location, contacts, audio
capture — must:

1. **Declare a usage description string** in its Info.plist (the `NS...UsageDescription` keys)
2. **Trigger a system permission prompt** when it first accesses the resource
3. **Receive explicit user consent** before the OS grants access

If you ship an app without the required usage description string and try to access a protected
API, the app crashes. Not at runtime with an error you can catch — the OS terminates the
process before your code even executes the protected call.

```
┌──────────────────────────────────────────────────────────────────┐
│                        TCC Flow                                    │
│                                                                    │
│  1. App calls protected API (e.g., create an audio process tap)   │
│                          │                                         │
│                          ▼                                         │
│  2. OS checks TCC database: has user already granted access?      │
│                          │                                         │
│              ┌───────────┴───────────┐                             │
│              ▼                       ▼                              │
│         Yes: proceed            No: show dialog                    │
│                                      │                              │
│                                      ▼                              │
│                              ┌──────────────┐                      │
│                              │ "Hush needs  │                      │
│                              │ audio access │                      │
│                              │ to mute and  │ ◄─ string from       │
│                              │ unmute       │    Info.plist         │
│                              │ individual   │                      │
│                              │ apps."       │                      │
│                              │              │                      │
│                              │ [Don't Allow]│                      │
│                              │ [OK]         │                      │
│                              └──────────────┘                      │
│                                      │                              │
│                          ┌───────────┴───────────┐                 │
│                          ▼                       ▼                  │
│                     Granted                   Denied                │
│                   (stored in DB)           (stored in DB)           │
│                                                                    │
│  The decision persists. The user changes it in System Settings     │
│  > Privacy & Security, not in your app.                            │
└──────────────────────────────────────────────────────────────────┘
```

Hush uses audio process taps, which fall under the "Screen & System Audio Recording"
category in System Settings. That is why `AppListViewModel.requestAudioTapPermission()` creates
and immediately destroys a dummy tap at launch — it triggers the TCC prompt early, so the user
is not surprised by it later when they try to mute something.

There is no equivalent to TCC in the Rust ecosystem. On Linux, you run a binary and it has
whatever access your user account has. On macOS, even if you are an admin user, the OS
interposes on specific API calls and requires per-app, per-resource consent. This is a
fundamental difference in the platform's security model.

---

## Entitlements: capability declarations

Entitlements are key-value pairs embedded in your app's code signature that declare what
capabilities your app needs. Think of them as capability flags — a static declaration of
"this app may use network sockets" or "this app may access the user's Downloads folder."

Here is Hush's entitlements file (`Hush/Resources/Hush.entitlements`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict/>
</plist>
```

It is empty. No entitlements are declared. This is worth understanding — *why* is it empty?

### Why Hush's entitlements are empty

Entitlements primarily matter when the **App Sandbox** is enabled. The App Sandbox is a
macOS security feature that restricts what your app can do: no network access unless you
declare it, no file access outside your container unless you declare it, no access to user
folders unless you declare it. Each exception requires an entitlement.

Hush has App Sandbox **disabled** (`ENABLE_APP_SANDBOX: false` in `project.yml`). Here is why:

- Hush uses Core Audio's Hardware Abstraction Layer (HAL) to create process audio taps. These
  are low-level system operations that the App Sandbox does not permit, even with entitlements.
- Audio taps require interacting with system-wide audio objects that belong to other processes.
  The sandbox is designed to prevent exactly this kind of cross-process interaction.

Without the sandbox enabled, the entitlements file has nothing to declare. The app runs with
the full permissions of the user account (subject to TCC, which is separate from sandboxing).

### Common entitlements you will encounter

| Entitlement | What it grants |
|-------------|----------------|
| `com.apple.security.app-sandbox` | Enables the App Sandbox (required for Mac App Store) |
| `com.apple.security.network.client` | Outbound network connections (sandbox) |
| `com.apple.security.network.server` | Inbound network connections (sandbox) |
| `com.apple.security.files.downloads.read-write` | Access to `~/Downloads` (sandbox) |
| `com.apple.security.files.user-selected.read-write` | Access to files the user picks in an open/save dialog (sandbox) |
| `com.apple.security.device.audio-input` | Microphone access (sandbox) |
| `com.apple.security.device.camera` | Camera access (sandbox) |

### Hardened runtime vs App Sandbox

Hush has App Sandbox disabled but **hardened runtime enabled** (`ENABLE_HARDENED_RUNTIME: true`
in `project.yml`). These are different security mechanisms:

```
┌─────────────────────────────────────────────────────────────────┐
│              App Sandbox vs Hardened Runtime                       │
│                                                                   │
│  ┌──────────────────────────┐  ┌──────────────────────────────┐  │
│  │      App Sandbox          │  │      Hardened Runtime         │  │
│  │                           │  │                               │  │
│  │  Restricts what your app  │  │  Protects your app's own     │  │
│  │  can ACCESS:              │  │  INTEGRITY:                   │  │
│  │  - filesystem             │  │  - no code injection          │  │
│  │  - network                │  │  - no unsigned libraries      │  │
│  │  - hardware devices       │  │  - no debugging by other      │  │
│  │  - other processes        │  │    processes                  │  │
│  │                           │  │  - no DYLD environment        │  │
│  │  Required for Mac App     │  │    variable overrides         │  │
│  │  Store distribution.      │  │                               │  │
│  │                           │  │  Required for notarization.   │  │
│  └──────────────────────────┘  └──────────────────────────────┘  │
│                                                                   │
│  Hush: Sandbox OFF              Hush: Hardened Runtime ON         │
│  (needs raw Core Audio access)  (required for distribution)       │
└─────────────────────────────────────────────────────────────────┘
```

The hardened runtime prevents other software from tampering with your app at runtime. It
blocks techniques like dynamic library injection (`DYLD_INSERT_LIBRARIES`), code modification,
and debugging by unsigned processes. It is required for **notarization** (Apple's server-side
check for distributed apps).

> **Rust/Linux comparison**: Entitlements are conceptually similar to Linux capabilities
> (`CAP_NET_BIND_SERVICE`, `CAP_SYS_PTRACE`, etc.) or Android manifest permissions. They
> declare at build time what the binary is *allowed* to do. The difference is that on macOS,
> they are embedded in the code signature, not set on the file post-install.

---

## Code signing: why and how

Every macOS application must be **code signed**. The code signature is a cryptographic
guarantee that the binary has not been modified since the developer built it. macOS checks
the signature before launching any app.

### Signing levels

There are three levels of code signing, with increasing trust:

| Level | Identity | Used for | What it proves |
|-------|----------|----------|----------------|
| **Ad-hoc** | `-` (dash) | Local development | The binary has not been tampered with since it was built *on this machine*. No developer identity attached. |
| **Developer ID** | `Developer ID Application: Your Name (TEAM_ID)` | Distribution outside the App Store | The binary was built by a specific, identified Apple developer. |
| **Apple Distribution** | `Apple Distribution: Your Name (TEAM_ID)` | Mac App Store | The binary was built by an identified developer and is distributed through Apple's store. |

Hush uses **ad-hoc signing** for local development. This is set in `project.yml`:

```yaml
settings:
  base:
    CODE_SIGN_IDENTITY: "-"
```

The dash (`-`) means "sign the binary with an ad-hoc identity." This is sufficient for
running the app on your own machine during development. The OS verifies the signature is
internally consistent (no files tampered with) but does not verify a developer identity.

For distribution, you would change this to a Developer ID certificate and submit the app
for notarization. Hush's `project.yml` includes a comment showing this path:

```yaml
configs:
  Release:
    # For notarized distribution, change CODE_SIGN_IDENTITY to your Developer ID:
    # CODE_SIGN_IDENTITY: "Developer ID Application"
    # DEVELOPMENT_TEAM: "YOUR_TEAM_ID"
```

### Notarization

Notarization is an additional step for apps distributed outside the Mac App Store. You submit
your signed app to Apple's servers, which scan it for malware, verify the code signature, and
check that the hardened runtime is enabled. If it passes, Apple issues a "ticket" that macOS
checks when the user first launches the app.

Without notarization, macOS Gatekeeper shows a warning dialog that frightens users: "this app
cannot be verified." With notarization, the app launches without complaint.

```
Build ──► Sign (Developer ID) ──► Submit to Apple ──► Apple scans ──► Ticket issued
                                                                           │
                                                                           ▼
                                                         Embed ticket in app
                                                         (or Apple hosts it)
                                                                           │
                                                                           ▼
                                                         User launches app
                                                         ──► macOS checks ticket
                                                         ──► App launches normally
```

> **Rust comparison**: There is no code signing in the Rust ecosystem. When you run
> `cargo build --release`, the resulting binary is unsigned. Anyone can modify it, and the
> OS will run it without question (on Linux). macOS imposes a chain of trust: the developer
> signs the binary, Apple verifies the signature, and the OS checks the verification before
> launching. This is a platform requirement, not a language feature.

---

## The app lifecycle

When you double-click Hush (or it launches at login via `SMAppService`), here is what
happens:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Hush Launch Sequence                            │
│                                                                   │
│  1. OS reads Contents/Info.plist                                  │
│     ├── Checks LSMinimumSystemVersion (14.2)                     │
│     ├── Reads CFBundleIdentifier (com.bastian.Hush)              │
│     └── Reads LSUIElement (true → no Dock icon)                  │
│                          │                                        │
│  2. OS verifies code signature                                    │
│     ├── Checks _CodeSignature/CodeResources                      │
│     ├── Validates entitlements                                    │
│     └── Checks Gatekeeper / notarization ticket                  │
│                          │                                        │
│  3. OS loads Contents/MacOS/Hush into memory                      │
│     ├── Maps binary segments                                      │
│     ├── Resolves dyld (dynamic linker) dependencies               │
│     └── Links CoreAudio.framework, SwiftUI, etc.                  │
│                          │                                        │
│  4. Swift runtime finds @main entry point (HushApp)               │
│     └── Calls the generated static main() function                │
│                          │                                        │
│  5. SwiftUI creates the App instance                              │
│     ├── Evaluates HushApp.body                                    │
│     ├── Creates MenuBarExtra with system image                    │
│     └── Initializes @State property (AppListViewModel)            │
│                          │                                        │
│  6. The run loop starts                                           │
│     ├── Listens for user interactions (menu bar click)            │
│     ├── Listens for system events (audio device changes)          │
│     └── Waits...                                                  │
│                          │                                        │
│  App is now running. The Hush icon appears in the menu bar.      │
└─────────────────────────────────────────────────────────────────┘
```

### Step 4 in detail: the `@main` attribute

In Rust, every program starts at `fn main()`. In Swift, the `@main` attribute designates
the entry point. Here is Hush's `HushApp.swift`:

```swift
import SwiftUI

@main
struct HushApp: App {
    @State private var viewModel = AppListViewModel()

    var body: some Scene {
        MenuBarExtra("Hush",
                     systemImage: viewModel.anyMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill") {
            MenuContentView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
    }
}
```

The `@main` attribute is a macro that generates a static `main()` function — the actual
C-level entry point. It calls into SwiftUI's application bootstrap code, which creates your
`App` struct, evaluates its `body`, and starts the run loop.

This is analogous to Rust's `#[tokio::main]`:

```rust
// Rust: #[tokio::main] generates fn main() { Runtime::new().block_on(async_main()) }
// Swift: @main generates static func main() { /* SwiftUI bootstrap */ }
```

Both are macros that hide the framework setup. Both turn your "entry point" into a callback
that the framework invokes after it has set up its infrastructure (event loop / run loop).

### The run loop

Once the SwiftUI bootstrap is complete, the **run loop** takes over. This is the macOS
equivalent of Tokio's event loop (covered in Part 0). It waits for events — mouse clicks,
keyboard input, timer firings, system notifications — and dispatches them to the appropriate
handlers.

You never interact with the run loop directly in a SwiftUI app. It is managed by the framework.
But its existence explains why:

- UI updates must happen on the **main thread** (the run loop runs on the main thread)
- The `@MainActor` annotation on `AppListViewModel` ensures its methods are called on the
  main thread
- Long-running work (like audio device enumeration) is dispatched with `Task` to avoid
  blocking the run loop

---

## Menu bar apps (LSUIElement)

Hush is a **menu bar app** — it has no main window, no Dock icon, and no application menu bar.
The only visible UI element is the speaker icon in the macOS menu bar.

### What `LSUIElement = true` does

Setting `LSUIElement` to `true` in Info.plist tells macOS that this is an **agent application**.
The effects:

1. **No Dock icon.** The app does not appear in the Dock.
2. **No application menu bar.** There is no "Hush" menu with File, Edit, Window, Help.
3. **No "Cmd+Tab" entry.** The app does not show in the application switcher.
4. **The app still runs.** It is a normal process — it shows in Activity Monitor and responds
   to system events. It communicates with the user through the menu bar.

This is the standard pattern for utility apps that do their work in the background: clipboard
managers, VPN clients, display tools, and audio controllers like Hush.

### MenuBarExtra: SwiftUI's menu bar API

Before macOS 13 Ventura (2022), creating a menu bar app required AppKit code —
`NSStatusBar`, `NSStatusItem`, `NSPopover`, and manual view hosting. SwiftUI's `MenuBarExtra`
replaces all of that with a declarative API.

Let's walk through every part of `HushApp.swift`:

```swift
@main
struct HushApp: App {
```

`HushApp` conforms to the `App` protocol. This is SwiftUI's top-level entry point — it defines
the *scenes* that make up the application. A scene is a container for content that the system
manages: a window, a document group, or (in Hush's case) a menu bar item.

```swift
    @State private var viewModel = AppListViewModel()
```

`@State` tells SwiftUI to own the lifecycle of this value. The `AppListViewModel` instance is
created once when the app launches and persists for the entire lifetime of the application.
SwiftUI ensures that when any `@Observable` property on the ViewModel changes, the views that
read those properties are re-evaluated.

```swift
    var body: some Scene {
```

The `body` property returns the app's scene graph. For most apps, this contains a
`WindowGroup` (a standard window). For menu bar apps, it contains a `MenuBarExtra`.

```swift
        MenuBarExtra("Hush",
                     systemImage: viewModel.anyMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill") {
```

`MenuBarExtra` creates a menu bar item. The parameters:

- `"Hush"` — an accessibility label (read by VoiceOver screen readers).
- `systemImage:` — the icon displayed in the menu bar. This is an **SF Symbol** name.

**SF Symbols** are Apple's icon system — over 5,000 vector icons that ship with the OS.
`speaker.wave.2.fill` shows a speaker with sound waves; `speaker.slash.fill` shows a speaker
with a line through it. The icon changes reactively: when `viewModel.anyMuted` changes (because
the user muted an app), SwiftUI re-evaluates this expression and swaps the icon.

```swift
            MenuContentView(viewModel: viewModel)
        }
```

The trailing closure provides the **content** that appears when the user clicks the menu bar
icon. This is where the `MenuContentView` lives — the list of audio processes, the mute
toggles, the footer.

```swift
        .menuBarExtraStyle(.window)
```

This modifier determines *how* the content appears:

- `.window` — The content appears in a popover-style floating panel attached to the menu bar
  icon. This is what Hush uses. It allows complex SwiftUI views with scroll views, buttons,
  and custom layouts.
- `.menu` — The content appears as a standard system menu (like the Wi-Fi or Bluetooth menu).
  Limited to `Button`, `Toggle`, `Divider`, and `Text` — no custom views.

Hush uses `.window` because its content includes a scrollable list with app icons, toggle
states, and hover effects — none of which work in a standard menu.

---

## XcodeGen and project.yml

Xcode stores project configuration in `.xcodeproj` bundles — opaque directories containing
XML files with UUIDs, build settings, and file references. These files are:

- Difficult to review in version control (diffs are walls of UUIDs)
- Prone to merge conflicts (team members adding files simultaneously)
- Verbose (hundreds of lines for a small project)

**XcodeGen** is an open-source tool that generates `.xcodeproj` files from a human-readable
YAML specification. Hush uses it. The `project.yml` file is the single source of truth for
the project configuration, and the `.xcodeproj` is a generated artifact.

> **Rust comparison**: `project.yml` serves the same role as `Cargo.toml`. It defines the
> project name, targets, dependencies, build settings, and source paths. The difference is
> that `Cargo.toml` is read directly by the compiler toolchain, while `project.yml` is read
> by XcodeGen to *generate* the Xcode project, which Xcode then reads.

### Walking through Hush's project.yml

Here is the full file (`project.yml`), annotated:

```yaml
name: Hush                           # Project name (like [package] name in Cargo.toml)
options:
  bundleIdPrefix: com.bastian        # Default prefix for bundle identifiers
  deploymentTarget:
    macOS: "14.2"                    # Minimum macOS version (like rust-version)
  xcodeVersion: "16.0"              # Expected Xcode version
  minimumXcodeGenVersion: "2.38.0"  # Minimum XcodeGen version required to parse this file
```

The `options` block sets project-wide defaults. The deployment target (`14.2`) means the app
requires macOS 14.2 Sonoma or later — this is enforced by the OS at launch time via
`LSMinimumSystemVersion` in Info.plist.

```yaml
targets:
  Hush:
    type: application                # This target produces a .app bundle
    platform: macOS                  # Not iOS, not watchOS — macOS
    sources:
      - path: Hush                   # Include everything under Hush/
        excludes:
          - "Resources/Assets.xcassets"   # ...except the asset catalog
      - path: Hush/Resources/Assets.xcassets
        buildPhase: resources        # Asset catalog goes into Resources build phase
```

The `sources` section tells XcodeGen which files to include. Note the two-step include: the
`Hush` directory is included (Swift source files, Info.plist, entitlements), but
`Assets.xcassets` is excluded from the default build phase and re-added as a resource. This is
because asset catalogs need special processing — the Xcode build system compiles them into
an optimized binary format (`.car` file), not a direct file copy.

In Cargo terms, this is like having both `src/` for code and a `build.rs` step for processing
non-code assets.

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.bastian.Hush
        INFOPLIST_FILE: Hush/Resources/Info.plist
        GENERATE_INFOPLIST_FILE: false       # Use our hand-written Info.plist
        SWIFT_VERSION: "5.10"
        MACOSX_DEPLOYMENT_TARGET: "14.2"
        ENABLE_APP_SANDBOX: false            # No sandbox (Core Audio needs raw access)
        ENABLE_HARDENED_RUNTIME: true        # Required for notarization
        CODE_SIGN_ENTITLEMENTS: Hush/Resources/Hush.entitlements
        CODE_SIGN_IDENTITY: "-"              # Ad-hoc signing for development
        PRODUCT_NAME: Hush
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon   # Which icon set to use
```

The `settings.base` block defines build settings that apply to all configurations (Debug and
Release). Key points:

- `GENERATE_INFOPLIST_FILE: false` — By default, Xcode can auto-generate an Info.plist from
  build settings. Hush provides its own because it needs custom keys like `LSUIElement` and
  `NSAudioCaptureUsageDescription`.
- `CODE_SIGN_IDENTITY: "-"` — Ad-hoc signing. See the [Code signing](#code-signing-why-and-how)
  section.
- `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` — Tells the asset catalog compiler which
  icon set to use as the app icon.

```yaml
      configs:
        Release:
          SWIFT_OPTIMIZATION_LEVEL: "-O"     # Optimize for speed in release builds
```

The `configs` block overrides settings per build configuration. Hush sets Swift optimization
level `-O` (equivalent to Rust's `--release` flag) for release builds. Debug builds use the
default (no optimization), which preserves debug symbols and speeds up compilation — the same
tradeoff as `cargo build` vs `cargo build --release`.

```yaml
    dependencies:
      - sdk: CoreAudio.framework             # System framework dependency
```

The `dependencies` section lists frameworks the app links against. `CoreAudio.framework` is a
**system framework** — it ships with macOS and provides the Hardware Abstraction Layer (HAL)
that Hush uses to create audio taps. This is not downloaded from a package registry; it is
part of the OS.

In Rust terms, this is like linking against a system library with `#[link(name = "coreaudio")]`
in a `build.rs` script, or specifying it in `Cargo.toml` with a `-sys` crate.

### Regenerating the Xcode project

After modifying `project.yml`, regenerate the Xcode project:

```bash
xcodegen generate
```

This reads `project.yml` and writes `Hush.xcodeproj/`. The `.xcodeproj` is listed in
`.gitignore` in many XcodeGen projects, since it is a generated artifact. Hush includes it
in the repository for convenience (so you can open the project without installing XcodeGen
first), but the source of truth is `project.yml`.

### Building from the command line

You do not need to open Xcode to build. The `xcodebuild` command-line tool does the same work:

```bash
# Debug build
xcodebuild -scheme Hush build

# Release build
xcodebuild -scheme Hush -configuration Release build

# See where the built .app ends up
xcodebuild -scheme Hush -showBuildSettings | grep BUILT_PRODUCTS_DIR
```

---

## The build system: Xcode vs cargo

Here is a side-by-side comparison of the two build systems:

| Concept | Rust / Cargo | Swift / Xcode |
|---------|-------------|---------------|
| **Project manifest** | `Cargo.toml` | `project.yml` (XcodeGen) or `.xcodeproj` |
| **Build command** | `cargo build` | `xcodebuild -scheme Hush build` |
| **Build output** | `target/debug/my_binary` | `DerivedData/.../Build/Products/Debug/Hush.app` |
| **Release build** | `cargo build --release` | `xcodebuild -configuration Release build` |
| **Dependency manager** | Cargo (crates.io) | Swift Package Manager (SPM) |
| **System libraries** | `-sys` crates + `build.rs` | `- sdk: CoreAudio.framework` |
| **Intermediate artifacts** | `target/` directory | `DerivedData/` directory |
| **Compilation unit** | Crate (a module tree) | Module (a target) |
| **Conditional compilation** | `#[cfg(feature = "...")]` | `#if DEBUG` / `#if os(macOS)` |

### Swift Package Manager (SPM)

SPM is Swift's built-in dependency manager — the equivalent of Cargo. It uses a `Package.swift`
manifest file (similar to `Cargo.toml`) and resolves dependencies from Git repositories.

Hush uses **no SPM dependencies**. Its only external dependency is `CoreAudio.framework`, which
is a system framework that ships with macOS. This is like a Rust project that uses `libc`
functions through FFI but has no crates.io dependencies.

When you do use SPM in a project, dependencies appear in a `Package.resolved` file (like
`Cargo.lock`) and are fetched from Git URLs rather than a central registry. The Swift package
ecosystem is smaller and more fragmented than crates.io — there is no single registry.
Packages are hosted on GitHub and referenced by URL.

### Debug vs Release builds

The concept maps directly from Rust:

- **Debug builds** compile quickly, include debug symbols, skip optimizations. Use these
  during development. In Rust: `cargo build`. In Xcode: the default configuration.

- **Release builds** enable optimizations (`-O` in Swift, similar to `-C opt-level=3` in
  Rust), strip debug information, and produce smaller, faster binaries. In Rust:
  `cargo build --release`. In Xcode: `-configuration Release`.

Hush sets `SWIFT_OPTIMIZATION_LEVEL: "-O"` for release builds in `project.yml`. The Swift
compiler supports three optimization levels:

| Flag | Equivalent in Rust | Effect |
|------|--------------------|--------|
| `-Onone` | `opt-level = 0` | No optimization (debug default) |
| `-O` | `opt-level = 2` or `3` | Optimize for speed |
| `-Osize` | `opt-level = "s"` | Optimize for binary size |

---

## Logging: os.Logger

Hush uses Apple's unified logging system throughout its codebase. This is the macOS equivalent
of Rust's `tracing` or `log` crate — a structured logging framework where logs are routed to
the system log, not to stdout/stderr.

### How Hush creates loggers

Each file creates a module-level logger with a **subsystem** and **category**:

```swift
// In AppListViewModel.swift:
private let logger = Logger(subsystem: "com.bastian.Hush", category: "ViewModel")

// In CoreAudioHelpers.swift:
private let logger = Logger(subsystem: "com.bastian.Hush", category: "CoreAudio")

// In AudioProcessMonitor.swift:
private let logger = Logger(subsystem: "com.bastian.Hush", category: "ProcessMonitor")

// In AudioTapManager.swift:
private let logger = Logger(subsystem: "com.bastian.Hush", category: "AudioTap")
```

The **subsystem** is the app's bundle identifier. The **category** is a free-form string that
groups related log messages. This is similar to how `tracing` uses targets and spans, or how
the `log` crate uses module paths.

### Using the logger

Hush logs at two levels — `info` and `error`:

```swift
// Informational: something expected happened
logger.info("Created tap \(tapID) for \(processID)")
logger.info("Output device changed, recreating \(self.mutedProcessIDs.count) tap(s)")

// Error: something went wrong
logger.error("Mute failed for \(process.name): \(err.localizedDescription)")
logger.error("Launch at login failed: \(error.localizedDescription)")
```

The logging API uses **string interpolation**, but this is not standard Swift string
interpolation. The `os.Logger` overloads the interpolation mechanism to format values lazily
and redact sensitive data. The string is not constructed in memory unless the log level is
active — similar to how `tracing::info!()` in Rust avoids formatting cost when the level
is disabled.

Available log levels, from lowest to highest severity:

| Swift (`os.Logger`) | Rust (`tracing`) equivalent | Behavior |
|----------------------|-----------------------------|----------|
| `.debug` | `tracing::debug!` | Not persisted to disk by default. Visible in Console.app when streaming. |
| `.info` | `tracing::info!` | Persisted to disk. Visible in Console.app. |
| `.notice` (default) | `tracing::info!` | Persisted. The default level if you use `logger.log()`. |
| `.error` | `tracing::error!` | Always persisted. Highlighted in Console.app. |
| `.fault` | `tracing::error!` | Indicates a bug. Captures a stack trace. Always persisted. |

### Viewing logs

You do not see `os.Logger` output in Xcode's console by default (unlike `print()` statements).
To view logs:

**Console.app** (GUI):
1. Open `/Applications/Utilities/Console.app`
2. Select your Mac in the sidebar
3. Click "Start Streaming"
4. Filter by subsystem: type `com.bastian.Hush` in the search bar

**Command line** (`log` CLI tool):
```bash
# Stream all Hush logs in real time
log stream --predicate 'subsystem == "com.bastian.Hush"'

# Filter by category
log stream --predicate 'subsystem == "com.bastian.Hush" AND category == "AudioTap"'

# Show recent stored logs
log show --predicate 'subsystem == "com.bastian.Hush"' --last 1h
```

> **Rust comparison**: `os.Logger` maps to Rust's `tracing` crate in several ways:
>
> | Rust (`tracing`) | Swift (`os.Logger`) |
> |------------------|---------------------|
> | `tracing::info!("message")` | `logger.info("message")` |
> | `tracing::error!("failed: {}", err)` | `logger.error("failed: \(err)")` |
> | `#[instrument]` for spans | No direct equivalent — use signposts (`os_signpost`) |
> | `tracing_subscriber::fmt()` | Built into the OS (Console.app, `log` CLI) |
> | Compile-time level filtering | Runtime level filtering by the OS |
>
> The key difference: in Rust, you choose a subscriber (formatter, JSON output, file output).
> In macOS, the OS *is* the subscriber. All `os.Logger` output goes to the unified log system,
> and you read it with system tools. There is no equivalent of configuring output format or
> destination in your app.

---

## Key resources

### Apple documentation

- **[Bundle Programming Guide](https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/Introduction/Introduction.html)** — Comprehensive guide to the bundle structure, Info.plist keys, and resource loading. Covers the directory layout in detail.

- **[Information Property List (Info.plist) Reference](https://developer.apple.com/documentation/bundleresources/information_property_list)** — Complete reference for every Info.plist key. Bookmark this — you will look up keys here frequently.

- **[Entitlements](https://developer.apple.com/documentation/bundleresources/entitlements)** — Reference for all entitlement keys, organized by capability.

- **[Hardened Runtime](https://developer.apple.com/documentation/security/hardened-runtime)** — Explains what the hardened runtime protects against and which entitlements can selectively relax its restrictions.

- **[Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/Introduction/Introduction.html)** — How code signing works, what it verifies, and how to troubleshoot signing issues.

- **[MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)** — SwiftUI documentation for the menu bar API that Hush uses. Covers both `.window` and `.menu` styles.

- **[os.Logger](https://developer.apple.com/documentation/os/logger)** — API reference for the unified logging system. Includes guidance on choosing log levels and formatting.

### Tools

- **[XcodeGen (GitHub)](https://github.com/yonaskolb/XcodeGen)** — The tool Hush uses to generate its Xcode project from `project.yml`. The README includes the full YAML specification.

### WWDC sessions

| Session | Year | Relevance |
|---------|------|-----------|
| **[What's new in privacy](https://developer.apple.com/videos/play/wwdc2023/10053/)** | 2023 | Covers TCC changes, new privacy APIs, and usage description requirements. |
| **[Explore logging in Swift](https://developer.apple.com/videos/play/wwdc2020/10168/)** | 2020 | Deep dive into `os.Logger`, log levels, formatting, and performance characteristics. |
| **[All about notarization](https://developer.apple.com/videos/play/wwdc2019/703/)** | 2019 | Explains the notarization workflow, hardened runtime requirements, and common issues. |

---

## Summary

A macOS application is more than a compiled binary. To build and distribute one, you need to
understand the infrastructure that surrounds your code:

1. **App bundles** package your binary with metadata, resources, and a code signature in a
   standard directory layout that the OS reads before launching your code.

2. **Info.plist** is your application manifest. The OS reads it to determine your app's
   identity, version, minimum OS requirement, privacy descriptions, and behavior (like
   whether to show a Dock icon).

3. **TCC** requires you to declare why your app needs access to protected resources and
   presents a consent dialog to the user. No description string, no access.

4. **Entitlements** declare your app's capabilities at build time, embedded in the code
   signature. They matter most when the App Sandbox is enabled.

5. **Code signing** provides a cryptographic chain of trust from developer to user. Ad-hoc
   signing works for development; Developer ID signing and notarization are required for
   distribution.

6. **The launch sequence** goes: read manifest, verify signature, load binary, find `@main`,
   create the `App`, evaluate scenes, start the run loop.

7. **Menu bar apps** use `LSUIElement = true` and `MenuBarExtra` to live in the menu bar
   without a Dock icon or main window.

8. **XcodeGen** lets you define your project in human-readable YAML instead of Xcode's
   opaque project format. The `project.yml` is the `Cargo.toml` equivalent.

9. **`os.Logger`** routes structured log messages to the system's unified logging
   infrastructure, viewable with Console.app or the `log` CLI tool.

With this understanding of the platform infrastructure, you are ready for the next parts —
where you will see how Swift's language features and SwiftUI's view system work together to
build the UI that lives inside this bundle.
