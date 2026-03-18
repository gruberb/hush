import Observation
import CoreAudio
import AppKit
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.bastian.Hush", category: "ViewModel")

@Observable
@MainActor
final class AppListViewModel {
    var processes: [AudioProcess] = []
    var mutedProcessIDs: Set<String> = []
    var error: String?

    var anyMuted: Bool { !mutedProcessIDs.isEmpty }

    private let monitor = AudioProcessMonitor()
    private let tapManager = AudioTapManager()
    private var mutedObjectIDs: [String: [AudioObjectID]] = [:]
    private var mutedProcessCache: [String: AudioProcess] = [:]

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

    // MARK: - Actions

    func toggleMute(for process: AudioProcess) {
        if mutedProcessIDs.contains(process.id) {
            tapManager.unmute(processID: process.id)
            mutedProcessIDs.remove(process.id)
            mutedObjectIDs.removeValue(forKey: process.id)
            mutedProcessCache.removeValue(forKey: process.id)
            error = nil
        } else {
            do {
                try tapManager.mute(processID: process.id, objectIDs: process.objectIDs)
                mutedProcessIDs.insert(process.id)
                mutedObjectIDs[process.id] = process.objectIDs
                mutedProcessCache[process.id] = process
                error = nil
            } catch let err {
                if let caErr = err as? CoreAudioError, caErr.isPermissionError {
                    self.error = "Hush needs Screen & System Audio Recording permission. Open System Settings > Privacy & Security to grant access."
                } else {
                    self.error = "Failed to mute \(process.name): \(err.localizedDescription)"
                }
                logger.error("Mute failed for \(process.name): \(err.localizedDescription)")
            }
        }
    }

    func unmuteAll() {
        tapManager.teardownAll()
        mutedProcessIDs.removeAll()
        mutedObjectIDs.removeAll()
        mutedProcessCache.removeAll()
        error = nil
    }

    func teardown() {
        unmuteAll()
        monitor.stopListening()
        stopDeviceListener()
    }

    func openAudioPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    var launchAtLogin = false

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

    private func handleProcessUpdate(_ activeProcesses: [AudioProcess]) {
        var merged = activeProcesses

        // Keep muted processes visible even when they pause audio output
        for (id, cached) in mutedProcessCache {
            if !activeProcesses.contains(where: { $0.id == id }) {
                if kill(cached.pid, 0) == 0 {
                    // Process is alive but not outputting audio — keep it visible
                    var copy = cached
                    copy.isRunningOutput = false
                    merged.append(copy)
                } else {
                    // Process has exited — clean up the tap
                    logger.info("Muted process exited: \(cached.name)")
                    tapManager.unmute(processID: id)
                    mutedProcessIDs.remove(id)
                    mutedObjectIDs.removeValue(forKey: id)
                    mutedProcessCache.removeValue(forKey: id)
                }
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
        guard anyMuted else { return }

        // Debounce rapid device switches (e.g. connecting AirPods)
        deviceChangeTask?.cancel()
        deviceChangeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }

            logger.info("Output device changed, recreating \(self.mutedProcessIDs.count) tap(s)")

            let saved = self.mutedObjectIDs

            self.tapManager.teardownAll()
            self.mutedProcessIDs.removeAll()
            self.mutedObjectIDs.removeAll()

            for (processID, objectIDs) in saved {
                do {
                    try self.tapManager.mute(processID: processID, objectIDs: objectIDs)
                    self.mutedProcessIDs.insert(processID)
                    self.mutedObjectIDs[processID] = objectIDs
                } catch {
                    logger.error("Re-mute failed for \(processID): \(error.localizedDescription)")
                    self.mutedProcessCache.removeValue(forKey: processID)
                }
            }
        }
    }
}
