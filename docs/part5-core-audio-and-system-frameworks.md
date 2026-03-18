# Part 5 — Core Audio and System Frameworks

This is the most technically demanding part of the guide. Core Audio is macOS's low-level
audio framework — a C API that predates Swift by over twenty years. If you have written
FFI bindings in Rust, calling C libraries through `extern "C"` blocks and wrangling raw
pointers, you already have the right mental model. Core Audio programming in Swift is
the same dance: allocate buffers, call C functions, check error codes, interpret raw
bytes, and clean up manually.

Hush uses Core Audio's Hardware Abstraction Layer (HAL) to enumerate which apps are
producing audio, then uses the process tap API (introduced in macOS 14.2) to mute
individual apps at the system level. This part walks through every line of code that
makes that work.

---

## Table of contents

- [Core Audio overview: what it is and why it matters](#core-audio-overview-what-it-is-and-why-it-matters)
- [The HAL object model: AudioObjectID and properties](#the-hal-object-model-audioobjectid-and-properties)
- [Unsafe pointer dance: reading properties](#unsafe-pointer-dance-reading-properties)
  - [Reading a single value: propertyData](#reading-a-single-value-propertydata)
  - [Reading an array: propertyArray](#reading-an-array-propertyarray)
  - [Reading a string: stringProperty and Unmanaged](#reading-a-string-stringproperty-and-unmanaged)
  - [Swift-to-Rust unsafe operation mapping](#swift-to-rust-unsafe-operation-mapping)
- [Error handling in Core Audio](#error-handling-in-core-audio)
- [Process enumeration: AudioProcessMonitor](#process-enumeration-audioprocessmonitor)
  - [enumerateProcesses step by step](#enumerateprocesses-step-by-step)
  - [Data flow: from HAL objects to AudioProcess](#data-flow-from-hal-objects-to-audioprocess)
- [HAL property listeners: getting notified of changes](#hal-property-listeners-getting-notified-of-changes)
- [Process taps: the muting mechanism](#process-taps-the-muting-mechanism)
  - [The mute function step by step](#the-mute-function-step-by-step)
  - [The cleanup tower](#the-cleanup-tower)
  - [The complete audio muting pipeline](#the-complete-audio-muting-pipeline)
- [Teardown: orderly resource cleanup](#teardown-orderly-resource-cleanup)
- [TCC permissions: the system permission prompt](#tcc-permissions-the-system-permission-prompt)
- [Device change handling](#device-change-handling)
- [Key resources](#key-resources)

---

## Core Audio overview: what it is and why it matters

Core Audio is Apple's low-level audio framework. It has been the foundation of all audio
on macOS since Mac OS X 10.0 (2001). Every sound your Mac produces — from a FaceTime
call to a Spotify track to a system notification — passes through Core Audio. It occupies
roughly the same role that ALSA and PipeWire fill on Linux.

Here is where Core Audio sits in the stack:

```
┌─────────────────────────────────────────────────────────┐
│                    Applications                          │
│  (Spotify, Chrome, FaceTime, Hush)                      │
├─────────────────────────────────────────────────────────┤
│              High-level frameworks                        │
│  (AVFoundation, AVFAudio, AudioToolbox)                  │
├─────────────────────────────────────────────────────────┤
│         Core Audio Hardware Abstraction Layer             │
│  (AudioHardware.h — the C API Hush uses directly)        │
├─────────────────────────────────────────────────────────┤
│                   Audio drivers                           │
│  (CoreAudio.kext, vendor drivers)                        │
├─────────────────────────────────────────────────────────┤
│                    Hardware                               │
│  (Built-in speakers, AirPods, USB DAC)                   │
└─────────────────────────────────────────────────────────┘
```

A few things to know up front:

**It is a C API.** Core Audio was written in C (with some C++ internals). Swift calls it
through the same bridging mechanism it uses for all C headers — the functions appear as
global Swift functions, the constants appear as global Swift constants, and the structs
map to Swift structs. There is no Swift wrapper. There is no "Swifty" API. You are writing
C-style code with Swift syntax.

**There is no Rust crate equivalent.** In Rust, you would use [`cpal`](https://github.com/RustAudio/cpal)
for cross-platform audio I/O, or raw ALSA bindings (`alsa-rs`) for Linux-specific work.
Core Audio's HAL is closer to the raw ALSA approach — you talk to kernel objects through
handles and ioctl-like property queries.

**It is sparsely documented.** Apple's official documentation for Core Audio is thin.
The real documentation lives in the C header files themselves (`AudioHardware.h`,
`AudioHardwareBase.h`), which contain extensive comments. Many behaviors — especially
around process taps and aggregate devices — are learned from WWDC sample code and
experimentation.

> **Rust parallel**: If you have wrapped a C library using `bindgen` and then written
> safe Rust wrappers around the raw FFI bindings, you understand the experience of working
> with Core Audio in Swift. The C functions are available, the types are bridged, but there
> is no safety net. You manage memory, check error codes, and interpret raw bytes yourself.

---

## The HAL object model: AudioObjectID and properties

Everything in Core Audio's HAL is an **audio object** identified by an `AudioObjectID`,
which is a `UInt32`. Think of it as a file descriptor — an opaque handle that the kernel
uses to look up the actual resource. You never construct the object itself; you receive a
numeric ID and use it to query properties.

Audio objects form a tree:

```
System Object (kAudioObjectSystemObject = 1)
├── Device: "Built-in Output" (ID: 58)
│   ├── property: kAudioDevicePropertyDeviceUID → "BuiltInSpeakerDevice"
│   ├── property: kAudioDevicePropertyNominalSampleRate → 48000.0
│   └── Stream 1 (ID: 59)
│       └── property: kAudioStreamPropertyPhysicalFormat → ...
├── Device: "AirPods Pro" (ID: 73)
│   └── ...
├── Process: Spotify (ID: 102)
│   ├── property: kAudioProcessPropertyPID → 1234
│   ├── property: kAudioProcessPropertyBundleID → "com.spotify.client"
│   └── property: kAudioProcessPropertyIsRunningOutput → 1
├── Process: Chrome (ID: 103)
│   ├── property: kAudioProcessPropertyPID → 5678
│   ├── property: kAudioProcessPropertyBundleID → "com.google.Chrome"
│   └── property: kAudioProcessPropertyIsRunningOutput → 1
└── Process: Finder (ID: 104)
    ├── property: kAudioProcessPropertyPID → 321
    └── property: kAudioProcessPropertyIsRunningOutput → 0
```

To read a property, you construct an `AudioObjectPropertyAddress` with three fields:

```swift
AudioObjectPropertyAddress(
    mSelector: kAudioProcessPropertyPID,          // WHAT property
    mScope:    kAudioObjectPropertyScopeGlobal,   // WHICH direction (global/input/output)
    mElement:  kAudioObjectPropertyElementMain     // WHICH channel (main = all)
)
```

**`mSelector`** identifies *what* property you want. It is a `UInt32` constant — Apple
defines hundreds of them in `AudioHardwareBase.h`. The ones Hush uses:

| Selector | Returns | Purpose |
|---|---|---|
| `kAudioHardwarePropertyProcessObjectList` | `[AudioObjectID]` | All registered audio process objects |
| `kAudioHardwarePropertyDefaultOutputDevice` | `AudioObjectID` | Currently active output device |
| `kAudioProcessPropertyPID` | `pid_t` | Unix process ID |
| `kAudioProcessPropertyBundleID` | `CFString` | App bundle identifier |
| `kAudioProcessPropertyIsRunningOutput` | `UInt32` | Whether the process is currently outputting audio |
| `kAudioDevicePropertyDeviceUID` | `CFString` | Unique string identifier for a device |

**`mScope`** controls directionality. Most properties Hush uses are
`kAudioObjectPropertyScopeGlobal` because they apply regardless of input/output direction.
For device-specific queries, you would use `kAudioObjectPropertyScopeOutput` or
`kAudioObjectPropertyScopeInput`.

**`mElement`** selects a channel. `kAudioObjectPropertyElementMain` (which is `0`) means
"the whole object" — you almost always use this unless you are working with individual
channels of a multi-channel device.

> **Rust parallel**: This is structurally identical to reading sysfs on Linux. Instead
> of reading `/sys/class/sound/card0/pcm0p/sub0/status`, you query object 58 at address
> `(kAudioDevicePropertyDeviceUID, Global, Main)`. The addressing scheme is different,
> but the pattern is the same: ask the kernel for a specific property of a specific
> object by constructing an address.

---

## Unsafe pointer dance: reading properties

The core of Hush's interaction with Core Audio lives in `CoreAudioHelpers.swift`. This
file contains three functions that wrap the C API's property-reading pattern into
reusable Swift. Every one of them involves manual memory allocation, pointer manipulation,
and type reinterpretation — the same operations you would mark `unsafe` in Rust.

The file lives at `Hush/Audio/CoreAudioHelpers.swift`.

### Reading a single value: propertyData

Here is the function, annotated line by line:

```swift
static func propertyData<T>(from objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> T {
    var address = address
    var size: UInt32 = 0
```

The function is generic over `T` — the caller specifies what type they expect the
property to contain. The `address` parameter is copied into a `var` because the C
functions take it as an `inout` pointer (`&address`), and Swift requires `var` for that.

```swift
    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }
```

**Step 1: Ask how big the data is.** `AudioObjectGetPropertyDataSize` writes the byte
count into `size`. This is the same pattern as calling a C function once with a null
buffer to get the required size — you see this in Win32's `GetWindowText`, OpenGL's
`glGetShaderInfoLog`, and ALSA's `snd_pcm_hw_params_get_buffer_size`. The `0, nil`
arguments are for "qualifier data" — extra parameters some properties need. Most do not.

In Rust, this would be:

```rust
let mut size: u32 = 0;
let status = unsafe {
    AudioObjectGetPropertyDataSize(object_id, &address, 0, ptr::null(), &mut size)
};
if status != NO_ERR { return Err(CoreAudioError::OsStatus(status)); }
```

```swift
    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { data.deallocate() }
```

**Step 2: Allocate a buffer.** `UnsafeMutableRawPointer.allocate` is Swift's equivalent
of `alloc::alloc::alloc` in Rust — a raw heap allocation with a specified size and
alignment. You get back an untyped pointer (`*mut u8` in Rust terms).

The `defer` block guarantees that `data.deallocate()` runs when the function exits,
*regardless of how it exits* — normal return, thrown error, or early guard exit. This
is Swift's version of RAII. In Rust, you would achieve this with a `Drop` implementation
on a wrapper type, or by using `Box::from_raw` to hand ownership to a `Box` that
deallocates when it goes out of scope.

```swift
    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, data)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }
```

**Step 3: Read the property data into the buffer.** The C function writes raw bytes into
your buffer. The `size` parameter is both input (how much space you have) and output
(how many bytes were written). If the call fails, the `guard` throws, and `defer`
deallocates the buffer.

```swift
    return data.load(as: T.self)
}
```

**Step 4: Reinterpret the bytes as type T.** `data.load(as: T.self)` reads the first
`MemoryLayout<T>.size` bytes from the buffer and interprets them as a value of type `T`.
This is a *type-punning* operation — it trusts you that the bytes actually represent a
valid `T`. There is no runtime check.

In Rust, the equivalent is:

```rust
unsafe { ptr::read::<T>(data as *const T) }
```

Or, if you prefer the more explicit version:

```rust
unsafe { std::mem::transmute_copy::<[u8; N], T>(&buffer) }
```

Both operations are `unsafe` in Rust because the compiler cannot verify that the bytes
form a valid `T`. In Swift, `UnsafeMutableRawPointer.load(as:)` carries the same risk
but does not require an `unsafe` keyword — Swift trusts you at compile time. The danger
is identical.

### Reading an array: propertyArray

```swift
static func propertyArray<T>(from objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> [T] {
    var address = address
    var size: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }
```

Same opening: query the data size. For array properties (like the list of all audio
process objects), the returned size is `count * MemoryLayout<T>.stride`.

```swift
    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }
```

Compute the element count. `MemoryLayout<T>.stride` is the distance in bytes between
consecutive elements — this accounts for alignment padding, unlike `.size` which is the
bare storage size. In Rust, this is `std::mem::size_of::<T>()` (which already includes
padding for array layout). If no elements exist, return early — no need to allocate.

```swift
    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { data.deallocate() }

    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, data)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }
```

Same allocate-read-or-throw pattern as `propertyData`.

```swift
    let buffer = data.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}
```

**`bindMemory(to:capacity:)`** tells the Swift runtime that this region of memory
contains `count` values of type `T`. It returns a typed pointer (`UnsafeMutablePointer<T>`).
In Rust, this is analogous to:

```rust
let slice = unsafe { std::slice::from_raw_parts(data as *const T, count) };
```

**`UnsafeBufferPointer`** wraps a typed pointer and a count into something that conforms
to `Collection` — you can iterate it, pass it to `Array()`, use it with `map` and `filter`.
It is like Rust's `&[T]` — a fat pointer with a start address and a length.

**`Array(...)`** copies the elements into a safe, heap-allocated Swift array. After this
line, the `defer` block frees the raw buffer, and the returned `Array` owns its own copy
of the data. You are back in safe territory.

### Reading a string: stringProperty and Unmanaged

String properties require special handling because Core Audio returns Core Foundation
`CFString` objects — reference-counted objects managed by a C runtime, not by Swift's ARC.

```swift
static func stringProperty(from objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String {
    var address = address
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
```

Instead of asking for the size, this function *knows* the size: it is the size of a
pointer to a `CFString` (8 bytes on 64-bit). The property returns a `CFString` reference,
not a byte buffer.

**`Unmanaged<CFString>`** is Swift's escape hatch for dealing with objects whose reference
count is not managed by Swift's ARC (Automatic Reference Counting). In Rust terms,
imagine you receive a raw pointer to an `Arc<String>` from C code. You need to decide:
did the C function increment the reference count for you (you own it), or did it hand you
a borrowed reference (you do not own it)?

```swift
    let ptr = UnsafeMutablePointer<Unmanaged<CFString>>.allocate(capacity: 1)
    defer { ptr.deallocate() }
```

Allocate space for one `Unmanaged<CFString>` — that is, space for one pointer. The `defer`
cleans up the allocation.

```swift
    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }
```

Read the property. Core Audio writes a `CFString` reference into `ptr`.

```swift
    // AudioObjectGetPropertyData follows the "Get Rule" — caller does NOT own the reference
    return ptr.pointee.takeUnretainedValue() as String
}
```

**The Get Rule** is a Core Foundation memory management convention:

- **"Get Rule"**: The function name contains "Get". The caller receives a borrowed
  reference. You must *not* release it. Use `takeUnretainedValue()`.
- **"Create/Copy Rule"**: The function name contains "Create" or "Copy". The caller
  owns the reference. You must release it when done. Use `takeRetainedValue()`.

`takeUnretainedValue()` tells Swift: "Give me the `CFString` value, but do not decrement
the reference count when I am done with it — I do not own this reference." If you
mistakenly used `takeRetainedValue()` here, you would over-release the string and
potentially crash.

In Rust terms, this is the difference between `Arc::from_raw` (takes ownership, will
call `Drop`) and constructing a `&T` from a raw pointer (borrows, does not call `Drop`).
Getting this wrong in either language leads to use-after-free or double-free.

The final `as String` bridges the `CFString` to a Swift `String`. This is a
zero-cost toll-free bridge — `CFString` and `NSString` and `String` share the same
underlying representation on Apple platforms.

### Swift-to-Rust unsafe operation mapping

Here is a complete reference table mapping every unsafe operation in `CoreAudioHelpers.swift`
to its Rust equivalent:

| Swift | Rust | What it does |
|---|---|---|
| `UnsafeMutableRawPointer.allocate(byteCount:alignment:)` | `alloc::alloc::alloc(Layout::from_size_align(size, align))` | Heap-allocate raw bytes |
| `data.deallocate()` | `alloc::alloc::dealloc(ptr, layout)` | Free raw heap allocation |
| `defer { data.deallocate() }` | `impl Drop for Guard` or `scopeguard::defer!` | Guarantee cleanup on scope exit |
| `MemoryLayout<T>.alignment` | `std::mem::align_of::<T>()` | Minimum alignment of type T |
| `MemoryLayout<T>.stride` | `std::mem::size_of::<T>()` | Stride between array elements |
| `MemoryLayout<T>.size` | N/A (Rust's `size_of` includes padding) | Size without trailing padding |
| `data.load(as: T.self)` | `ptr::read::<T>(data as *const T)` | Read bytes as type T |
| `data.bindMemory(to: T.self, capacity: n)` | `std::slice::from_raw_parts(data as *const T, n)` | Interpret raw memory as typed array |
| `UnsafeBufferPointer(start:count:)` | `&[T]` (fat pointer) | Pointer + length pair |
| `Unmanaged<T>.takeUnretainedValue()` | Borrowing from a raw `Arc` pointer | Get value without taking ownership |
| `Unmanaged<T>.takeRetainedValue()` | `Arc::from_raw(ptr)` | Get value and take ownership |

---

## Error handling in Core Audio

Every Core Audio C function returns an `OSStatus` — a 32-bit signed integer where `0`
(`noErr`) means success and any other value indicates an error. This is identical to
how C functions return `errno` values, or how Rust FFI wrappers check return codes from
`libc` functions.

Hush wraps this in a structured error type at the top of `CoreAudioHelpers.swift`:

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
```

Three variants:

- **`.osStatus(OSStatus)`** — wraps a raw status code from any Core Audio C function
- **`.propertyNotFound`** — a domain-specific error when a property query returns nothing
- **`.ioProcCreationFailed`** — when `AudioDeviceCreateIOProcIDWithBlock` returns nil
  despite reporting `noErr` (a defensive case)

The `errorDescription` property is required by `LocalizedError` — it provides the
human-readable string that `.localizedDescription` returns. For `.osStatus`, it checks
a known codes dictionary first:

```swift
    private static let knownCodes: [OSStatus: String] = [
        560947818: "Bad audio object",         // '!obj'
        1970171760: "Not running",             // 'stop'
        1970170480: "Unsupported operation",   // 'unop'
        1852797029: "Illegal operation",       // 'nope'
    ]
```

Those large integer values are **FourCC codes** — four ASCII characters packed into a
32-bit integer. This is a convention from classic Mac OS that Core Audio inherits. The
integer `560947818` is the bytes `'!' 'o' 'b' 'j'` interpreted as a big-endian `UInt32`.
If you have worked with video container formats (AVI, MP4), you have seen FourCC codes
before.

In Rust, you would define these as `const` values:

```rust
const BAD_OBJECT: i32 = i32::from_be_bytes(*b"!obj");   // 560947818
const NOT_RUNNING: i32 = i32::from_be_bytes(*b"stop");  // 1970171760
```

The **permission detection** is critical for the user experience:

```swift
    var isPermissionError: Bool {
        guard case .osStatus(let code) = self else { return false }
        // TCC / permission denial codes observed with process taps
        return code == -66753 || code == -66748
    }
```

These two codes are returned when the app attempts to create a process tap but the user
has not granted (or has revoked) the "Screen & System Audio Recording" permission. The
codes are not documented in any public header — they were identified by testing. Hush
uses this check to show a specific error message directing the user to System Settings,
rather than a generic "mute failed" error.

> **Rust parallel**: This is the same pattern you see in Rust FFI wrappers:
> ```rust
> fn check(status: OSStatus) -> Result<(), CoreAudioError> {
>     match status {
>         0 => Ok(()),
>         code => Err(CoreAudioError::OsStatus(code)),
>     }
> }
> ```
> Every C call gets wrapped in `check(...)`. The difference from Rust's `Result` is that
> Swift uses `throw` — but the control flow is identical. You either get the value or
> you propagate the error.

---

## Process enumeration: AudioProcessMonitor

`AudioProcessMonitor` (`Hush/Audio/AudioProcessMonitor.swift`) is responsible for
answering one question: *which applications are currently producing audio?* It queries
the HAL, transforms the results into `[AudioProcess]`, and notifies the ViewModel
whenever the list changes.

### enumerateProcesses step by step

```swift
func enumerateProcesses() -> [AudioProcess] {
    let objectIDs: [AudioObjectID]
    do {
        objectIDs = try CoreAudioHelper.propertyArray(
            from: AudioObjectID(kAudioObjectSystemObject),
            address: processListAddress
        )
    } catch {
        logger.error("Failed to enumerate audio processes: \(error.localizedDescription)")
        return []
    }
```

**Query all audio process objects.** The `processListAddress` property stores:

```swift
private var processListAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyProcessObjectList,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
```

This asks the system object for its list of audio process IDs. Core Audio returns every
process that has registered with the audio system — even those that are not currently
playing audio. If the query fails (which would mean something is fundamentally wrong
with Core Audio), the function logs and returns an empty array.

```swift
    struct Info {
        var objectIDs: [AudioObjectID]
        var pid: pid_t
        var bundleID: String?
        var name: String
        var icon: NSImage?
        var isRunningOutput: Bool
    }

    var grouped: [String: Info] = [:]
```

**Define a local grouping structure.** A single application (like Chrome) can have
*multiple* audio objects — one for each tab or extension producing audio. Hush needs to
present Chrome as a single row with all its object IDs collected together. The `Info`
struct accumulates data as the code iterates through the raw HAL objects. The `grouped`
dictionary uses the bundle ID (or a PID-based fallback key) for grouping.

```swift
    for oid in objectIDs {
        let pidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard let pid: pid_t = try? CoreAudioHelper.propertyData(from: oid, address: pidAddr) else { continue }
```

**For each object, query its PID.** `kAudioProcessPropertyPID` returns the Unix process
ID. If this query fails, the object is skipped — something is wrong with that particular
HAL object, but it should not prevent processing the rest.

```swift
        let runAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let isRunning: UInt32 = (try? CoreAudioHelper.propertyData(from: oid, address: runAddr)) ?? 0
```

**Query whether the process is outputting audio.** `kAudioProcessPropertyIsRunningOutput`
returns a `UInt32` boolean (0 or 1). If the query fails, it defaults to `0` (not running).
This property is what lets Hush show only apps that are actively producing sound, rather
than every app that has ever opened an audio context.

```swift
        let bidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let bundleID = try? CoreAudioHelper.stringProperty(from: oid, address: bidAddr)

        // Skip our own process
        if bundleID == Self.ownBundleID { continue }
```

**Query the bundle ID and skip ourselves.** If Hush appeared in its own list, the user
could mute Hush itself, which would be confusing. `Self.ownBundleID` is a static property
that reads `Bundle.main.bundleIdentifier` once.

```swift
        let key = bundleID ?? "pid:\(pid)"

        if var existing = grouped[key] {
            existing.objectIDs.append(oid)
            existing.isRunningOutput = existing.isRunningOutput || (isRunning != 0)
            grouped[key] = existing
        } else {
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName
                ?? bundleID?.components(separatedBy: ".").last
                ?? "PID \(pid)"
            grouped[key] = Info(
                objectIDs: [oid],
                pid: pid,
                bundleID: bundleID,
                name: name,
                icon: app?.icon,
                isRunningOutput: isRunning != 0
            )
        }
    }
```

**Group objects by application.** If a bundle ID already exists in the dictionary,
append this object ID and OR the running status (if *any* of Chrome's audio objects are
producing output, Chrome counts as running). If it is a new entry, look up the
`NSRunningApplication` to get the display name and icon. The name falls back through three
levels: localized app name, last component of the bundle ID, or bare PID.

Note the `if var existing` pattern — this copies the `Info` struct out of the dictionary,
mutates the copy, and writes it back. Structs in Swift are value types (like Rust structs
without `&mut`), so you cannot mutate them in-place through a dictionary subscript.

```swift
    return grouped
        .filter { $0.value.isRunningOutput }
        .map { key, info in
            AudioProcess(
                id: key,
                objectIDs: info.objectIDs,
                pid: info.pid,
                bundleID: info.bundleID,
                name: info.name,
                icon: info.icon,
                isRunningOutput: info.isRunningOutput
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}
```

**Filter, transform, sort.** Only processes with `isRunningOutput == true` make it into
the final array. Each `Info` is converted to an `AudioProcess` (the model struct the UI
consumes). The list is sorted alphabetically by name, case-insensitive.

### Data flow: from HAL objects to AudioProcess

```
Core Audio HAL
│
│  kAudioHardwarePropertyProcessObjectList
│  returns: [102, 103, 104, 105, 106]
│
▼
Per-object property queries
│
│  Object 102 → PID: 1234, BundleID: "com.spotify.client", IsRunning: 1
│  Object 103 → PID: 5678, BundleID: "com.google.Chrome",  IsRunning: 1
│  Object 104 → PID: 5678, BundleID: "com.google.Chrome",  IsRunning: 0
│  Object 105 → PID: 321,  BundleID: "com.apple.Finder",   IsRunning: 0
│  Object 106 → PID: 9999, BundleID: "com.bastian.Hush",   IsRunning: 0  ← skipped
│
▼
Group by bundleID
│
│  "com.spotify.client" → objectIDs: [102], isRunning: true
│  "com.google.Chrome"  → objectIDs: [103, 104], isRunning: true  (103 OR 104)
│  "com.apple.Finder"   → objectIDs: [105], isRunning: false
│
▼
Filter to isRunningOutput == true
│
│  "com.spotify.client" → AudioProcess(name: "Spotify", ...)
│  "com.google.Chrome"  → AudioProcess(name: "Google Chrome", ...)
│
▼
Sort alphabetically → [Google Chrome, Spotify]
│
▼
ViewModel receives [AudioProcess] via onChange callback
```

---

## HAL property listeners: getting notified of changes

Core Audio provides an event-driven notification mechanism: you register a callback for
a specific property on a specific object, and the HAL calls your callback when that
property changes. This is conceptually like Linux's `inotify` (file change notifications)
or `epoll` (I/O readiness notifications) — you tell the kernel what you care about, and
it calls you back.

The registration function is `AudioObjectAddPropertyListenerBlock`:

```swift
func startListening() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.fireUpdate()
        }
    }
    listenerBlock = block
    AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &processListAddress,
        .main,
        block
    )
```

Four arguments:

1. **`AudioObjectID(kAudioObjectSystemObject)`** — watch the system object
2. **`&processListAddress`** — specifically, watch its process object list property
3. **`.main`** — deliver the callback on the main dispatch queue
4. **`block`** — the closure to call when the property changes

The callback receives two arguments (the number of addresses that changed and a pointer
to the addresses), but Hush ignores both — any change triggers a full re-enumeration.

The `[weak self]` capture list prevents a retain cycle. Without it, the block would hold
a strong reference to the monitor, and the monitor holds a strong reference to the block
(via `listenerBlock`), and neither would ever be deallocated. In Rust, this is like using
`Weak<T>` in a callback registered with a system API to avoid leaking an `Arc<T>`.

The `Task { @MainActor ... }` dispatch ensures `fireUpdate()` runs on the main thread,
since `AudioProcessMonitor` is `@MainActor`-isolated and the HAL may invoke the callback
from an internal dispatch queue.

**Cleanup** happens in both `stopListening()` and `deinit`:

```swift
func stopListening() {
    pollTimer?.invalidate()
    pollTimer = nil

    guard let block = listenerBlock else { return }
    AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &processListAddress,
        .main,
        block
    )
    listenerBlock = nil
}
```

You must pass the exact same arguments to `AudioObjectRemovePropertyListenerBlock` as
you passed to `AddPropertyListenerBlock`. The HAL matches on all four: object ID, address,
queue, and block. If any differ, the listener is not removed, and your callback continues
to fire after the object is logically done listening.

**The poll timer — why it exists:**

```swift
    // Poll every 2s to catch isRunningOutput changes (no HAL notification for those)
    pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
        Task { @MainActor [weak self] in
            self?.fireUpdate()
        }
    }
```

The HAL notifies when processes *join or leave* the audio system (the process object list
changes), but it does **not** notify when a process *starts or stops outputting audio*
(the `isRunningOutput` property changes). This is a gap in Core Audio's notification
coverage. Without the poll timer, a user would need to close and reopen Hush's menu to
see that Spotify started playing.

Two seconds is a compromise: frequent enough that the UI feels responsive, infrequent
enough that the CPU impact is negligible (each poll is a few property queries taking
microseconds).

> **Rust parallel**: This is the same situation you face with Linux's `inotify`: it
> notifies for file creation and deletion but not for all metadata changes. You end up
> combining event-driven notification (for what the kernel tells you) with periodic polling
> (for what it does not). The Rust `notify` crate has the same hybrid approach.

---

## Process taps: the muting mechanism

Process taps are the core feature that makes Hush possible. Introduced in macOS 14.2
(Sonoma), a process tap intercepts the audio output of one or more specific processes.
When configured with `muteBehavior: .muted`, the tap silences those processes at the
system level — the audio never reaches the speakers or headphones.

This API was presented at WWDC 2024 in the session
["What's new in Audio"](https://developer.apple.com/videos/play/wwdc2024/10116/),
with sample code demonstrating the aggregate device pattern that Hush uses.

The tap management code lives in `Hush/Audio/AudioTapManager.swift`.

### The mute function step by step

The `mute` function is 40 lines of carefully ordered resource creation. Each step depends
on the previous step's success, and each step's failure must clean up everything that came
before. Here is the complete walk-through:

```swift
func mute(processID: String, objectIDs: [AudioObjectID]) throws {
    guard sessions[processID] == nil, !objectIDs.isEmpty else { return }
```

**Guard against double-muting.** If a tap session already exists for this process, or if
there are no audio objects to tap, return immediately. This is a no-op, not an error.

**Step 1: Create the tap description.**

```swift
    // 1. Create tap description  (NS_REFINED_FOR_SWIFT → use __ prefix)
    let desc = CATapDescription(__stereoMixdownOfProcesses: objectIDs.map { NSNumber(value: $0) })
    let tapUUID = UUID()
    desc.uuid = tapUUID
    desc.muteBehavior = .muted
    desc.isPrivate = true
```

[`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)
is a high-level Swift class that describes what a process tap should do. The initializer
`__stereoMixdownOfProcesses:` creates a tap that mixes down all channels of the specified
processes into stereo. The `__` prefix indicates this is a "refined for Swift" API — the
Objective-C method name was adjusted for Swift conventions.

`objectIDs.map { NSNumber(value: $0) }` wraps each `AudioObjectID` (a `UInt32`) into
`NSNumber` because `CATapDescription` expects an array of Objective-C objects, not raw
integers. This is a bridging cost you pay when calling Objective-C APIs from Swift.

Three properties are set:

- **`uuid`** — a unique identifier for this tap, used later to reference it in the
  aggregate device configuration
- **`muteBehavior = .muted`** — this is the line that silences the audio. The tap
  intercepts the audio stream and does not forward it to the output device
- **`isPrivate = true`** — the tap's output is not routed to any audio device. Since
  Hush is muting (not recording), there is no reason for the tapped audio to go anywhere

**Step 2: Create the process tap.**

```swift
    // 2. Create the process tap
    var tapID: AudioObjectID = kAudioObjectUnknown
    var status = AudioHardwareCreateProcessTap(desc, &tapID)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    logger.info("Created tap \(tapID) for \(processID)")
```

`AudioHardwareCreateProcessTap` registers the tap with the HAL and returns its object ID.
After this call, the tap exists as a HAL object, but it is not yet active — it is not
connected to a device that drives audio through it.

**Step 3: Get the default output device UID.**

```swift
    // 3. Get default output device UID
    let outputUID: String
    do { outputUID = try CoreAudioHelper.defaultOutputDeviceUID() }
    catch {
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw error
    }
```

The tap needs to know which output device it is intercepting. `defaultOutputDeviceUID()`
(defined in `CoreAudioHelpers.swift`) queries two properties in sequence:

1. `kAudioHardwarePropertyDefaultOutputDevice` on the system object → gets the device's
   `AudioObjectID`
2. `kAudioDevicePropertyDeviceUID` on that device → gets its string UID
   (e.g., `"BuiltInSpeakerDevice"`)

If this fails, the tap is destroyed before throwing. This is the first instance of the
cleanup pattern that grows with each subsequent step.

**Step 4: Build an aggregate device.**

```swift
    // 4. Build aggregate device containing the tap + default output
    // Keys sourced from Apple's WWDC 2024 sample code for Audio Taps.
    // These are not in public headers — see AudioHardwareCreateAggregateDevice docs.
    let aggDesc: [String: Any] = [
        "uid":  "com.bastian.Hush.agg.\(UUID().uuidString)",
        "name": "Hush Tap",
        "private": 1,
        "stacked": 0,
        "subdevices": [["uid": outputUID]],
        "taps":       [["uid": tapUUID.uuidString]],
        "tapautostart": 1,
    ]

    var aggID: AudioObjectID = kAudioObjectUnknown
    status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID)
    guard status == noErr else {
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw CoreAudioError.osStatus(status)
    }
```

This is the most surprising step. A process tap cannot exist on its own — it must be
"hosted" by an aggregate device. An **aggregate device** is a virtual audio device that
combines multiple real devices (or taps) into one. macOS uses aggregate devices for
scenarios like combining a USB microphone with built-in speakers, or in this case,
connecting a process tap to the audio pipeline.

The dictionary keys are **not in any public header**. They come from Apple's WWDC 2024
sample code for the audio tap API. Here is what each key does:

| Key | Value | Purpose |
|---|---|---|
| `"uid"` | Unique string | Identifier for this aggregate device |
| `"name"` | `"Hush Tap"` | Display name (visible in Audio MIDI Setup.app) |
| `"private"` | `1` | Hide from the user's device list |
| `"stacked"` | `0` | Do not stack channels (use interleaved mode) |
| `"subdevices"` | `[["uid": outputUID]]` | The real device to include (default output) |
| `"taps"` | `[["uid": tapUUID]]` | The process tap to include |
| `"tapautostart"` | `1` | Automatically start the tap when the device starts |

Failure at this step cleans up the process tap before throwing.

**Step 5: Create a no-op IO proc.**

```swift
    // 5. Create a no-op IO proc (required to drive the aggregate device)
    var procID: AudioDeviceIOProcID?
    status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, _, _, _, _ in }
    guard status == noErr else {
        _ = AudioHardwareDestroyAggregateDevice(aggID)
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw CoreAudioError.osStatus(status)
    }
    guard let unwrappedProcID = procID else {
        _ = AudioHardwareDestroyAggregateDevice(aggID)
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw CoreAudioError.ioProcCreationFailed
    }
```

An audio device needs an **IO proc** — a callback that processes audio buffers — before
it can be started. Since Hush is muting (not recording or processing), the IO proc does
nothing: `{ _, _, _, _, _ in }` is an empty closure that ignores all five parameters
(the device ID, current time, input data, output time, and output data).

The `AudioDeviceCreateIOProcIDWithBlock` function returns both an `OSStatus` and an
optional `AudioDeviceIOProcID`. Both must be checked — the function can return `noErr`
but still produce a nil proc ID in edge cases.

Failure cleans up the aggregate device *and* the process tap.

**Step 6: Start the aggregate device.**

```swift
    // 6. Start the aggregate device
    status = AudioDeviceStart(aggID, unwrappedProcID)
    guard status == noErr else {
        _ = AudioDeviceDestroyIOProcID(aggID, unwrappedProcID)
        _ = AudioHardwareDestroyAggregateDevice(aggID)
        _ = AudioHardwareDestroyProcessTap(tapID)
        throw CoreAudioError.osStatus(status)
    }
```

`AudioDeviceStart` activates the aggregate device, which in turn activates the process
tap (because of `"tapautostart": 1`). At this point, the app's audio is being intercepted
and silenced.

Failure cleans up the IO proc, the aggregate device, and the process tap — three
resources in reverse allocation order.

```swift
    sessions[processID] = TapSession(
        tapObjectID: tapID,
        aggregateDeviceID: aggID,
        ioProcID: unwrappedProcID
    )
}
```

**Store the session.** The `TapSession` struct holds all three resource IDs needed for
cleanup. It is keyed by `processID` (the bundle ID or PID string) in the `sessions`
dictionary.

### The cleanup tower

Look at how the cleanup grows with each step:

```
Step 2 fails → destroy tap
Step 3 fails → destroy tap
Step 4 fails → destroy tap
Step 5 fails → destroy aggregate device, destroy tap
Step 6 fails → destroy IO proc, destroy aggregate device, destroy tap
```

Each step adds one more resource to clean up. This is the manual version of what Rust's
ownership system handles automatically. In Rust, you would wrap each resource in a type
that implements `Drop`, and let scope-based destruction handle the cleanup:

```rust
let tap = ProcessTap::create(desc)?;           // Drop destroys tap
let agg = AggregateDevice::create(desc)?;      // Drop destroys aggregate device
let proc = IoProc::create(agg.id())?;          // Drop destroys IO proc
agg.start(proc.id())?;
// All three survive — move them into the session
std::mem::forget(tap);  // ownership transferred to session
```

In Swift, you do this manually. There is no compiler enforcing that you clean up in the
right order, or that you clean up at all. The `guard ... else { cleanup; throw }` pattern
is the discipline that prevents resource leaks.

### The complete audio muting pipeline

When Hush mutes Spotify, here is what exists in the audio system:

```
                      Before muting:

  Spotify ──► audio stream ──► Default Output Device ──► Speakers
  Chrome  ──► audio stream ──► Default Output Device ──► Speakers


                       After muting Spotify:

  Spotify ──► audio stream ──► Process Tap (muteBehavior: .muted)
                                     │
                                     ▼
                               Aggregate Device ──► (audio discarded,
                               "Hush Tap"           tap is private)
                                     │
                                     ├── subdevice: Default Output
                                     └── tap: Spotify's tap

  Chrome  ──► audio stream ──► Default Output Device ──► Speakers
                               (unaffected)
```

The process tap intercepts Spotify's audio before it reaches the output device. Because
`muteBehavior` is `.muted` and `isPrivate` is `true`, the intercepted audio is discarded.
Chrome's audio is unaffected because the tap targets only the specific process objects
belonging to Spotify.

---

## Teardown: orderly resource cleanup

When the user unmutes a process, Hush must tear down all the resources created during
muting. The `teardown` function does this:

```swift
private func teardown(_ session: TapSession) {
    _ = AudioDeviceStop(session.aggregateDeviceID, session.ioProcID)
    _ = AudioDeviceDestroyIOProcID(session.aggregateDeviceID, session.ioProcID)
    _ = AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
    _ = AudioHardwareDestroyProcessTap(session.tapObjectID)
}
```

Four steps, in **reverse order** from creation:

1. **Stop the aggregate device** — halt audio processing
2. **Destroy the IO proc** — remove the callback from the device
3. **Destroy the aggregate device** — remove the virtual device from the system
4. **Destroy the process tap** — release the tap from the HAL

The `_ =` discards the return status. During teardown, there is nothing meaningful to do
if a step fails — the resources may already be partially invalid (e.g., if the output
device was disconnected). Logging failures could be useful for debugging, but the current
approach prioritizes making forward progress through the cleanup.

The order matters. You cannot destroy the aggregate device while its IO proc is still
running. You cannot destroy the process tap while the aggregate device still references
it. This is the inverse of the construction order — last in, first out.

```
Construction:  tap → aggregate → IO proc → start
Destruction:   stop → IO proc → aggregate → tap
```

In Rust, the compiler enforces this through `Drop` ordering: fields of a struct are
dropped in declaration order, and local variables are dropped in reverse declaration
order. In Core Audio, you enforce it by writing the calls in the right sequence.

The public methods `unmute` and `teardownAll` delegate to this private function:

```swift
func unmute(processID: String) {
    guard let session = sessions.removeValue(forKey: processID) else { return }
    logger.info("Removing tap for \(processID)")
    teardown(session)
}

func teardownAll() {
    sessions.values.forEach { teardown($0) }
    sessions.removeAll()
}
```

`unmute` removes a single session from the dictionary and tears it down. `teardownAll`
iterates every active session and tears them all down, then clears the dictionary. The
`removeValue(forKey:)` return value serves double duty: it both removes the entry and
provides the `TapSession` for cleanup, or returns `nil` if there is nothing to clean up.

---

## TCC permissions: the system permission prompt

macOS uses a system called **TCC** (Transparency, Consent, and Control) to gate access
to sensitive resources: camera, microphone, screen recording, contacts, and — relevant
here — system audio capture. When an app first attempts to create a process tap, macOS
shows a permission dialog asking the user to grant "Screen & System Audio Recording"
access.

Hush handles this proactively. Rather than waiting until the user tries to mute something
(and then surprising them with a permission dialog), it triggers the prompt at launch:

```swift
/// Triggers the TCC "Screen & System Audio Recording" prompt at launch
/// by creating and immediately destroying a dummy process tap.
private func requestAudioTapPermission() {
    let desc = CATapDescription(__stereoGlobalTapButExcludeProcesses: [])
    desc.muteBehavior = .unmuted
    desc.isPrivate = true
    var tapID: AudioObjectID = kAudioObjectUnknown
    let status = AudioHardwareCreateProcessTap(desc, &tapID)
    if status == noErr {
        AudioHardwareDestroyProcessTap(tapID)
    }
}
```

This creates a **global tap** (not targeting any specific process) that excludes no
processes. It is set to `.unmuted` so it would not actually silence anything even if it
persisted. The purpose is to trigger the TCC check — macOS sees "this app wants to create
a process tap" and presents the permission dialog.

If the user grants permission, `AudioHardwareCreateProcessTap` returns `noErr`, and the
dummy tap is immediately destroyed. If the user denies permission, the function returns
an error status, and nothing else happens — the app remains functional but muting will
fail when attempted.

The permission prompt's text comes from `Info.plist`:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Hush needs audio access to mute and unmute individual apps.</string>
```

This is the **usage description string** — macOS displays it in the permission dialog to
explain why the app needs access. Without this key in the plist, the app would crash
immediately upon attempting to create a process tap. Apple enforces this at the OS level.

When a user later tries to mute and permission has been denied, the error flows through:

1. `AudioHardwareCreateProcessTap` returns a TCC denial code (-66753 or -66748)
2. `AudioTapManager.mute` throws `CoreAudioError.osStatus(code)`
3. `AppListViewModel.toggleMute` catches it, checks `isPermissionError`
4. If true, sets `self.error = .permissionDenied`
5. The UI shows the error banner with a message directing the user to System Settings

> **Rust parallel**: TCC is like Linux's capabilities system or SELinux — the kernel
> restricts what operations a process can perform regardless of the code's intent. In
> Rust, you would handle this the same way: check the error code from the C function,
> map it to a domain-specific error, and present a meaningful message to the user.

---

## Device change handling

When the user switches output devices — plugging in headphones, connecting AirPods,
selecting a different device in System Settings — every active process tap breaks. The
taps were created with a reference to the *previous* output device's UID. With a new
output device active, the aggregate devices are pointing at a stale target.

Hush detects this through a HAL property listener on `kAudioHardwarePropertyDefaultOutputDevice`:

```swift
private func startDeviceListener() {
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        Task { @MainActor [weak self] in
            self?.handleDeviceChange()
        }
    }
    deviceListenerBlock = block
    AudioObjectAddPropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &deviceAddress,
        .main,
        block
    )
}
```

Same pattern as the process list listener in `AudioProcessMonitor`: register a callback
on the system object for a specific property, dispatch to the main thread, call the
handler.

The handler is where the interesting logic lives:

```swift
private func handleDeviceChange() {
    guard anyMuted else { return }
```

If nothing is muted, there is nothing to do. The taps do not exist.

```swift
    // Debounce rapid device switches (e.g. connecting AirPods)
    deviceChangeTask?.cancel()
    deviceChangeTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled, let self else { return }
```

**Debouncing.** When AirPods connect, macOS fires multiple device change events in rapid
succession — the system may switch to a temporary device, then to the AirPods, then
adjust properties. Without debouncing, Hush would tear down and rebuild all taps two or
three times in the span of a second, which wastes resources and could cause audible
glitches.

The debounce mechanism uses Swift's structured concurrency:

1. Cancel any pending device change task
2. Create a new task that sleeps 500ms before doing work
3. If another device change arrives during the 500ms, the task is cancelled, and a new
   one starts the 500ms window over

`try? await Task.sleep(for: .milliseconds(500))` sleeps without throwing if cancelled —
the `try?` swallows the `CancellationError`. The `guard !Task.isCancelled` check after
the sleep catches the case where the task was cancelled *during* the sleep (the sleep
returns early in that case).

In Rust, you would implement this with a `tokio::time::sleep` combined with an
`AbortHandle`, or a `debounce` combinator from a reactive streams library.

```swift
        logger.info("Output device changed, recreating \(self.mutedProcessIDs.count) tap(s)")

        let saved = self.mutedObjectIDs
```

**Save the current mute state.** The `mutedObjectIDs` dictionary maps process IDs to
their audio object IDs — everything needed to recreate the taps.

```swift
        self.tapManager.teardownAll()
```

**Tear down all existing taps.** The old aggregate devices referenced the old output
device; they are useless now.

```swift
        // Collect new state into locals, then assign once to avoid
        // a UI flicker where everything briefly appears unmuted.
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

**Recreate taps for the new output device.** For each previously-muted process, attempt
to create a new tap. The new tap automatically picks up the new default output device
because `CoreAudioHelper.defaultOutputDeviceUID()` is called inside `tapManager.mute()`.

New state is collected into local variables first, then assigned to the `@Observable`
properties in a batch. This prevents a UI flicker where the muted icons would briefly
disappear (when `teardownAll` clears `mutedProcessIDs`) and then reappear (when the
re-mute succeeds). By writing the final state all at once, SwiftUI sees a single
consistent update.

If re-muting fails for a process (perhaps it exited during the device switch), that
process is removed from the cache and silently dropped from the muted set. The remaining
processes continue to be muted.

```
Device change flow:

AirPods connect
    │
    ▼
HAL fires kAudioHardwarePropertyDefaultOutputDevice (event 1)
    │
    ▼
handleDeviceChange() → creates Task with 500ms delay
    │
    │  ... 100ms later ...
    │
HAL fires kAudioHardwarePropertyDefaultOutputDevice (event 2)
    │
    ▼
handleDeviceChange() → cancels previous task, creates new 500ms task
    │
    │  ... 500ms of silence ...
    │
    ▼
Task fires:
    1. Save: {Spotify: [102], Chrome: [103, 104]}
    2. Tear down all existing taps
    3. Recreate tap for Spotify with new output device UID → success
    4. Recreate tap for Chrome with new output device UID → success
    5. Assign new muted state → UI stays consistent
```

---

## Key resources

### Apple documentation

- **[Core Audio Overview](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/Introduction/Introduction.html)** — Apple's high-level introduction to Core Audio. Covers the architecture and component relationships. Somewhat dated but still accurate for the HAL layer.

- **[Audio Hardware Services (AudioHardware.h)](https://developer.apple.com/documentation/coreaudio/audio_hardware)** — The API reference for the HAL functions Hush uses (`AudioObjectGetPropertyData`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`, etc.). The real documentation is in the header file comments.

- **[CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)** — Documentation for the tap description class used to configure process taps.

- **[Technical Note TN2091: Device input using the HAL Output Audio Unit](https://developer.apple.com/library/archive/technotes/tn2091/_index.html)** — Older technical note about audio device I/O. Useful for understanding the IO proc concept.

### WWDC sessions

| Session | Year | Why watch it |
|---|---|---|
| **[What's new in Audio](https://developer.apple.com/videos/play/wwdc2024/10116/)** | 2024 | Introduces the process tap API and aggregate device pattern that Hush uses. The sample code from this session is the source of the undocumented dictionary keys in `AudioTapManager.mute()`. |
| **[Discover Observation in SwiftUI](https://developer.apple.com/videos/play/wwdc2023/10149/)** | 2023 | Covers `@Observable`, which `AppListViewModel` uses. Relevant for understanding how property changes drive UI updates. |

### Header files (the real documentation)

Core Audio's headers contain extensive inline documentation that often exceeds what Apple
publishes online. If you have Xcode installed, you can find them at:

```
/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/
SDKs/MacOSX.sdk/System/Library/Frameworks/CoreAudio.framework/Headers/
```

Key files:

- **`AudioHardware.h`** — HAL functions (`AudioObjectGetPropertyData`, etc.)
- **`AudioHardwareBase.h`** — Property selector constants, scope/element constants
- **`AudioHardwareDeprecated.h`** — Older API versions (avoid these)

### For Rust developers

- **[cpal](https://github.com/RustAudio/cpal)** — The closest Rust equivalent to Core Audio for cross-platform audio I/O. Uses Core Audio on macOS internally.
- **[coreaudio-rs](https://github.com/RustAudio/coreaudio-rs)** — Direct Rust bindings to Core Audio. Shows how the same C API looks when wrapped in Rust FFI.

---

## Summary

Core Audio programming in Swift is FFI programming. You call C functions, manage raw
memory, interpret bytes, and clean up resources manually. For a Rust developer, this
territory is familiar — the concepts map directly:

1. **`AudioObjectID` is a handle.** Like a file descriptor or a raw pointer — an opaque
   integer that identifies a kernel-managed resource.

2. **Properties are queried through addresses.** Like reading sysfs entries — you
   construct a path (selector + scope + element) and read the value.

3. **Memory management is manual.** Allocate, read, reinterpret, deallocate. No GC, no
   ARC (for the C layer), no safety net. `defer` provides scope-based cleanup, filling
   the role of `Drop`.

4. **Error handling is return-code-based.** Every C function returns an `OSStatus`.
   Wrap it, check it, throw on failure. Identical to checking `errno` in Rust FFI.

5. **Resource cleanup must be ordered.** Resources are freed in reverse allocation order.
   Rust enforces this through `Drop` ordering; in Swift Core Audio, you do it by hand.

6. **Process taps require a pipeline.** Muting an app is not a single function call — it
   is a six-step construction of tap, aggregate device, IO proc, and activation. Each
   step can fail, and failure must clean up all prior steps.

7. **The system owns your permissions.** TCC gates access to process taps. You must
   request permission proactively and handle denial gracefully.

With this foundation, you understand Hush's entire audio layer — from the low-level
property queries in `CoreAudioHelpers.swift`, through process enumeration in
`AudioProcessMonitor.swift`, to the muting pipeline in `AudioTapManager.swift`, and the
orchestration in `AppListViewModel.swift`.
