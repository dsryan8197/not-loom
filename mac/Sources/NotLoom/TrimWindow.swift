import AppKit
import AVKit

/// Opens after you stop: plays the recording with QuickTime-style trim handles.
/// "Trim" cuts the start and end; "Cancel" keeps the whole thing.
@MainActor
final class TrimWindowController: NSObject, NSWindowDelegate {
    private let url: URL
    private let window: NSWindow
    private let playerView = AVPlayerView()
    private var onClose: (() -> Void)?

    init(url: URL) {
        self.url = url
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "Trim “\(url.deletingPathExtension().lastPathComponent)”"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 520, height: 340)
        playerView.player = AVPlayer(url: url)
        playerView.controlsStyle = .inline
        window.contentView = playerView
        window.center()
    }

    func show(onClose: @escaping () -> Void) {
        self.onClose = onClose
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        Task { await beginTrimming() }
    }

    private func beginTrimming() async {
        // The trim bar needs the video to be loaded first.
        var tries = 0
        while !playerView.canBeginTrimming && tries < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            tries += 1
        }
        guard playerView.canBeginTrimming else { return }
        playerView.beginTrimming { [weak self] result in
            Task { @MainActor in await self?.trimmingEnded(result) }
        }
    }

    private func trimmingEnded(_ result: AVPlayerViewTrimResult) async {
        defer { window.close() }
        guard result == .okButton, let item = playerView.player?.currentItem else { return }

        let duration = item.duration
        let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
        let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : duration
        guard start > .zero || end < duration else { return } // nothing trimmed

        let asset = AVURLAsset(url: url)
        guard let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return }
        exporter.timeRange = CMTimeRange(start: start, end: end)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".trimming-\(UUID().uuidString).mp4")

        do {
            try await exporter.export(to: temp, as: .mp4)
            playerView.player = nil // let go of the file before replacing it
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't trim the recording. The original is unchanged."
            alert.runModal()
        }
    }

    func windowWillClose(_ notification: Notification) {
        playerView.player?.pause()
        playerView.player = nil
        let callback = onClose
        onClose = nil
        callback?()
    }
}
