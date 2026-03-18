import AppKit
import CoreAudio

/// `@unchecked Sendable` because `NSImage` is not formally `Sendable`,
/// but instances here are only read after creation, and the struct is
/// exclusively used from `@MainActor` context.
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
