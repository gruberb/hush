import Accelerate
import CoreAudio
import Foundation
import os

private let logger = Logger(subsystem: "com.bastian.Hush", category: "AudioTap")

struct TapSession: @unchecked Sendable {
    let tapObjectID: AudioObjectID
    let aggregateDeviceID: AudioObjectID
    let ioProcID: AudioDeviceIOProcID
    let volumePtr: UnsafeMutablePointer<Float32>
}

@MainActor
final class AudioTapManager {
    private var sessions: [String: TapSession] = [:]

    // MARK: - Public

    /// Sets the volume for the given process. A value of 1.0 removes the tap
    /// entirely (no processing overhead). Values below 1.0 create or update a
    /// tap that scales the audio, with 0.0 being equivalent to full mute.
    func setVolume(processID: String, objectIDs: [AudioObjectID], volume: Float32) throws {
        let clamped = min(max(volume, 0), 1)

        if clamped >= 1.0 {
            removeTap(processID: processID)
            return
        }

        if let session = sessions[processID] {
            session.volumePtr.pointee = clamped
        } else {
            try createTap(processID: processID, objectIDs: objectIDs, volume: clamped)
        }
    }

    func removeTap(processID: String) {
        guard let session = sessions.removeValue(forKey: processID) else { return }
        logger.info("Removing tap for \(processID)")
        teardown(session)
    }

    func teardownAll() {
        sessions.values.forEach { teardown($0) }
        sessions.removeAll()
    }

    // MARK: - Private

    private func createTap(processID: String, objectIDs: [AudioObjectID], volume: Float32) throws {
        guard !objectIDs.isEmpty else { return }

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

        // 5. Create volume-scaling IO proc.
        // The captured pointer is read from the real-time audio thread;
        // 32-bit aligned Float32 reads are atomic on ARM64 and x86_64.
        let volumePtr = UnsafeMutablePointer<Float32>.allocate(capacity: 1)
        volumePtr.initialize(to: volume)

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, outOutputData, _ in
            var vol = volumePtr.pointee
            let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outputList = UnsafeMutableAudioBufferListPointer(outOutputData)

            for i in 0..<outputList.count {
                guard let dst = outputList[i].mData else { continue }
                let dstBytes = Int(outputList[i].mDataByteSize)

                if i < inputList.count, let src = inputList[i].mData {
                    let bytes = min(Int(inputList[i].mDataByteSize), dstBytes)
                    let count = bytes / MemoryLayout<Float32>.stride
                    let srcPtr = src.assumingMemoryBound(to: Float32.self)
                    let dstPtr = dst.assumingMemoryBound(to: Float32.self)
                    vDSP_vsmul(srcPtr, 1, &vol, dstPtr, 1, vDSP_Length(count))
                } else {
                    memset(dst, 0, dstBytes)
                }
            }
        }

        guard status == noErr else {
            volumePtr.deinitialize(count: 1)
            volumePtr.deallocate()
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError.osStatus(status)
        }
        guard let unwrappedProcID = procID else {
            volumePtr.deinitialize(count: 1)
            volumePtr.deallocate()
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError.ioProcCreationFailed
        }

        // 6. Start the aggregate device
        status = AudioDeviceStart(aggID, unwrappedProcID)
        guard status == noErr else {
            volumePtr.deinitialize(count: 1)
            volumePtr.deallocate()
            _ = AudioDeviceDestroyIOProcID(aggID, unwrappedProcID)
            _ = AudioHardwareDestroyAggregateDevice(aggID)
            _ = AudioHardwareDestroyProcessTap(tapID)
            throw CoreAudioError.osStatus(status)
        }

        sessions[processID] = TapSession(
            tapObjectID: tapID,
            aggregateDeviceID: aggID,
            ioProcID: unwrappedProcID,
            volumePtr: volumePtr
        )
    }

    private func teardown(_ session: TapSession) {
        _ = AudioDeviceStop(session.aggregateDeviceID, session.ioProcID)
        _ = AudioDeviceDestroyIOProcID(session.aggregateDeviceID, session.ioProcID)
        _ = AudioHardwareDestroyAggregateDevice(session.aggregateDeviceID)
        _ = AudioHardwareDestroyProcessTap(session.tapObjectID)
        session.volumePtr.deinitialize(count: 1)
        session.volumePtr.deallocate()
    }
}
