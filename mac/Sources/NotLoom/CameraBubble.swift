import AppKit
import AVFoundation

/// A round, always-on-top window showing the camera. It sits on the real screen,
/// so the screen recording picks it up along with everything else.
@MainActor
final class CameraBubble {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "not-loom.camera")
    private let previewLayer: AVCaptureVideoPreviewLayer
    private let panel: NSPanel
    private var deviceID: String?

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
        panel.ignoresMouseEvents = true
        // Panels hide when their app isn't frontmost by default, which made the
        // bubble vanish as soon as you switched to the app you were recording.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        view.autoresizingMask = [.width, .height]
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(previewLayer)
        panel.contentView = view
    }

    /// Shows the bubble in a corner of `area` (AppKit screen coordinates).
    func show(device: AVCaptureDevice, corner: BubbleCorner, size: BubbleSize, in area: NSRect) {
        use(device)

        let diameter = (area.height * size.fraction).rounded()
        let margin = (area.height * 0.03).rounded()
        let x = corner.isLeft ? area.minX + margin : area.maxX - margin - diameter
        let y = corner.isTop ? area.maxY - margin - diameter : area.minY + margin
        panel.setFrame(NSRect(x: x, y: y, width: diameter, height: diameter), display: true)

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

    func hide() {
        panel.orderOut(nil)
        queue.async { [session] in session.stopRunning() }
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
