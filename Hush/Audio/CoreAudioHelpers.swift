import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.bastian.Hush", category: "CoreAudio")

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

    var isPermissionError: Bool {
        guard case .osStatus(let code) = self else { return false }
        // TCC / permission denial codes observed with process taps
        return code == -66753 || code == -66748
    }

    private static let knownCodes: [OSStatus: String] = [
        560947818: "Bad audio object",         // '!obj'
        1970171760: "Not running",             // 'stop'
        1970170480: "Unsupported operation",   // 'unop'
        1852797029: "Illegal operation",       // 'nope'
    ]
}

func caPropertyData<T>(from objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> T {
    var address = address
    var size: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { data.deallocate() }

    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, data)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    return data.load(as: T.self)
}

func caPropertyArray<T>(from objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> [T] {
    var address = address
    var size: UInt32 = 0

    var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    let count = Int(size) / MemoryLayout<T>.stride
    guard count > 0 else { return [] }

    let data = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
    defer { data.deallocate() }

    status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, data)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    let buffer = data.bindMemory(to: T.self, capacity: count)
    return Array(UnsafeBufferPointer(start: buffer, count: count))
}

func caStringProperty(from objectID: AudioObjectID, address: AudioObjectPropertyAddress) throws -> String {
    var address = address
    var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)

    let ptr = UnsafeMutablePointer<Unmanaged<CFString>>.allocate(capacity: 1)
    defer { ptr.deallocate() }

    let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
    guard status == noErr else { throw CoreAudioError.osStatus(status) }

    // AudioObjectGetPropertyData follows the "Get Rule" — caller does NOT own the reference
    return ptr.pointee.takeUnretainedValue() as String
}

func caDefaultOutputDeviceUID() throws -> String {
    let deviceID: AudioObjectID = try caPropertyData(
        from: AudioObjectID(kAudioObjectSystemObject),
        address: AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    )
    return try caStringProperty(
        from: deviceID,
        address: AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    )
}
