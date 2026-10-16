import AppKit

/// A red outline around whatever is being recorded. It's kept out of the video.
@MainActor
final class RecordingFrame {
    private let panel: NSPanel
    private let lineWidth: CGFloat = 4

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.systemRed.cgColor
        view.layer?.borderWidth = lineWidth
        panel.contentView = view
    }

    /// Outlines `area` (AppKit coordinates). Around a window the line sits just
    /// outside its edges; around a whole screen it runs along the inside edge.
    func show(around area: NSRect, isWindow: Bool) {
        let frame = isWindow ? area.insetBy(dx: -lineWidth, dy: -lineWidth) : area
        panel.setFrame(frame, display: true)
        panel.contentView?.layer?.cornerRadius = isWindow ? 14 : 0
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
