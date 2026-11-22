# ProCam 📸

## 👉 Use it on your iPhone: https://sahibgrewal9815.github.io/Camera/

1. Open the link in **Safari** on your iPhone.
2. Tap **Tap to start camera** and allow camera access.
3. Tap **Share** → **Add to Home Screen**. ProCam now opens full screen like a normal app.
4. Your shots are kept in the ProCam gallery (bottom-left thumbnail). Open one, tap **Save**, then **Save Image** / **Save Video** to put it in Photos.

**Web app features:** 17 film looks (Portra 800, Leica X, Alpine Gold, The Times, Classic Chrome, Velvia, Kodachrome, Cine 800T…) live in the viewfinder, an editable FUJISTYLE-style recipe card, Depth photos and Cinematic video with real background blur (on-device person segmentation), lens buttons (.5 / 1 / 2 / Tele), pinch zoom, Pro panel (EV, white balance, tint, contrast, saturation + histogram), gyroscope stabilization, timer, grid, level, flash, and a frosted glass UI.

The web app lives in `index.html`, `css/`, `js/` and `vendor/` (MediaPipe Selfie Segmentation, Apache-2.0).

---

## Native iOS version (needs a Mac + Xcode)

A film-style iPhone camera with a frosted-glass UI, built with SwiftUI, AVFoundation, Core Image, Metal and Vision.
Looks are rendered **live in the viewfinder** and baked into your photos and videos.

## Features

### Film looks (live LUTs)
17 built-in recipes, each one a full "film recipe" (film simulation, white balance + red/blue shift, grain, colour chrome, dynamic range, highlight, shadow, colour, sharpness, denoise, clarity, plus halation and vignette):

| Family | Looks |
|---|---|
| Your recipe cards | Portra 800, Leica X, Alpine Gold, The Times |
| Fujifilm-style | Classic Chrome, Classic Neg, Velvia, Eterna, Acros |
| Kodak-style | Portra 400, Gold 200, Ektar 100, Kodachrome, Tri-X 400 |
| Vintage / cine | Cine 800T (with halation), Instant, Vintage 70s |

- Live thumbnails of every look in a swipeable strip, plus a strength slider
- **Recipe card**: a frosted card laid out like a FUJISTYLE recipe. Tap any tile to change it, then save your own recipes
- Film colour comes from procedural 3D LUTs (33³), with animated film grain on video
- Works with the **Camera Control** button: swipe through Looks and Strength (iPhone 16 and later)

### Photo
- Zero Shutter Lag, Responsive Capture, Fast Capture Prioritization
- **Depth**: background blur with an adjustable ƒ1.4–ƒ16 aperture. It uses Vision subject masks, so it works for people, pets and objects
- Apple ProRAW (on Pro models; the RAW is saved next to the styled HEIF), Live Photos (with the Natural look), flash
- 4:3, 1:1 and 16:9 aspect ratios, 3s/10s timer, grid, horizon level

### Video
- **Cinematic**: 24fps, background blur that follows people, extended stabilization
- **Action**: strongest stabilization (Enhanced), 1080p
- **Slo-mo**: up to 240fps, written as true slow-motion playback
- **Time-lapse**: adjustable interval, stabilized
- Standard video in 4K or HD at 24/25/30/60fps, HEVC, with a stabilization picker: Off, Standard, Cinematic, Extended or Action

### Pro controls
- Manual ISO, shutter speed, white balance (Kelvin), focus and exposure compensation, each with an AUTO toggle
- Live histogram and aperture readout
- **Smart focus tracking**: double-tap a subject and focus follows it as it moves

### Other
- Automatic lens switching (0.5×, 1×, 2×, 4×/5×), pinch to zoom, tap to focus
- Volume buttons, Camera Control press and AirPods stem press work as the shutter
- Liquid Glass on iOS 26 and later, frosted material on iOS 18

## What the iPhone doesn't let third-party apps do

Some features in Apple's Camera app can't be built by another app, so ProCam either imitates them or leaves them out:
- **Night mode, Photonic Engine and Smart HDR tuning**: not available to other apps. ProCam does get Deep Fusion-style processing through the quality setting.
- **Variable aperture (iPhone 18 Pro)**: no control is available yet. ProCam shows the real ƒ-number and simulates aperture with blur in Depth and Cinematic.
- **Spatial video, Apple Log and ProRes**: these need a different recording pipeline that can't apply live looks. They're good candidates for a future "Pro Video" mode.
- **Siri mode and Photographic Styles**: these are Apple-only. Film recipes take the place of Styles.

## Requirements

- Xcode 26 or later
- iOS 18.0 or later on a **real iPhone** (the Simulator has no camera)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting started

```bash
brew install xcodegen
git clone https://github.com/<your-username>/ProCam.git
cd ProCam
xcodegen generate
open ProCam.xcodeproj
```

1. Select the **ProCam** target → **Signing & Capabilities** → choose your Team.
2. Change the bundle ID (`com.example.procam`) to something unique.
3. Plug in your iPhone, select it, and press **Run** (⌘R).
4. On the phone: trust your developer certificate in **Settings → General → VPN & Device Management**, and turn on **Developer Mode** if asked.

## Project structure

```
ProCam/
├── ProCamApp.swift
├── Camera/
│   ├── CameraEngine.swift      Session, modes, lenses, pro controls, tracking, frame pipeline
│   ├── CameraTypes.swift       Modes, settings, pro state, shared render context
│   ├── PhotoProcessor.swift    Bakes look/depth/crop into photos and saves them
│   ├── VideoRecorder.swift     AVAssetWriter recording, slo-mo and time-lapse retiming
│   └── DepthEffect.swift       Vision subject masks + background blur
├── Looks/
│   ├── FilmRecipe.swift        Recipe model + built-in recipes
│   └── FilmRenderer.swift      LUT generation, tone, grain, halation, clarity
└── UI/
    ├── CameraView.swift        Main screen
    ├── ModeTray.swift          Frosted mode tray (PHOTO ⌄ VIDEO)
    ├── LooksStrip.swift        Look picker with live thumbnails
    ├── RecipeCardView.swift    Editable recipe card
    ├── ProPanel.swift          Manual controls
    ├── SettingsSheet.swift
    ├── MetalPreview.swift      Metal viewfinder
    ├── Components.swift        Shutter, zoom, histogram, level, overlays
    └── Glass.swift             Liquid Glass / frosted helpers
```

## Notes

- Film stock names (Portra, Velvia, Kodachrome and others) are trademarks of their owners. ProCam's looks are inspired by those films, not official versions. **Rename them before you publish to the App Store.**
- Heavy looks combined with 4K60 or 240fps slo-mo can drop frames on older iPhones. If that happens, use HD or a lighter look.
