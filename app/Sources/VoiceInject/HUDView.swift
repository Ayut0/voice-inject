import SwiftUI

struct HUDView: View {
    let display: HUDDisplay
    let maxRecordMs: Int64

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .fixedSize()
    }

    @ViewBuilder
    private var content: some View {
        switch display {
        case .hidden:
            EmptyView()

        case .recording(let started):
            HStack(spacing: 10) {
                PulsingDot()
                TimelineView(.animation(minimumInterval: 0.05)) { context in
                    let elapsed = context.date.timeIntervalSince(started)
                    let fraction = min(elapsed / (Double(maxRecordMs) / 1000.0), 1.0)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "Recording  %.1fs", elapsed))
                            .font(.caption.monospacedDigit())
                        ProgressView(value: fraction)
                            .frame(width: 140)
                    }
                }
            }

        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Transcribing…").font(.caption)
            }

        case .errorFlash(let message, _):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: 260)
            }
        }
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(.red)
            .frame(width: 12, height: 12)
            .scaleEffect(pulsing ? 1.35 : 0.85)
            .opacity(pulsing ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
