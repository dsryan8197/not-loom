# not-loom for Mac

A native menu bar app (Swift, ScreenCaptureKit) that records your screen with your camera in a round bubble.

- **Click the menu bar icon** to pick a camera, a microphone, the bubble's corner and size, and whether to record computer audio. A live **audio meter** shows whether the mic is picking you up. Your camera bubble appears as a preview while the menu is open.
- **Record Full Screen** records the screen your mouse is on. **Record a Window** records just one window, with the bubble in its corner.
- **While recording, the menu bar item is the Stop button.** It shows a red `■ 02:14` and a small level meter. Click it to stop and save.
- **A red outline marks what's being recorded**: around the window, or along the edges of the screen. Your camera bubble stays on screen exactly where it appears in the video, so you can see if it's covering something. The outline isn't in the video; the bubble is.
- **After you stop**, a window opens with trim handles. Drag them to cut the start and end, then click **Trim**, or click **Cancel** to keep everything. The video is saved to `~/Movies/not-loom/` as an H.264 `.mp4` that opens in QuickTime.

Requires **macOS 15 (Sequoia) or later**.

## Build and install

You need Xcode 16 or later (or its Command Line Tools: `xcode-select --install`).

```sh
cd mac
./scripts/build-app.sh --install
```

This builds `not-loom.app`, copies it to `/Applications` and opens it. Look for the ⏺ icon in your menu bar.

The first time you record, macOS asks you to allow screen recording. Turn on not-loom in **System Settings → Privacy & Security → Screen & System Audio Recording**, then quit and reopen not-loom. Camera and microphone access are asked for on first launch.

### Keeping the screen recording permission across rebuilds

macOS ties that permission to the app's code signature. The build script signs with your **Apple Development** certificate if it finds one, and then the permission sticks. To get one, open Xcode → Settings → Accounts, add your Apple ID and click Manage Certificates → + → Apple Development. Without a certificate the app is signed ad hoc, and after each rebuild you may need to toggle the permission off and on again.

### Prebuilt app from GitHub

Every push that touches `mac/` builds the app on GitHub Actions (the **Mac app** workflow) and attaches `not-loom-app` (a zip) to the run. That build is signed ad hoc, so macOS will block it the first time you open it. Right-click the app → **Open**, or run `xattr -dr com.apple.quarantine /Applications/not-loom.app`.

## How it works

- `CameraBubble.swift`: a borderless, always-on-top circular window showing the camera. Because it's a real window on screen, the screen capture records it, the same way Loom does it.
- `Recorder.swift`: ScreenCaptureKit streams the display (or one window plus the bubble) and writes it with `SCRecordingOutput`, which also records the microphone and, if you choose, computer audio, straight to MP4.
- `MicMeter.swift`: a small `AVCaptureSession` that reads the mic's power level for the meters.
- `AppDelegate.swift`: the menu, the menu bar timer, and the countdown → record → trim flow.
- `TrimWindow.swift`: `AVPlayerView`'s built-in trimming UI, then a lossless passthrough export over the original file.

## Not in this version

There's no pause or mute while recording, and no camera-only mode.
