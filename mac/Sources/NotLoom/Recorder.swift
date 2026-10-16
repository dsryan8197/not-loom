import AVFoundation
import ScreenCaptureKit

enum CaptureTarget {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

enum RecorderError: LocalizedError {
    case targetGone
    case emptyFile

    var errorDescription: String? {
        switch self {
        case .targetGone: return "That screen or window isn't available to record any more."
        case .emptyFile: return "The recording ended before anything was saved."
        }
    }
}

/// Records a display (or one window) plus the camera bubble, mic and optional
/// computer audio straight to an H.264 MP4, using ScreenCaptureKit.
@MainActor
final class Recorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    /// Called once per recording, when the file is finished (or failed).
    var onFinished: (@MainActor (Result<URL, Error>) -> Void)?
    private(set) var startedAt: Date?

    private var stream: SCStream?
    private var config: SCStreamConfiguration?
    private var displayFrame = CGRect.zero
    private var pendingCrop: CGRect?
    private var updatingCrop = false
    private var url: URL?
    private var finished = true
    private let frameQueue = DispatchQueue(label: "not-loom.frames")

    /// - Parameters:
    ///   - bubble: the camera bubble's window, so window recordings include it too.
    ///   - excluding: our own windows to keep out of full-screen recordings.
    func start(
        _ target: CaptureTarget, bubble: CGWindowID?, excluding: [CGWindowID],
        mic: AVCaptureDevice?, systemAudio: Bool, to url: URL
    ) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let config = SCStreamConfiguration()
        let filter: SCContentFilter

        switch target {
        case .display(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) ?? content.displays.first else {
                throw RecorderError.targetGone
            }
            let hidden = content.windows.filter { excluding.contains($0.windowID) }
            filter = SCContentFilter(display: display, excludingWindows: hidden)
            setSize(of: config, to: filter.contentRect.size, scale: CGFloat(filter.pointPixelScale))

        case .window(let id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecorderError.targetGone }
            let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) }) ?? content.displays.first else {
                throw RecorderError.targetGone
            }
            // Capture only that window and the bubble, cropped to the window.
            let bubbleWindows = content.windows.filter { $0.windowID == bubble }
            filter = SCContentFilter(display: display, including: [window] + bubbleWindows)
            let crop = window.frame
                .offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                .intersection(CGRect(origin: .zero, size: display.frame.size))
            config.sourceRect = crop
            displayFrame = display.frame
            setSize(of: config, to: crop.size, scale: CGFloat(filter.pointPixelScale))
        }

        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true
        config.queueDepth = 8
        config.capturesAudio = systemAudio
        config.excludesCurrentProcessAudio = true
        config.captureMicrophone = mic != nil
        config.microphoneCaptureDeviceID = mic?.uniqueID

        let recordingConfig = SCRecordingOutputConfiguration()
        recordingConfig.outputURL = url
        recordingConfig.outputFileType = .mp4
        recordingConfig.videoCodecType = .h264 // opens in QuickTime, Slack, browsers
        let recording = SCRecordingOutput(configuration: recordingConfig, delegate: self)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        try stream.addRecordingOutput(recording)

        self.url = url
        finished = false
        try await stream.startCapture()
        self.stream = stream
        self.config = config
        startedAt = Date()
    }

    /// Window recordings: moves the crop when the window moves. The size stays
    /// the same, so the video never stretches. Returns the area actually being
    /// captured (global coordinates), which stays on the display even if the
    /// window is dragged partly off it.
    @discardableResult
    func moveCrop(to rect: CGRect) -> CGRect? {
        guard stream != nil, let config else { return nil }
        let size = config.sourceRect.size
        // A crop that runs off the display makes ScreenCaptureKit stop the stream.
        let x = min(max(rect.minX - displayFrame.minX, 0), max(0, displayFrame.width - size.width))
        let y = min(max(rect.minY - displayFrame.minY, 0), max(0, displayFrame.height - size.height))
        let crop = CGRect(origin: CGPoint(x: x, y: y), size: size)
        pendingCrop = crop
        applyPendingCrop()
        return crop.offsetBy(dx: displayFrame.minX, dy: displayFrame.minY)
    }

    /// Sends crop changes one at a time; dragging a window produces a burst of
    /// them, and overlapping updates can stop the stream.
    private func applyPendingCrop() {
        guard !updatingCrop, let crop = pendingCrop, let stream, let config else { return }
        pendingCrop = nil
        updatingCrop = true
        config.sourceRect = crop
        Task {
            do {
                try await stream.updateConfiguration(config)
            } catch {
                NSLog("not-loom: couldn't follow the window: \(error.localizedDescription)")
            }
            updatingCrop = false
            applyPendingCrop()
        }
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        finishSoon()
    }

    private func setSize(of config: SCStreamConfiguration, to size: CGSize, scale: CGFloat) {
        var width = size.width * scale
        var height = size.height * scale
        let maxWidth: CGFloat = 3840 // H.264 tops out around 4K
        if width > maxWidth {
            height *= maxWidth / width
            width = maxWidth
        }
        config.width = max(2, Int((width / 2).rounded()) * 2)
        config.height = max(2, Int((height / 2).rounded()) * 2)
    }

    /// The recording output normally reports when the file is done. If it doesn't
    /// (for example the system stopped the capture), use whatever was written.
    private func finishSoon(_ error: Error? = nil) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            self.complete(error: error)
        }
    }

    private func complete(error: Error?, failed: Bool = false) {
        guard !finished, let url else { return }
        finished = true
        startedAt = nil
        stream = nil
        config = nil
        pendingCrop = nil
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if failed || size == 0 {
            onFinished?(.failure(error ?? RecorderError.emptyFile))
        } else {
            onFinished?(.success(url))
        }
    }

    // MARK: SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // Frames go to the recording output; nothing to do with them here.
    }

    // MARK: SCStreamDelegate

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        // Also called when you stop sharing from macOS's own menu bar indicator.
        Task { @MainActor in
            self.stream = nil
            self.finishSoon(error)
        }
    }

    // MARK: SCRecordingOutputDelegate

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in self.complete(error: nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.complete(error: error, failed: true) }
    }
}
