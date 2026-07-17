import SwiftUI

struct HUDView: View {
    /// Transparent margin around the pill so `.shadow(radius: 34, y: 12)`
    /// has room to render — `HUDPanelController` sizes the panel exactly
    /// to `fittingSize`, so anything drawn past the pill's own bounds
    /// would otherwise be clipped. `HUDPanelController.position()` shifts
    /// the frame origin by this same amount to keep the pill itself
    /// anchored at its original on-screen position.
    static let shadowInset: CGFloat = 48

    let display: HUDDisplay
    let maxRecordMs: Int64

    var body: some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 1)
            )
            .overlay(topHighlight)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .compositingGroup()
            .shadow(color: .black.opacity(0.48), radius: 34, x: 0, y: 12)
            .fixedSize()
            .padding(Self.shadowInset)
    }

    private var borderColor: Color {
        if case .errorFlash = display {
            return Color(hex: 0xFFD60A).opacity(0.28)
        }
        return .white.opacity(0.13)
    }

    private var topHighlight: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.08), .clear],
                    startPoint: .top,
                    endPoint: .center
                ),
                lineWidth: 1
            )
    }

    @ViewBuilder
    private var content: some View {
        switch display {
        case .hidden:
            EmptyView()

        case .recording(let started):
            RecordingContent(started: started, maxRecordMs: maxRecordMs)

        case .working:
            HStack(spacing: 10) {
                BreathingBars()
                Text("Transcribing…")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.88))
            }

        case .errorFlash(let message, _):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(hex: 0xFFD60A))
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.90))
                    .lineSpacing(2)
                    .lineLimit(2)
                    // Fixed (not max) width: under the outer pill's
                    // .fixedSize(), a maxWidth-only frame clamps the
                    // reported *width* to 260 without re-measuring height
                    // for the now-wrapped text, clipping the 2nd line.
                    // A fixed width forces wrapping during measurement.
                    .frame(width: 260, alignment: .leading)
            }
        }
    }
}

private struct RecordingContent: View {
    let started: Date
    let maxRecordMs: Int64

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let elapsed = context.date.timeIntervalSince(started)
            let fraction = min(elapsed / (Double(maxRecordMs) / 1000.0), 1.0)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    PulsingDot()
                    Text("Recording")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(String(format: "%.1fs", elapsed))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                }
                ProgressUnderline(fraction: fraction)
            }
        }
    }
}

private struct PulsingDot: View {
    @State private var pulsing = false
    private let color = Color(hex: 0xFF453A)

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .shadow(color: color, radius: 4)
            .scaleEffect(pulsing ? 0.78 : 1.0)
            .opacity(pulsing ? 0.3 : 1.0)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

private struct ProgressUnderline: View {
    let fraction: Double
    private let width: CGFloat = 140

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule()
                .fill(.white.opacity(0.15))
                .frame(width: width, height: 2)
            Capsule()
                .fill(.white.opacity(0.9))
                .frame(width: width * fraction, height: 2)
                .shadow(color: .white.opacity(0.6), radius: 3)
        }
    }
}

private struct BreathingBars: View {
    @State private var animate = false
    private let heights: [CGFloat] = [11, 16, 11]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(0..<heights.count, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(animate ? 0.85 : 0.4))
                    .frame(width: 3, height: heights[index])
                    .animation(
                        .easeInOut(duration: 1.0)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
