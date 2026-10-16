import AppKit
import AVFoundation

/// Owns the menu bar item and drives a recording from start to the trim window.
///
/// Idle: clicking the icon opens the menu (and shows your camera bubble as a preview).
/// Recording: the menu bar item turns into a red "■ 02:14" with a level meter,
/// and clicking it stops and saves.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase { case idle, countdown, recording, stopping }

    private var phase = Phase.idle
    private var statusItem: NSStatusItem!
    private let settings = Settings.shared
    private let meter = MicMeter()
    private let bubble = CameraBubble()
    private let recorder = Recorder()
    private let countdown = Countdown()
    private let recordingFrame = RecordingFrame()
    private let levelView = LevelMenuView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
    private var tickTimer: Timer?
    private var micDevice: AVCaptureDevice?
    /// Window recordings: the window and the part of the screen being captured
    /// (global coordinates, origin top left).
    private var trackedWindow: (id: CGWindowID, crop: CGRect)?
    private var trimWindows: [TrimWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        recorder.onFinished = { [weak self] result in self?.recordingFinished(result) }
        updateStatusItem()

        AVCaptureDevice.requestAccess(for: .video) { _ in }
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
    }

    // MARK: Menu bar item

    @objc private func statusItemClicked() {
        switch phase {
        case .idle: showMenu()
        case .countdown: countdown.cancel()
        case .recording: stopRecording()
        case .stopping: break
        }
    }

    private func showMenu() {
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil) // opens the menu and blocks until it closes
        statusItem.menu = nil
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        switch phase {
        case .idle, .stopping:
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "not-loom")
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            button.toolTip = phase == .stopping ? "Saving…" : "not-loom"

        case .countdown:
            button.image = nil
            button.imagePosition = .noImage
            button.attributedTitle = redTitle("● Starting…")
            button.toolTip = "Click to cancel"

        case .recording:
            let seconds = Int(Date().timeIntervalSince(recorder.startedAt ?? Date()))
            let time = String(format: "%02d:%02d", seconds / 60, seconds % 60)
            button.image = LevelGlyph.image(level: micDevice == nil ? 0 : meter.level)
            button.imagePosition = .imageTrailing
            button.attributedTitle = redTitle("■ \(time) ")
            button.toolTip = "Click to stop & save"
        }
    }

    private func redTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
        ])
    }

    // MARK: Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(item("Record Full Screen", #selector(recordFullScreen)))

        let windows = NSMenu()
        let list = WindowInfo.onScreen()
        if list.isEmpty {
            let empty = item("No windows found", nil)
            empty.isEnabled = false
            windows.addItem(empty)
        }
        for window in list {
            let title = window.title.count > 70 ? String(window.title.prefix(69)) + "…" : window.title
            let entry = item(title, #selector(recordWindow(_:)))
            entry.tag = Int(window.id)
            windows.addItem(entry)
        }
        menu.addItem(submenu("Record a Window", windows))

        menu.addItem(.separator())
        let level = NSMenuItem()
        level.view = levelView
        menu.addItem(level)

        menu.addItem(deviceMenu(
            "Camera", devices: Devices.cameras(), saved: settings.cameraID, mediaType: .video,
            noneTitle: "No Camera", action: #selector(pickCamera(_:))
        ))
        menu.addItem(deviceMenu(
            "Microphone", devices: Devices.microphones(), saved: settings.micID, mediaType: .audio,
            noneTitle: "No Microphone (silent video)", action: #selector(pickMic(_:))
        ))

        let bubbleMenu = NSMenu()
        for corner in BubbleCorner.allCases {
            let entry = item(corner.title, #selector(pickCorner(_:)), on: settings.bubbleCenter == nil && corner == settings.corner)
            entry.representedObject = corner.rawValue
            bubbleMenu.addItem(entry)
        }
        bubbleMenu.addItem(.separator())
        for size in BubbleSize.allCases {
            let entry = item(size.title, #selector(pickSize(_:)), on: size == settings.size)
            entry.representedObject = size.rawValue
            bubbleMenu.addItem(entry)
        }
        menu.addItem(submenu("Camera Bubble", bubbleMenu))

        menu.addItem(.separator())
        menu.addItem(item("3-2-1 Countdown", #selector(toggleCountdown), on: settings.countdown))
        menu.addItem(item("Record Computer Audio", #selector(toggleSystemAudio), on: settings.systemAudio))

        menu.addItem(.separator())
        menu.addItem(item("Open Recordings Folder", #selector(openRecordingsFolder)))
        menu.addItem(item("Quit not-loom", #selector(quit), key: "q"))
        return menu
    }

    private func item(_ title: String, _ action: Selector?, on: Bool = false, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private func deviceMenu(
        _ title: String, devices: [AVCaptureDevice], saved: String?, mediaType: AVMediaType,
        noneTitle: String, action: Selector
    ) -> NSMenuItem {
        let current = Devices.resolve(saved, mediaType: mediaType)?.uniqueID ?? Settings.none
        let menu = NSMenu()
        for device in devices {
            let entry = item(device.localizedName, action, on: device.uniqueID == current)
            entry.representedObject = device.uniqueID
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let none = item(noneTitle, action, on: current == Settings.none)
        none.representedObject = Settings.none
        menu.addItem(none)

        let parent = submenu(title, menu)
        let currentName = devices.first { $0.uniqueID == current }?.localizedName ?? "None"
        parent.title = "\(title): \(currentName)"
        return parent
    }

    func menuWillOpen(_ menu: NSMenu) {
        guard phase == .idle else { return }
        micDevice = Devices.resolve(settings.micID, mediaType: .audio)
        meter.use(micDevice)
        startTicking()
        // Preview the bubble where it will appear.
        if let camera = Devices.resolve(settings.cameraID, mediaType: .video) {
            bubble.show(device: camera, corner: settings.corner, size: settings.size, in: screenUnderMouse().visibleFrame)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        // Runs after a picked menu item's action, so starting a recording keeps the bubble up.
        Task { @MainActor in
            guard self.phase == .idle else { return }
            self.meter.stop()
            self.stopTicking()
            self.bubble.hide()
        }
    }

    // MARK: Menu actions

    @objc private func recordFullScreen() {
        let screen = screenUnderMouse()
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = screen.deviceDescription[key] as? CGDirectDisplayID ?? CGMainDisplayID()
        startRecording(.display(displayID), recordArea: screen.frame, bubbleArea: screen.visibleFrame)
    }

    @objc private func recordWindow(_ sender: NSMenuItem) {
        let id = CGWindowID(sender.tag)
        guard let window = WindowInfo.onScreen().first(where: { $0.id == id }) else {
            showAlert("That window has closed", "Open the menu again to pick another.")
            return
        }
        NSRunningApplication(processIdentifier: window.pid)?.activate()

        // Keep the bubble on the visible part of the window, clear of the Dock.
        let frame = window.appKitFrame
        let screen = NSScreen.screens.first { NSPointInRect(NSPoint(x: frame.midX, y: frame.midY), $0.frame) }
        let visible = frame.intersection(screen?.visibleFrame ?? frame)
        trackedWindow = (id, window.frame)
        startRecording(.window(id), recordArea: frame, bubbleArea: visible.isEmpty ? frame : visible)
    }

    @objc private func pickCamera(_ sender: NSMenuItem) {
        settings.cameraID = sender.representedObject as? String
    }

    @objc private func pickMic(_ sender: NSMenuItem) {
        settings.micID = sender.representedObject as? String
    }

    @objc private func pickCorner(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let corner = BubbleCorner(rawValue: raw) {
            settings.corner = corner
            settings.bubbleCenter = nil // forget where it was dragged
        }
    }

    @objc private func pickSize(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let size = BubbleSize(rawValue: raw) {
            settings.size = size
        }
    }

    @objc private func toggleCountdown() {
        settings.countdown.toggle()
    }

    @objc private func toggleSystemAudio() {
        settings.systemAudio.toggle()
    }

    @objc private func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: settings.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.recordingsFolder)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: Recording

    /// - Parameters:
    ///   - recordArea: what ends up in the video, outlined in red while recording.
    ///   - bubbleArea: where the camera bubble goes (a screen's area minus the Dock, or the window).
    private func startRecording(_ target: CaptureTarget, recordArea: NSRect, bubbleArea: NSRect) {
        guard phase == .idle else { return }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            showAlert(
                "Allow screen recording",
                "Turn on not-loom in System Settings → Privacy & Security → Screen & System Audio Recording, then quit and reopen not-loom."
            )
            return
        }

        phase = .countdown
        updateStatusItem()

        let camera = Devices.resolve(settings.cameraID, mediaType: .video)
        micDevice = Devices.resolve(settings.micID, mediaType: .audio)
        if let camera {
            bubble.show(device: camera, corner: settings.corner, size: settings.size, in: bubbleArea)
        } else {
            bubble.hide()
        }
        if case .window = target {
            recordingFrame.show(around: recordArea, isWindow: true)
        } else {
            recordingFrame.show(around: recordArea, isWindow: false)
        }
        meter.use(micDevice)
        startTicking()

        Task {
            if settings.countdown {
                let screen = NSScreen.screens.first { $0.frame.intersects(bubbleArea) } ?? screenUnderMouse()
                guard await countdown.run(on: screen) else {
                    resetToIdle()
                    return
                }
            } else {
                try? await Task.sleep(for: .milliseconds(700)) // let the camera warm up
            }

            do {
                let folder = settings.recordingsFolder
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(fileName())
                try await recorder.start(
                    target,
                    bubble: camera == nil ? nil : bubble.windowID,
                    excluding: [recordingFrame.windowID],
                    mic: micDevice,
                    systemAudio: settings.systemAudio,
                    to: url
                )
                phase = .recording
                updateStatusItem()
            } catch {
                resetToIdle()
                showAlert("Couldn't start recording", error.localizedDescription)
            }
        }
    }

    private func stopRecording() {
        guard phase == .recording else { return }
        phase = .stopping
        updateStatusItem()
        Task { await recorder.stop() }
    }

    private func recordingFinished(_ result: Result<URL, Error>) {
        resetToIdle()
        switch result {
        case .success(let url):
            let trim = TrimWindowController(url: url)
            trimWindows.append(trim)
            trim.show { [weak self, weak trim] in
                self?.trimWindows.removeAll { $0 === trim }
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        case .failure(let error):
            showAlert("Recording failed", error.localizedDescription)
        }
    }

    private func resetToIdle() {
        phase = .idle
        trackedWindow = nil
        bubble.hide()
        recordingFrame.hide()
        meter.stop()
        stopTicking()
        updateStatusItem()
    }

    private func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "not-loom \(formatter.string(from: Date())).mp4"
    }

    // MARK: Meter

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 0.08, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common) // keeps running while the menu is open
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    @objc private func tick() {
        levelView.level = micDevice == nil ? 0 : meter.level
        if micDevice == nil {
            levelView.status = settings.systemAudio ? "No mic · recording computer audio only" : "No audio — this video will be silent"
            levelView.tone = .off
        } else if meter.isHearingAudio {
            levelView.status = "Picking up audio"
            levelView.tone = .ok
        } else {
            levelView.status = "Silent — say something to test"
            levelView.tone = .warn
        }
        if phase == .recording { updateStatusItem() }
        if phase == .countdown || phase == .recording { followRecordedWindow() }
    }

    /// If the recorded window moves, move the capture, the red outline and the bubble with it.
    private func followRecordedWindow() {
        guard let tracked = trackedWindow,
              let frame = WindowInfo.currentFrame(of: tracked.id),
              frame.origin != tracked.crop.origin
        else { return }
        let crop = CGRect(origin: frame.origin, size: tracked.crop.size)
        trackedWindow = (tracked.id, crop)
        let area = WindowInfo.appKitRect(crop)
        recordingFrame.show(around: area, isWindow: true)
        bubble.follow(area)
        recorder.moveCrop(to: crop)
    }

    // MARK: Helpers

    private func screenUnderMouse() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
