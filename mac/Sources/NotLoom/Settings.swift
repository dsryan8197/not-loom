import Foundation

enum BubbleCorner: String, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight

    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }

    var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    var isTop: Bool { self == .topLeft || self == .topRight }
}

enum BubbleSize: String, CaseIterable {
    case small, medium, large

    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }

    /// Diameter as a fraction of the recorded area's height.
    var fraction: CGFloat {
        switch self {
        case .small: return 0.2
        case .medium: return 0.28
        case .large: return 0.38
        }
    }
}

/// Choices remembered between launches.
final class Settings {
    static let shared = Settings()
    /// Stored as a device ID to mean "don't use one".
    static let none = "none"

    private let defaults = UserDefaults.standard

    /// nil = the system default camera, `Settings.none` = no camera.
    var cameraID: String? {
        get { defaults.string(forKey: "cameraID") }
        set { defaults.set(newValue, forKey: "cameraID") }
    }

    /// nil = the system default microphone, `Settings.none` = record without a mic.
    var micID: String? {
        get { defaults.string(forKey: "micID") }
        set { defaults.set(newValue, forKey: "micID") }
    }

    var corner: BubbleCorner {
        get { BubbleCorner(rawValue: defaults.string(forKey: "corner") ?? "") ?? .bottomRight }
        set { defaults.set(newValue.rawValue, forKey: "corner") }
    }

    var size: BubbleSize {
        get { BubbleSize(rawValue: defaults.string(forKey: "size") ?? "") ?? .medium }
        set { defaults.set(newValue.rawValue, forKey: "size") }
    }

    /// Where you last dragged the bubble, as a fraction of the recorded area
    /// (0,0 = bottom left). nil = use `corner`.
    var bubbleCenter: CGPoint? {
        get {
            guard let xy = defaults.array(forKey: "bubbleCenter") as? [Double], xy.count == 2 else { return nil }
            return CGPoint(x: xy[0], y: xy[1])
        }
        set {
            if let point = newValue {
                defaults.set([Double(point.x), Double(point.y)], forKey: "bubbleCenter")
            } else {
                defaults.removeObject(forKey: "bubbleCenter")
            }
        }
    }

    var countdown: Bool {
        get { defaults.object(forKey: "countdown") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "countdown") }
    }

    var systemAudio: Bool {
        get { defaults.bool(forKey: "systemAudio") }
        set { defaults.set(newValue, forKey: "systemAudio") }
    }

    var recordingsFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("not-loom", isDirectory: true)
    }
}
