import AppKit
import AVFoundation

/// A round, always-on-top window showing the camera. It sits on the real screen,
/// so the screen recording picks it up along with everything else.
///
/// It always stays inside `area`, the part of the screen being recorded, so
/// wherever you see it is where it is in the video. Drag it to move it.
@MainActor
final class CameraBubble {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "not-loom.camera")
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let panel: NSPanel
    private var deviceID: String?
    private var area = NSRect.zero
    private var diameter: CGFloat = 0

    var windowID: CGWindowID { CGWindowID(panel.windowNumber) }

    init() {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        // Panels hide when their app isn't frontmost by default, which made the
        // bubble vanish as soon as you switched to the app you were recording.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(previewLayer)
        view.onMove = { [weak self] origin in
            guard let self else { return }
            panel.setFrameOrigin(clamped(origin))
        }
        view.onDragEnded = { [weak self] in self?.rememberPosition() }
        panel.contentView = view
    }

    /// Shows the bubble inside `area` (AppKit screen coordinates): where you last
    /// dragged it, or else in the chosen corner.
    func show(device: AVCaptureDevice, corner: BubbleCorner, size: BubbleSize, in area: NSRect) {
        use(device)
        self.area = area
        diameter = min((area.height * size.fraction).rounded(), area.width, area.height)

        var origin: NSPoint
        if let center = Settings.shared.bubbleCenter {
            origin = NSPoint(
                x: area.minX + center.x * area.width - diameter / 2,
                y: area.minY + center.y * area.height - diameter / 2
            )
        } else {
            let margin = (area.height * 0.03).rounded()
            origin = NSPoint(
                x: corner.isLeft ? area.minX + margin : area.maxX - margin - diameter,
                y: corner.isTop ? area.maxY - margin - diameter : area.minY + margin
            )
        }
        panel.setFrame(NSRect(origin: clamped(origin), size: NSSize(width: diameter, height: diameter)), display: true)

        if let layer = panel.contentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.cornerRadius = diameter / 2
            layer.borderWidth = max(3, diameter * 0.025)
            previewLayer.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
            CATransaction.commit()
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
    }

    /// Moves the bubble along with the recorded area, keeping its spot within it.
    func follow(_ newArea: NSRect) {
        guard panel.isVisible, area.width > 0, area.height > 0, newArea != area else { return }
        let frame = panel.frame
        let x = (frame.midX - area.minX) / area.width
        let y = (frame.midY - area.minY) / area.height
        area = newArea
        panel.setFrameOrigin(clamped(NSPoint(
            x: newArea.minX + x * newArea.width - diameter / 2,
            y: newArea.minY + y * newArea.height - diameter / 2
        )))
    }

    func hide() {
        panel.orderOut(nil)
        queue.async { [session] in session.stopRunning() }
    }

    /// Keeps the whole bubble inside the recorded area.
    private func clamped(_ origin: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, area.minX), area.maxX - diameter),
            y: min(max(origin.y, area.minY), area.maxY - diameter)
        )
    }

    private func rememberPosition() {
        guard area.width > 0, area.height > 0 else { return }
        let frame = panel.frame
        Settings.shared.bubbleCenter = CGPoint(
            x: (frame.midX - area.minX) / area.width,
            y: (frame.midY - area.minY) / area.height
        )
    }

    private func use(_ device: AVCaptureDevice) {
        let changed = device.uniqueID != deviceID
        deviceID = device.uniqueID
        let layer = previewLayer
        queue.async { [session] in
            if changed {
                session.beginConfiguration()
                session.inputs.forEach(session.removeInput)
                if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                    session.addInput(input)
                }
                if session.canSetSessionPreset(.high) { session.sessionPreset = .high }
                session.commitConfiguration()
            }
            if !session.isRunning { session.startRunning() }
            DispatchQueue.main.async {
                // Mirror it, like looking in a mirror.
                if let connection = layer.connection, connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = true
                }
            }
        }
    }
}

/// The bubble's content view: drag it to move the bubble.
private final class BubbleView: NSView {
    var onMove: ((NSPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    private var mouseStart = NSPoint.zero
    private var originStart = NSPoint.zero

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        mouseStart = NSEvent.mouseLocation
        originStart = window?.frame.origin ?? .zero
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        onMove?(NSPoint(x: originStart.x + mouse.x - mouseStart.x, y: originStart.y + mouse.y - mouseStart.y))
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
        onDragEnded?()
    }
}
