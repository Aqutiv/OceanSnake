# Ocean Snake

Ocean Snake is a polished, responsive browser snake game built as a single HTML file. It has pointer-drag steering, mobile joystick controls, WASD keyboard movement, progressive gamepad and USB DualSense touchpad support, animated ocean visuals, sound and haptic controls, and a persistent best score stored in `localStorage`.

You can try a live playable version of this game here: https://html.cafe/x726e33d0

## Features

- Single-file game runtime in `index.html`
- Installable PWA metadata for Android and desktop browsers
- Offline cache through `service-worker.js` when served from a static HTTPS host
- Responsive desktop and mobile layout
- Mouse, touch, keyboard (WASD or arrow keys), and gamepad input
- Capability-detected mobile vibration, sequenced gamepad rumble, and an optional USB DualSense WebHID fallback
- Optional USB DualSense touchpad steering in Chromium browsers
- Pause, mute, haptics, and restart controls with keyboard shortcuts
- Local best-score and settings persistence
- Synthesized ambient music fallback when streaming audio is unavailable
- Local image assets in `assets/`
- HTML.cafe deployment script with optional asset inlining and WebP optimization

## Project Structure

```text
.
|-- index.html
|-- manifest.webmanifest
|-- service-worker.js
|-- assets/
|   |-- ocean-snake-logo-header.png
|   |-- ocean-snake-logo.ico
|   |-- ocean-snake-logo.png
|   |-- ocean-snake-mascot-source.png
|   |-- pwa-icon-192.png
|   |-- pwa-icon-512.png
|   |-- pwa-maskable-192.png
|   `-- pwa-maskable-512.png
|-- deploy-htmlcafe.ps1
|-- .gitignore
`-- README.md
```

## Run Locally

No install step is required. Open `index.html` directly in a browser.

For a local server, you can run:

```powershell
python -m http.server 8000
```

Then open:

```text
http://localhost:8000
```

## Controls

- Mouse or touch: drag the snake head
- Mobile: use the on-screen joystick
- Keyboard: `W`, `A`, `S`, `D` or the arrow keys
- Keyboard shortcuts: `Space` start/pause, `P` pause, `M` mute, `R` restart
- Gamepad: analog stick or D-pad
- DualSense: Cross starts or resumes, Options pauses, Square restarts, and Triangle toggles haptics
- USB DualSense touchpad: select **Enable DualSense touchpad**, then drag on the pad to steer relative to the snake's current position; each new touch re-anchors without moving the snake, and lifting your finger returns to coasting
- Buttons: pause, mute, haptics (when supported), restart

## Haptic Feedback

Haptics are enabled by default on supported devices and can be switched off independently from sound. Ordinary fish, combos, magic fish or color upgrades, invincibility warnings, and collisions use distinct sequenced feedback. The game prefers the standard Gamepad haptic actuator, uses an authorized USB DualSense WebHID connection as a compatible-vibration fallback, and otherwise uses the Vibration API on compatible mobile browsers.

Browsers that do not expose a haptic API continue without vibration and hide the haptics button. In particular, iPhone Safari does not currently provide a reliable web API for device vibration; an attached compatible gamepad can still provide rumble.

This browser-first implementation provides dual-actuator tactile patterns, not PlayStation-native PCM audio haptics. Adaptive triggers, the light bar, motion sensors, and controller speaker are intentionally not controlled.

## Enhanced USB DualSense Support

Chrome and Edge can expose the DualSense touch surface through WebHID. Connect the controller by USB and press a controller button so the standard Gamepad API detects it. When the controller icon appears, select **Enable DualSense touchpad**, choose **Wireless Controller** in the browser prompt, and approve the connection.

The permission prompt only appears after that explicit button press. On later visits, the game attempts to reopen an already authorized controller without prompting. Denying permission, unplugging the controller, or using a browser without WebHID leaves analog-stick, D-pad, keyboard, mouse, and mobile controls unchanged.

The enhanced path currently supports the USB input report. A Bluetooth DualSense continues to work through the standard Gamepad API, but its raw touchpad path is not enabled in this version. Use HTTPS or `localhost` for WebHID testing.

## Deployment

### PWA on GitHub Pages

Use GitHub Pages as the default free PWA host. It serves the app as normal static files over HTTPS, which is required for Android install and service-worker offline support.

1. Push this repository to GitHub.
2. In the GitHub repository, open **Settings > Pages**.
3. Set **Build and deployment** to **Deploy from a branch**.
4. Select the branch that contains this project, usually `main`, and choose `/ (root)` as the folder.
5. Save the setting and wait for GitHub Pages to publish the site.
6. Open the published URL on Android Chrome, then use **Install app** or **Add to Home screen**.

Expected URL shape:

```text
https://<github-user>.github.io/<repo-name>/
```

The PWA files are:

- `manifest.webmanifest`: install metadata, theme colors, and icons
- `service-worker.js`: offline cache for the app shell and local assets
- `assets/pwa-*.png`: Android install icons derived from the existing logo

To test locally, use a web server rather than opening the file directly:

```powershell
python -m http.server 8000
```

Then open:

```text
http://localhost:8000
```

Chrome treats `localhost` as a secure context, so service-worker registration works during local testing.

### HTML.cafe

The deploy script builds a self-contained HTML artifact and can upload it to HTML.cafe.

HTML.cafe remains useful for quick sharing, but it is not the full PWA deployment path because the current flow uploads one standalone HTML payload instead of separately hosted `manifest.webmanifest` and `service-worker.js` files.

Build locally without uploading:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-htmlcafe.ps1 -NoUpload
```

Deploy with explicit credentials:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-htmlcafe.ps1 -PageId "your-page-id" -EditKey "your-edit-key"
```

Or use environment variables:

```powershell
$env:HTMLCAFE_PAGE_ID = "your-page-id"
$env:HTMLCAFE_EDIT_KEY = "your-edit-key"
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-htmlcafe.ps1
```

The script writes standalone builds to `dist/`, which is ignored by Git.

## Local Batch Files

Local `.bat` wrappers can hold machine-specific deploy defaults and credentials. They are intentionally ignored by Git via `.gitignore`, so they are not committed by accident.

Current local wrappers may include:

- `deploy-default.bat`: standard HTML.cafe deploy
- `deploy-webp.bat`: deploy with image optimization enabled

## WebP Optimization

To inline optimized WebP versions of supported image assets during deployment:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy-htmlcafe.ps1 -OptimizeImages -ImageQuality 82 -NoUpload
```

Image optimization requires Python with Pillow and WebP support. The local `deploy-webp.bat` wrapper can point at a known Python runtime.

## Git Hygiene

The repository ignores generated and local-only files such as:

- `*.bat`
- `*.cmd`
- `.env`
- `.env.*`
- `dist/`
- `debug.log`

Keep deploy keys in local ignored files or environment variables, not in committed source files.
