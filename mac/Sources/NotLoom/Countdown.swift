import AppKit

/// The 3-2-1 shown before recording starts. It's gone before capture begins,
/// so it never appears in the video.
@MainActor
final class Countdown {
    private var cancelled = false

    /// Returns false if it was cancelled.
    func run(from seconds: Int = 3, on screen: NSScreen) async -> Bool {
        cancelled = false
        let side: CGFloat = 200
        let frame = NSRect(x: screen.frame.midX - side / 2, y: screen.frame.midY - side / 2, width: side, height: side)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false

        let box = NSView(frame: NSRect(x: 0, y: 0, width: side, height: side))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        box.layer?.cornerRadius = 40
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 110, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 28, width: side, height: 140)
        box.addSubview(label)
        panel.contentView = box
        panel.orderFrontRegardless()

        for n in stride(from: seconds, through: 1, by: -1) {
            label.stringValue = "\(n)"
            try? await Task.sleep(for: .seconds(1))
            if cancelled { break }
        }
        panel.orderOut(nil)
        return !cancelled
    }

    func cancel() {
        cancelled = true
    }
}
