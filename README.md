# Ocean Snake

Ocean Snake is a polished, responsive browser snake game built as a single HTML file. It has pointer-drag steering, mobile joystick controls, WASD keyboard movement, gamepad support, animated ocean visuals, sound controls, and a persistent best score stored in `localStorage`.

You can try a live playable version of this game here: https://html.cafe/x726e33d0

## Features

- Single-file game runtime in `index.html`
- Responsive desktop and mobile layout
- Mouse, touch, WASD, and gamepad input
- Pause, mute, and restart controls
- Local best-score persistence
- Local image assets in `assets/`
- HTML.cafe deployment script with optional asset inlining and WebP optimization

## Project Structure

```text
.
|-- index.html
|-- assets/
|   |-- ocean-snake-logo-header.png
|   |-- ocean-snake-logo.ico
|   |-- ocean-snake-logo.png
|   `-- ocean-snake-mascot-source.png
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
- Keyboard: `W`, `A`, `S`, `D`
- Gamepad: analog stick or D-pad
- Buttons: pause, mute, restart

## Deployment

The deploy script builds a self-contained HTML artifact and can upload it to HTML.cafe.

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
