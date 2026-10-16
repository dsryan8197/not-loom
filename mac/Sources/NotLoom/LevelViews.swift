import AppKit

/// The audio meter shown inside the menu: a row of segments and a status line.
final class LevelMenuView: NSView {
    enum Tone { case ok, warn, off }

    var level: Float = 0 { didSet { if level != oldValue { needsDisplay = true } } }
    var status = "" { didSet { if status != oldValue { needsDisplay = true } } }
    var tone = Tone.off { didSet { if tone != oldValue { needsDisplay = true } } }

    override func draw(_ dirtyRect: NSRect) {
        let segments = 20
        let gap: CGFloat = 2
        let left: CGFloat = 21 // lines up with menu item titles
        let width = bounds.width - left - 14
        let segmentWidth = (width - gap * CGFloat(segments - 1)) / CGFloat(segments)

        for i in 0..<segments {
            let lit = Float(i) / Float(segments) < level
            let color: NSColor
            if !lit { color = .quaternaryLabelColor }
            else if i < 14 { color = .systemGreen }
            else if i < 17 { color = .systemYellow }
            else { color = .systemRed }
            color.setFill()
            let rect = NSRect(x: left + CGFloat(i) * (segmentWidth + gap), y: bounds.height - 14, width: segmentWidth, height: 6)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }

        let color: NSColor
        switch tone {
        case .ok: color = .systemGreen
        case .warn: color = .systemOrange
        case .off: color = .secondaryLabelColor
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: color,
        ]
        (status as NSString).draw(at: NSPoint(x: left, y: 5), withAttributes: attributes)
    }
}

/// Little level bars shown next to the timer in the menu bar while recording.
enum LevelGlyph {
    static func image(level: Float) -> NSImage {
        let heights: [CGFloat] = [4, 6, 8, 10, 12]
        let image = NSImage(size: NSSize(width: 17, height: 16), flipped: false) { _ in
            for (i, height) in heights.enumerated() {
                let lit = level > Float(i) / Float(heights.count) + 0.02
                NSColor.black.withAlphaComponent(lit ? 1 : 0.3).setFill()
                let rect = NSRect(x: 1 + CGFloat(i) * 3.2, y: 2, width: 2.2, height: height)
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
