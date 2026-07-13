import AppKit
import SwiftUI

/// Owns the floating NSPanel. Non-activating: showing it never steals
/// focus from the app being dictated into.
@MainActor
final class HUDPanelController {
    private let panel: NSPanel
    private let hosting: NSHostingView<HUDView>
    private var expiryTask: Task<Void, Never>?

    init() {
        hosting = NSHostingView(rootView: HUDView(display: .hidden, maxRecordMs: 60_000))
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = hosting
    }

    func apply(_ display: HUDDisplay, maxRecordMs: Int64) {
        hosting.rootView = HUDView(display: display, maxRecordMs: maxRecordMs)

        switch display {
        case .hidden:
            fadeOut()
        default:
            position()
            fadeIn()
        }
    }

    /// One-shot expiry for the error flash; the closure re-enters the
    /// reducer via tick().
    func scheduleErrorExpiry(after seconds: TimeInterval, tick: @escaping @MainActor () -> Void) {
        expiryTask?.cancel()
        expiryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            tick()
        }
    }

    private func position() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 80
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func fadeIn() {
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in
            panel.orderOut(nil)
        })
    }
}
