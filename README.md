# LiveWall

A native macOS live-wallpaper app. Plays local videos and compatible Wallpaper
Engine projects as your desktop background on every display, controlled from
the menu bar. No daemon, no Dock icon, no subscription and no bundled assets.
Free.

Website: https://version0chiro.github.io/LiveWall/

This is an original implementation inspired by apps like Wallper — it ships no
third-party assets or code.

## Download

Download the latest DMG from:
https://github.com/version0chiro/LiveWall/releases/latest

Drag LiveWall to Applications, then open it. This community build is ad-hoc
signed but not Apple-notarized. If macOS blocks the first launch, open
**System Settings → Privacy & Security** and choose **Open Anyway** for
LiveWall. Look for the photo icon in the menu bar after launch.

## Features (v0.6.0)

- Looping video desktop wallpaper via `AVPlayerLooper` (seamless, no gap)
- Imports an existing Wallpaper Engine project or Workshop content folder
  - Video projects: supported
  - Web projects: supported with a lightweight compatibility shim
  - 2D scene projects: beta support for packaged image layers, masked
    water-wave effects, rain particles and looping audio
  - Windows application projects: detected but not supported on macOS
- Downloads an individual Workshop item from a pasted Steam link using Valve's
  SteamCMD and an account that owns Wallpaper Engine
  - Password and Steam Guard entry happen directly in Terminal
  - LiveWall stores only the non-secret Steam account name
  - Downloads are locked to Wallpaper Engine app ID `431960`
- Web wallpapers run in an ephemeral `WKWebView`; navigation outside the
  selected project is blocked and internet access is disabled per wallpaper
  unless you explicitly allow it
- **Widget Mode** keeps Finder icons visible and lets clocks, calendars and
  passive dashboards run below them; click the desktop and hold Option whenever
  you need to interact
- **Always Interactive** mode provides mouse, hover, drag, wheel and keyboard
  input while temporarily covering Finder's desktop icons
- Built-in Wallpaper Engine property editor for booleans, sliders, combos,
  text, colors and local file properties; changes apply live and persist per
  wallpaper
- Local file properties are converted to data URLs instead of giving wallpaper
  JavaScript broad filesystem access
- Wallpaper Engine web host callbacks:
  - Packaged and user-edited properties plus pause state
  - 128-band system-audio spectra via ScreenCaptureKit
  - Now-playing title, artist, album, state and timeline from Music or Spotify
- Optional per-wallpaper internet access for weather, news and online-data
  widgets
- One playback window per display; auto-rebuilds when you plug/unplug monitors
- Menu-bar library picker, local video chooser, pause/resume, Fill vs Fit
- Resource management:
  - **Pause When App is Fullscreen** (on by default) — stops playback when a
    fullscreen app covers the desktop
  - **Pause on Battery** (optional)
- Remembers your last wallpaper and settings across launches
- Native video wallpapers are muted

## Build & run

Requires the Xcode Command Line Tools (already installed).

```bash
cd /Users/bsachsin/Repos/LiveWall
./build.sh
open LiveWall.app
```

Look for the photo icon in the menu bar:

- **Choose Video…** plays a local `.mp4` / `.mov`.
- **Import Wallpaper Engine Folder…** accepts one project folder or a Workshop
  library such as `steamapps/workshop/content/431960`.
- **Download from Steam Workshop Link…** accepts an individual URL containing
  `sharedfiles/filedetails/?id=…`, opens SteamCMD in Terminal, and imports the
  finished project automatically.
- SteamCMD downloads are discovered in Steam's macOS Workshop library:
  `~/Library/Application Support/Steam/steamapps/workshop/content/431960`.
- If one compatible project is found it starts immediately. If several are
  found, choose one from **Wallpaper Engine Library**.
- For clocks and widgets, choose **Widget Mode (icons visible; hold Option)**.
- For games or full-screen controls, choose **Always Interactive**.
- Use **Wallpaper Properties…** to edit the current web wallpaper.
- Enable **Allow Internet for This Wallpaper** only when a trusted widget needs
  online data.
- Enable **System Audio for Visualizers** to feed desktop sound into compatible
  wallpapers. macOS will request Screen & System Audio Recording permission.
- Enable **Music & Spotify Media Widgets** for now-playing information. macOS
  may request Automation permission for the active media player.

Only use Workshop items you have legitimately downloaded for personal use.
LiveWall does not download, decrypt or redistribute Steam content.

> Note: the build pins the `MacOSX15.4` SDK to match the CLT Swift 6.3.3
> compiler. Installing full Xcode would let you use `swift build` / an `.xcodeproj`
> instead.

## Package a DMG

```bash
./package.sh
```

This rebuilds and verifies the app, runs the parser tests, and writes the DMG
plus its SHA-256 checksum to `dist/`. A Developer ID certificate is required
for a notarized public build; without one, the DMG contains the same ad-hoc
signed app produced by `build.sh`.

## Where to get free videos

Any local `.mp4`/`.mov` works. Good free 4K sources: Pexels, Pixabay, and
Coverr (all royalty-free).

## Architecture

- `WallpaperProject.swift` — safe `project.json` parsing and recursive library
  scanning with project-folder containment checks.
- `SceneWallpaper.swift` — bounds-checked `scene.pkg` and `.tex` parsing,
  embedded image loading and LZ4 effect-mask decoding.
- `SceneWallpaperView.swift` — dependency-free Metal renderer for supported
  2D scene effects and procedural rain.
- `SteamWorkshop.swift` — strict Steam item-link parsing, fixed app-ID download
  jobs and safe shell quoting for interactive SteamCMD authentication.
- `WallpaperWindow.swift` — borderless `NSWindow` hosting an `AVPlayerLayer` or
  isolated `WKWebView`, Wallpaper Engine browser callbacks, network policy and
  switchable passive/interactive desktop levels.
- `WallpaperEngine.swift` — owns one wallpaper window per screen, handles
  display reconfiguration and the pause policy (fullscreen / battery).
- `WallpaperPropertyEditor.swift` — dynamic editor generated from
  `project.json` property definitions.
- `SystemAudioSpectrum.swift` — opt-in ScreenCaptureKit audio capture and FFT.
- `MediaIntegration.swift` — opt-in Music and Spotify now-playing bridge.
- `AppDelegate.swift` — menu-bar UI, imported library, permissions and settings.
- `main.swift` — app entry point (`LSUIElement`, accessory activation).

## Roadmap

- [ ] Multi-display: different video per monitor
- [ ] Built-in library / thumbnail picker UI (SwiftUI)
- [x] 2D scene wallpaper renderer (image, water waves, rain and audio)
- [ ] Additional scene textures, shaders, particles and puppet animation
- [ ] Additional media players beyond Music and Spotify
- [ ] Per-domain rather than per-wallpaper internet allowlists
- [ ] "Pause on high CPU" throttle
- [ ] Reduce quality on battery
- [ ] Lock Screen playback (hard — no public API; deferred)
- [ ] Launch at login (`SMAppService`)
