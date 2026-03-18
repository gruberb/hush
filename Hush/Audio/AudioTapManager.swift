import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.bastian.Hush", category: "AudioTap")

struct TapSession {
    let tapObjectID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
}

@MainActor
final class AudioTapManager {
    private var sessions: [String: TapSession] = [:]

    // MARK: - Public

    func mute(processID: String, objectIDs: [AudioObjectID]) throws {
        guard sessions[processID] == nil, !objectIDs.isEmpty else { return }

        // 1. Create tap description  (NS_REFINED_FOR_SWIFT → use __ prefix)
        let desc = CATapDescription(__stereoMixdownOfProcesses: objectIDs.map { NSNumber(value: $0) })
        let tapUUID = UUID()
        desc.uuid = tapUUID
        desc.muteBehavior = .muted
        desc.isPrivate = true

        // 2. Create the process tap
        var tapID: AudioObjectID = kAudioObjectUnknown
        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr else { throw CoreAudioError.osStatus(status) }

        logger.info("Created tap \(tapID) for \(processID)")

        // 3. Get default output device UID
        let outputUID: String
        do { outputUID = try CoreAudioHelper.defaultOutputDeviceUID() }
        catch {
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw error
        }

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

        // 6. Start the aggregate device
        status = AudioDeviceStart(aggID, unwrappedProcID)
        guard status == noErr else {
            _ = AudioDeviceDestroyIOProcID(aggID, unwrappedProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError.osStatus(status)
        }

        sessions[processID] = TapSession(
            tapObjectID: tapID,
            aggregateDeviceID: aggID,
            ioProcID: unwrappedProcID
        )
    }

    func unmute(processID: String) {
        guard let session = sessions.removeValue(forKey: processID) else { return }
        logger.info("Removing tap for \(processID)")
        teardown(session)
    }

    func teardownAll() {
        sessions.values.forEach { teardown($0) }
        sessions.removeAll()
    }

    // MARK: - Private

    private func teardown(_ session: TapSession) {
        _ = AudioDeviceStop(session.aggregateDeviceID, session.ioProcID)
        _ = AudioDeviceDestroyIOProcID(session.aggregateDeviceID, session.ioProcID)
        _ = AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        _ = AudioHardwareDestroyProcessTap(session.tapObjectID)
    }
}
