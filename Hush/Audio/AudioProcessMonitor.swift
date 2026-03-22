import CoreAudio
import AppKit
import os

private let logger = Logger(subsystem: "com.bastian.Hush", category: "ProcessMonitor")

@MainActor
final class AudioProcessMonitor {
    var onChange: (([AudioProcess]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var processListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var pollTimer: Timer?

    private static let ownBundleID = Bundle.main.bundleIdentifier

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

        struct Info {
            var objectIDs: [AudioObjectID]
            var pid: pid_t
            var bundleID: String?
            var name: String
            var icon: NSImage?
            var isRunningOutput: Bool
        }

        var grouped: [String: Info] = [:]

        for oid in objectIDs {
            let pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard let pid: pid_t = try? CoreAudioHelper.propertyData(from: oid, address: pidAddr) else { continue }

            let runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let isRunning: UInt32 = (try? CoreAudioHelper.propertyData(from: oid, address: runAddr)) ?? 0

            let bidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let bundleID = try? CoreAudioHelper.stringProperty(from: oid, address: bidAddr)

            // Skip our own process
            if bundleID == Self.ownBundleID { continue }

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
    }

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

        // Poll every 2s to catch isRunningOutput changes (no HAL notification for those)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.fireUpdate()
            }
        }
    }

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

    private func fireUpdate() {
        guard let onChange else { return }
        let processes = enumerateProcesses()
        onChange(processes)
    }
}
