# not-loom (browser version)

A local, Loom-style recorder for demo videos: your screen with your camera in a round bubble, a live audio meter, and a Stop button that stays on screen while you record. It runs in your browser, has no dependencies or accounts, and doesn't upload anything.

## Run it

```sh
cd web
npm start          # or: node server.js
```

This opens <http://127.0.0.1:4321> in your browser. On a Mac you can also double-click **`not-loom.command`** in Finder. If you don't have Node.js, it falls back to Python.

**Use Chrome (or Edge).** Safari and Firefox can record too, but only Chrome-based browsers can show the floating Stop window.

### First run on macOS

macOS has to allow the browser to see your screen:

1. **System Settings → Privacy & Security → Screen & System Audio Recording** → turn on Google Chrome.
2. Quit and reopen Chrome.
3. When the page asks, allow camera and microphone.

## Using it

1. Pick a **camera** and a **microphone**. To record without sound, pick **"No microphone"**.
2. Watch the **audio meter**. It turns green and says *Picking up audio* when you talk. If it says *Silent*, you've picked the wrong mic.
3. Choose where the camera bubble goes (↖ ↗ ↙ ↘) and how big it is (S/M/L).
4. Click **Start recording**, then pick the screen, window or tab to share. A 3-2-1 countdown runs.
5. A small **floating window** opens and stays above every app. It has the timer, the audio meter, Pause, Mute and a red **Stop & save** button.
6. Click **Stop & save**. The video goes to your Downloads folder as `not-loom <date> at <time>.mp4`.

Other ways to stop: press <kbd>Esc</kbd> while the floating window or the not-loom tab has focus, use Chrome's own **Stop sharing** bar, or click Stop in the not-loom tab. <kbd>P</kbd> pauses and resumes. <kbd>M</kbd> mutes the mic.

Your settings (devices, bubble position and size, checkboxes) are remembered.

## Good to know

- **The floating window can show up in the video** if you share your *entire screen*. Drag it into a corner you won't record over, or share a single window or tab. Then it won't show up at all.
- **File format**: Chrome on macOS writes H.264/AAC `.mp4`, which plays in QuickTime and uploads anywhere. Browsers without H.264 encoding write `.webm`, which plays in Chrome and VLC.
- **Computer audio**: tick *Also record computer / tab audio*. Sharing a tab always works. Capturing a whole screen's or another app's audio depends on your Chrome and macOS versions.
- The camera is drawn **mirrored**, like a mirror, the way Loom shows it.
- Very large screens are scaled down to 2560px wide to keep files a sensible size.

## How it works

```
screen (getDisplayMedia) ─┐
                           ├─> drawn onto a <canvas> each frame ─> canvas.captureStream() ─┐
camera (getUserMedia) ────┘                                                                ├─> MediaRecorder ─> .mp4/.webm
mic + optional tab audio ─> Web Audio mix ─> MediaStreamDestination ───────────────────────┘
                                   └─> AnalyserNode ─> level meter
```

- `public/app.js`: everything (devices, meter, compositing, recording, floating controls)
- `public/index.html`, `public/style.css`: the UI
- `server.js`: a tiny static server. Browsers only allow camera, mic and screen capture on `https://` or localhost, so you can't just open the HTML file.

The floating controls use Chrome's [Document Picture-in-Picture API](https://developer.chrome.com/docs/web-platform/document-picture-in-picture). Frames are read with `MediaStreamTrackProcessor`, and a Web Worker drives the frame loop, so recording stays smooth while the tab is hidden behind the app you're demoing.

## Ideas for later

- Show your camera in the floating window so you can see yourself while you record
- Trim the start and end before saving
- Pick a save folder (File System Access API) instead of Downloads
- Wrap it in Electron or Tauri to get a global hotkey and keep the controls out of full-screen recordings
