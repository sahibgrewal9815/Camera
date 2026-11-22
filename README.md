# ProCam 📸

A modern iPhone camera app built with SwiftUI and AVFoundation, using the newest camera APIs.

## Features

**Photo**
- Zero Shutter Lag, Responsive Capture and Fast Capture Prioritization (fire shots back-to-back like the system camera)
- Deferred photo processing: you get the shot instantly, and Photos finishes the heavy processing in the background
- HEIF output, up to ~24MP by default (on 48MP sensors)
- Apple ProRAW toggle (on supported Pro models), saved together with an HEIF preview
- Live Photos
- Flash: off / auto / on
- 3s and 10s self-timer

**Video**
- HEVC recording with sound
- Enhanced cinematic stabilization
- Recording timer

**Controls**
- Automatic lens switching across ultra wide, wide and telephoto
- Zoom buttons (0.5×, 1×, 2×, 3×/5× depending on your iPhone) and pinch to zoom
- Tap to focus and expose; goes back to auto focus when the scene changes
- **Camera Control button** (iPhone 16 and later): zoom and exposure sliders
- Take a shot with the **volume buttons**, a **Camera Control** press or an **AirPods** stem press
- Rule-of-thirds grid
- Swipe left/right to switch between Photo and Video
- Front/back camera switch
- Liquid Glass buttons on iOS 26 and later, frosted glass on iOS 18
- Haptic feedback

## Requirements

- Xcode 26 or later
- iOS 18.0 or later on a **real iPhone** (the Simulator has no camera)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project

## Getting started

```bash
brew install xcodegen
git clone https://github.com/<your-username>/ProCam.git
cd ProCam
xcodegen generate
open ProCam.xcodeproj
```

Then in Xcode:
1. Select the **ProCam** target → **Signing & Capabilities** → choose your Team.
2. If needed, change the bundle ID (`com.example.procam`) to something unique, like `com.yourname.procam`.
3. Plug in your iPhone, select it as the run destination and press **Run** (⌘R).
4. On the iPhone, the first time: **Settings → General → VPN & Device Management** → trust your developer certificate, and turn on **Developer Mode** if asked.

## Project structure

| File | What it does |
|---|---|
| `ProCam/ProCamApp.swift` | App entry point |
| `ProCam/CameraView.swift` | The camera screen (SwiftUI) |
| `ProCam/CameraModel.swift` | Capture session, lenses, zoom, focus, photo/video, Camera Control |
| `ProCam/PhotoCaptureProcessor.swift` | Handles each photo and saves it to Photos |
| `ProCam/CameraPreview.swift` | Live camera preview layer |
| `project.yml` | XcodeGen project definition (permissions, iOS version, bundle ID) |

## Ideas for next features

- Night mode and manual controls (ISO, shutter speed, white balance)
- Portrait mode with depth effect
- Cinematic video / Spatial video
- 4K 60fps and ProRes / Apple Log options
- Photographic Styles and filters
- QR code scanning
