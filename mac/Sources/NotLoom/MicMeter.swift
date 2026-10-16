import AVFoundation

/// Listens to one microphone and reports how loud it is, for the level meter.
final class MicMeter: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    /// Anything louder than this counts as "picking up audio".
    static let heardThreshold: Float = -50

    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "not-loom.mic-meter")
    private let lock = NSLock()
    private var power: Float = -160
    private var heardAt = Date.distantPast

    /// 0...1, mapped from -60 dB...0 dB.
    var level: Float {
        lock.withLock { max(0, min(1, (power + 60) / 60)) }
    }

    var isHearingAudio: Bool {
        lock.withLock { Date().timeIntervalSince(heardAt) < 1.5 }
    }

    /// Starts metering `device`, or stops when it's nil.
    func use(_ device: AVCaptureDevice?) {
        queue.async { [self] in
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.outputs.forEach(session.removeOutput)
            if let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                let output = AVCaptureAudioDataOutput()
                output.setSampleBufferDelegate(self, queue: queue)
                if session.canAddOutput(output) { session.addOutput(output) }
            }
            session.commitConfiguration()

            if session.inputs.isEmpty {
                session.stopRunning()
                reset()
            } else if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            session.stopRunning()
            reset()
        }
    }

    private func reset() {
        lock.withLock {
            power = -160
            heardAt = .distantPast
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let loudest = connection.audioChannels.map(\.averagePowerLevel).max() ?? -160
        lock.withLock {
            power = loudest
            if loudest > Self.heardThreshold { heardAt = Date() }
        }
    }
}
