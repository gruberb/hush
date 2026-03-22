import SwiftUI

struct AudioProcessRow: View {
    let process: AudioProcess
    let volume: Float
    let onToggleMute: () -> Void
    let onVolumeChange: (Float) -> Void

    @State private var isHovering = false

    private var speakerIcon: String {
        if volume <= 0 { return "speaker.slash.fill" }
        if volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var speakerColor: Color {
        if volume <= 0 { return .red }
        if volume < 1.0 { return .orange }
        return .secondary
    }

    var body: some View {
        VStack(spacing: 2) {
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
                    .opacity(!process.isRunningOutput && volume < 1.0 ? 0.5 : 1)

                if !process.isRunningOutput && volume < 1.0 {
                    Text("paused")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Button(action: onToggleMute) {
                    Image(systemName: speakerIcon)
                        .foregroundStyle(speakerColor)
                        .font(.body)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                Spacer().frame(width: 32)
                Slider(
                    value: Binding(
                        get: { Double(volume) },
                        set: { onVolumeChange(Float($0)) }
                    ),
                    in: 0...1
                )
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isHovering ? Color.primary.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(process.name), volume \(Int(volume * 100)) percent")
    }
}
