import SwiftUI

struct AudioProcessRow: View {
    let process: AudioProcess
    let isMuted: Bool
    let onToggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = process.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .resizable()
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            Text(process.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(!process.isRunningOutput && isMuted ? 0.5 : 1)

            if !process.isRunningOutput && isMuted {
                Text("paused")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .foregroundStyle(isMuted ? .red : .secondary)
                .font(.body)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(process.name), \(isMuted ? "muted" : "playing")")
        .accessibilityHint("Click to \(isMuted ? "unmute" : "mute")")
        .accessibilityAddTraits(.isButton)
    }
}
