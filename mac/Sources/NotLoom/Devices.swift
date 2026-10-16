import AppKit
import AVFoundation

enum Devices {
    static func cameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .continuityCamera, .external],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    static func microphones() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    /// The device for a saved choice, or nil when the user picked "none".
    /// Falls back to the system default if the saved device is unplugged.
    static func resolve(_ id: String?, mediaType: AVMediaType) -> AVCaptureDevice? {
        if id == Settings.none { return nil }
        if let id, let device = AVCaptureDevice(uniqueID: id) { return device }
        return AVCaptureDevice.default(for: mediaType)
    }
}

/// An on-screen window that can be recorded on its own.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let title: String
    /// Global screen coordinates, origin at the top left of the main display.
    let frame: CGRect

    static func onScreen() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier

        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.width >= 160, frame.height >= 120
            else { return nil }
            let owner = info[kCGWindowOwnerName as String] as? String ?? "Window"
            let name = info[kCGWindowName as String] as? String ?? ""
            let title = name.isEmpty ? owner : "\(owner) — \(name)"
            return WindowInfo(id: id, pid: pid, title: title, frame: frame)
        }
    }

    /// The window's frame in AppKit coordinates (origin at the bottom left).
    var appKitFrame: NSRect { Self.appKitRect(frame) }

    /// Converts a global screen rect (origin top left of the main display) to AppKit's
    /// coordinates (origin bottom left).
    static func appKitRect(_ rect: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// The window's current frame, or nil if it's gone.
    static func currentFrame(of id: CGWindowID) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let bounds = list.first?[kCGWindowBounds as String] as? NSDictionary
        else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }
}
