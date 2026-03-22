import Observation
import CoreAudio
import AppKit
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.bastian.Hush", category: "ViewModel")

enum HushError: Error {
    case permissionDenied
    case muteFailed(processName: String, detail: String)

    var message: String {
        switch self {
        case .permissionDenied:
            return "Hush needs Screen & System Audio Recording permission. Open System Settings > Privacy & Security to grant access."
        case .muteFailed(let name, let detail):
            return "Failed to mute \(name): \(detail)"
        }
    }
}

@Observable
@MainActor
final class AppListViewModel {
    var processes: [AudioProcess] = []
    var processVolumes: [String: Float] = [:]
    var error: HushError?
    var launchAtLogin = false

    var anyAdjusted: Bool { !processVolumes.isEmpty }
    var anyMuted: Bool { processVolumes.values.contains { $0 <= 0 } }

    private let monitor = AudioProcessMonitor()
    private let tapManager = AudioTapManager()
    private var tappedObjectIDs: [String: [AudioObjectID]] = [:]
    private var tappedProcessCache: [String: AudioProcess] = [:]
    private var previousVolumes: [String: Float] = [:]

    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceChangeTask: Task<Void, Never>?

    init() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        processes = monitor.enumerateProcesses()

        monitor.onChange = { [weak self] processes in
            Task { @MainActor [weak self] in
                self?.handleProcessUpdate(processes)
            }
        }
        monitor.startListening()
        startDeviceListener()
        requestAudioTapPermission()
    }

    func volume(for processID: String) -> Float {
        processVolumes[processID] ?? 1.0
    }

    // MARK: - Actions

    func toggleMute(for process: AudioProcess) {
        let current = volume(for: process.id)
        if current > 0 {
            previousVolumes[process.id] = current
            setVolume(for: process, to: 0)
        } else {
            let restored = previousVolumes.removeValue(forKey: process.id) ?? 1.0
            setVolume(for: process, to: restored)
        }
    }

    func setVolume(for process: AudioProcess, to volume: Float) {
        let clamped = min(max(volume, 0), 1)

        if clamped >= 1.0 {
            tapManager.removeTap(processID: process.id)
            processVolumes.removeValue(forKey: process.id)
            tappedObjectIDs.removeValue(forKey: process.id)
            tappedProcessCache.removeValue(forKey: process.id)
            previousVolumes.removeValue(forKey: process.id)
            error = nil
        } else {
            do {
                try tapManager.setVolume(processID: process.id, objectIDs: process.objectIDs, volume: Float32(clamped))
                processVolumes[process.id] = clamped
                tappedObjectIDs[process.id] = process.objectIDs
                tappedProcessCache[process.id] = process
                error = nil
            } catch let err {
                if let caErr = err as? CoreAudioError, caErr.isPermissionError {
                    self.error = .permissionDenied
                } else {
                    self.error = .muteFailed(processName: process.name, detail: err.localizedDescription)
                }
                logger.error("Volume change failed for \(process.name): \(err.localizedDescription)")
            }
        }
    }

    func resetAll() {
        tapManager.teardownAll()
        processVolumes.removeAll()
        tappedObjectIDs.removeAll()
        tappedProcessCache.removeAll()
        previousVolumes.removeAll()
        error = nil
    }

    func teardown() {
        resetAll()
        monitor.stopListening()
        stopDeviceListener()
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func toggleLaunchAtLogin() {
        let newValue = !launchAtLogin
        do {
            if newValue {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = newValue
        } catch {
            logger.error("Launch at login failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private

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

    private func handleProcessUpdate(_ activeProcesses: [AudioProcess]) {
        var merged = activeProcesses

        // Keep tapped processes visible even when they pause audio output.
        // Collect exited IDs first, then clean up in a second pass to avoid
        // mutating tappedProcessCache while iterating over it.
        let exitedIDs = tappedProcessCache.keys.filter { id in
            guard let cached = tappedProcessCache[id] else { return false }
            return !activeProcesses.contains(where: { $0.id == id }) &&
                kill(cached.pid, 0) != 0
        }
        for id in exitedIDs {
            logger.info("Tapped process exited: \(self.tappedProcessCache[id]?.name ?? id)")
            tapManager.removeTap(processID: id)
            processVolumes.removeValue(forKey: id)
            tappedObjectIDs.removeValue(forKey: id)
            tappedProcessCache.removeValue(forKey: id)
            previousVolumes.removeValue(forKey: id)
        }

        // Append still-alive tapped processes that stopped outputting audio
        for (id, cached) in tappedProcessCache {
            if !activeProcesses.contains(where: { $0.id == id }) {
                var copy = cached
                copy.isRunningOutput = false
                merged.append(copy)
            }
        }

        processes = merged.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

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

    private func stopDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &deviceAddress,
            .main,
            block
        )
        deviceListenerBlock = nil
    }

    private func handleDeviceChange() {
        guard anyAdjusted else { return }

        // Debounce rapid device switches (e.g. connecting AirPods)
        deviceChangeTask?.cancel()
        deviceChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }

            logger.info("Output device changed, recreating \(self.processVolumes.count) tap(s)")

            let savedObjectIDs = self.tappedObjectIDs
            let savedVolumes = self.processVolumes

            self.tapManager.teardownAll()

            // Collect new state into locals, then assign once to avoid
            // a UI flicker where everything briefly appears unmuted.
            var newVolumes: [String: Float] = [:]
            var newObjectIDs: [String: [AudioObjectID]] = [:]

            for (processID, objectIDs) in savedObjectIDs {
                let volume = savedVolumes[processID] ?? 1.0
                guard volume < 1.0 else { continue }
                do {
                    try self.tapManager.setVolume(processID: processID, objectIDs: objectIDs, volume: Float32(volume))
                    newVolumes[processID] = volume
                    newObjectIDs[processID] = objectIDs
                } catch {
                    logger.error("Re-tap failed for \(processID): \(error.localizedDescription)")
                    self.tappedProcessCache.removeValue(forKey: processID)
                    self.previousVolumes.removeValue(forKey: processID)
                }
            }

            self.processVolumes = newVolumes
            self.tappedObjectIDs = newObjectIDs
        }
    }
}
