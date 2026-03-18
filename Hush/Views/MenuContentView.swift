import SwiftUI

struct MenuContentView: View {
    var viewModel: AppListViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            processList
            errorBanner
            Divider()
            footer
        }
        .frame(width: 280)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Hush")
                .font(.headline)
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
            if viewModel.anyMuted {
                Button("Unmute All") {
                    viewModel.unmuteAll()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .font(.caption)
                .accessibilityLabel("Unmute all apps")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var processList: some View {
        if viewModel.processes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .font(.system(size: 24))
                    .foregroundStyle(.quaternary)
                Text("No apps playing audio")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Apps will appear here when they produce sound")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .padding(.horizontal, 16)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(viewModel.processes) { process in
                        AudioProcessRow(
                            process: process,
                            isMuted: viewModel.mutedProcessIDs.contains(process.id)
                        ) {
                            viewModel.toggleMute(for: process)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 300)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = viewModel.error {
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                if error.contains("permission") || error.contains("Permission") {
                    Button("Open System Settings") {
                        viewModel.openAudioPrivacySettings()
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Button {
                viewModel.toggleLaunchAtLogin()
            } label: {
                HStack {
                    Image(systemName: viewModel.launchAtLogin ? "checkmark.square.fill" : "square")
                        .foregroundStyle(viewModel.launchAtLogin ? .blue : .secondary)
                    Text("Launch at Login")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            Divider()

            Button("Quit Hush") {
                viewModel.teardown()
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }
}
