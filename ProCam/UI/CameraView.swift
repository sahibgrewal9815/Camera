import AVFoundation
import AVKit
import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraEngine()
    @Environment(\.scenePhase) private var scenePhase
    @State private var focusPoint: CGPoint?
    @State private var focusID = UUID()
    @State private var pinchStartZoom: CGFloat?
    @State private var trayExpanded = true
    @State private var showSettings = false
    @State private var showRecipeCard = false

    var body: some View {
        GeometryReader { geo in
            let safe = geo.safeAreaInsets
            let frame = viewfinderFrame(screen: geo.size, topInset: safe.top)

            ZStack(alignment: .top) {
                Color.black

                if camera.isAuthorized == false {
                    PermissionView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    viewfinder(size: frame.size)
                        .frame(width: frame.width, height: frame.height)
                        .clipShape(RoundedRectangle(cornerRadius: camera.mode.isVideo ? 0 : 4, style: .continuous))
                        .position(x: frame.midX, y: frame.midY)
                        .animation(.smooth(duration: 0.35), value: frame)

                    topBar
                        .padding(.top, safe.top + 6)
                        .padding(.horizontal, 18)
                        .opacity(camera.controlsFullscreen ? 0 : 1)

                    VStack(spacing: 14) {
                        Spacer()
                        contextPanel
                        ZoomPresetBar(camera: camera)
                        shutterRow
                        ModeTray(camera: camera, expanded: $trayExpanded)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, max(safe.bottom, 12))
                    .opacity(camera.controlsFullscreen ? 0 : 1)
                    .animation(.spring(duration: 0.35), value: camera.showLooks)
                    .animation(.spring(duration: 0.35), value: camera.showPro)
                    .animation(.spring(duration: 0.35), value: trayExpanded)
                }

                Color.black.opacity(camera.shutterBlink ? 0.85 : 0)
                    .allowsHitTesting(false)
            }
            .ignoresSafeArea()
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        // Volume buttons, Camera Control click and AirPods stem press act as the shutter.
        .onCameraCaptureEvent { event in
            if event.phase == .ended { camera.shutterPressed() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet(camera: camera)
        }
        .sheet(isPresented: $showRecipeCard) {
            RecipeCardView(camera: camera, recipe: camera.selectedRecipe)
        }
    }

    // MARK: Viewfinder

    private func viewfinderFrame(screen: CGSize, topInset: CGFloat) -> CGRect {
        let width = screen.width
        let aspect = camera.mode.isVideo ? 9.0 / 16.0 : camera.settings.photoAspect.ratio
        let height = width / aspect
        let photoTop = topInset + 58
        let photoAreaHeight = width * 4 / 3
        if !camera.mode.isVideo, height <= photoAreaHeight + 1 {
            return CGRect(x: 0, y: photoTop + (photoAreaHeight - height) / 2, width: width, height: height)
        }
        return CGRect(x: 0, y: (screen.height - height) / 2, width: width, height: height)
    }

    private func viewfinder(size: CGSize) -> some View {
        let mapping = PreviewMapping(viewSize: size, imageSize: camera.imageSize, mirrored: camera.isFrontCamera)
        return ZStack {
            MetalPreview(store: camera.frameStore, mirrored: camera.isFrontCamera)

            if camera.settings.showGrid { GridOverlay().allowsHitTesting(false) }
            if camera.settings.showLevel { LevelIndicator(live: camera.live).allowsHitTesting(false) }

            TrackingBox(live: camera.live, mapping: mapping)

            if let focusPoint {
                FocusSquare()
                    .position(focusPoint)
                    .id(focusID)
                    .allowsHitTesting(false)
            }

            if let countdown = camera.countdown {
                Text("\(countdown)")
                    .font(.system(size: 130, weight: .thin, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(radius: 10)
                    .contentTransition(.numericText(countdown: true))
                    .allowsHitTesting(false)
            }

            if camera.showPro, camera.settings.showHistogram {
                VStack {
                    HStack {
                        HistogramView(live: camera.live)
                        Spacer()
                    }
                    Spacer()
                }
                .padding(.top, camera.mode.isVideo ? 120 : 12)
                .padding(.leading, 12)
                .allowsHitTesting(false)
            }

            if camera.mode.usesDepthEffect {
                VStack {
                    Text(camera.mode == .cinematic ? "CINEMATIC · ƒ\(apertureText)" : "DEPTH · ƒ\(apertureText)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassBackground(Capsule())
                    Spacer()
                }
                .padding(.top, camera.mode.isVideo ? 110 : 10)
                .allowsHitTesting(false)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            SpatialTapGesture(count: 2)
                .onEnded { value in
                    camera.startTracking(atImagePoint: mapping.imagePoint(from: value.location))
                }
                .exclusively(before: SpatialTapGesture(count: 1).onEnded { value in
                    camera.stopTracking()
                    camera.focus(atImagePoint: mapping.imagePoint(from: value.location))
                    showFocus(at: value.location)
                })
        )
        .simultaneousGesture(pinchToZoom)
        .simultaneousGesture(modeSwipe)
    }

    private var apertureText: String { String(format: "%.1f", camera.aperture) }

    // MARK: Top bar (pinned controls)

    private var topBar: some View {
        HStack(spacing: 10) {
            if camera.isRecording {
                Spacer()
                RecordingBadge(live: camera.live)
                Spacer()
            } else {
                if camera.mode.isVideo {
                    stabilizationMenu
                    formatMenu
                } else {
                    if camera.flashAvailable {
                        GlassCircleButton(systemName: flashIcon, active: camera.flashMode == .on) { camera.cycleFlash() }
                    }
                    if camera.livePhotoSupported, camera.selectedRecipe.isNeutral, camera.mode == .photo {
                        GlassCircleButton(systemName: camera.livePhotoEnabled ? "livephoto" : "livephoto.slash",
                                          active: camera.livePhotoEnabled) { camera.livePhotoEnabled.toggle() }
                    }
                    if camera.proRAWSupported, camera.mode == .photo {
                        Button { camera.proRAWEnabled.toggle() } label: {
                            Text("RAW")
                                .font(.system(size: 12, weight: .heavy))
                                .strikethrough(!camera.proRAWEnabled)
                                .foregroundStyle(camera.proRAWEnabled ? .yellow : .white)
                                .frame(width: 44, height: 44)
                                .glassBackground(Circle())
                        }
                    }
                }
                Spacer()
                GlassCircleButton(systemName: "slider.horizontal.3", active: camera.showPro) {
                    camera.showPro.toggle()
                    if camera.showPro { camera.showLooks = false }
                }
                GlassCircleButton(systemName: "camera.filters", active: camera.showLooks || !camera.selectedRecipe.isNeutral) {
                    camera.showLooks.toggle()
                    if camera.showLooks { camera.showPro = false }
                }
                GlassCircleButton(systemName: "gearshape") { showSettings = true }
            }
        }
        .frame(height: 48)
    }

    private var stabilizationMenu: some View {
        Menu {
            if camera.mode == .video {
                Picker("Stabilization", selection: $camera.settings.stabilization) {
                    ForEach(StabilizationChoice.allCases) { choice in
                        Label(choice.rawValue, systemImage: choice.symbol).tag(choice)
                    }
                }
            } else {
                Text("\(camera.mode.title) uses its own stabilization")
            }
        } label: {
            Image(systemName: stabilizationIcon)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(camera.activeStabilization == .off ? .white : .yellow)
                .frame(width: 44, height: 44)
                .glassBackground(Circle())
        }
    }

    private var formatMenu: some View {
        Menu {
            Picker("Resolution", selection: $camera.settings.videoResolution) {
                ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
            }
            if camera.mode == .video {
                Picker("Frame rate", selection: $camera.settings.frameRate) {
                    ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
            if camera.mode == .cinematic {
                Picker("Frame rate", selection: $camera.settings.cinematicFrameRate) {
                    ForEach([24, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
            }
        } label: {
            Text(formatLabel)
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 44)
                .glassBackground(Capsule())
        }
    }

    private var formatLabel: String {
        switch camera.mode {
        case .sloMo: return "HD · \(camera.activeFrameRate)"
        case .timelapse: return "TIMELAPSE"
        case .action: return "HD · 30"
        default: return "\(camera.settings.videoResolution.rawValue) · \(camera.activeFrameRate)"
        }
    }

    private var stabilizationIcon: String {
        switch camera.activeStabilization {
        case .off: "hand.raised.slash"
        case .standard: "hand.raised"
        case .cinematicExtendedEnhanced: "figure.run"
        default: "gyroscope"
        }
    }

    private var flashIcon: String {
        switch camera.flashMode {
        case .on: "bolt.fill"
        case .auto: "bolt.badge.automatic"
        default: "bolt.slash"
        }
    }

    // MARK: Bottom

    @ViewBuilder
    private var contextPanel: some View {
        if camera.showLooks {
            LooksStrip(camera: camera, live: camera.live) { showRecipeCard = true }
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if camera.showPro {
            ProPanel(camera: camera)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if camera.mode.usesDepthEffect {
            ApertureSlider(aperture: $camera.aperture)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var shutterRow: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                ZStack {
                    if let thumb = camera.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.1)
                    }
                    if camera.processingCount > 0 {
                        Color.black.opacity(0.35)
                        ProgressView().tint(.white)
                    }
                }
                .frame(width: 62, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(.white.opacity(0.25)))
            }
            .opacity(camera.isRecording ? 0 : 1)

            Spacer()
            ShutterButton(mode: camera.mode, isRecording: camera.isRecording) { camera.shutterPressed() }
            Spacer()

            GlassCircleButton(systemName: "arrow.triangle.2.circlepath", size: 62) { camera.switchCamera() }
                .opacity(camera.isRecording ? 0 : 1)
        }
        .padding(.horizontal, 12)
    }

    // MARK: Gestures

    private var pinchToZoom: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStartZoom ?? camera.zoomFactor
                pinchStartZoom = start
                camera.setZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStartZoom = nil }
    }

    private var modeSwipe: some Gesture {
        DragGesture(minimumDistance: 50)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                camera.setMode(value.translation.width < 0 ? .video : .photo)
            }
    }

    private func showFocus(at point: CGPoint) {
        focusID = UUID()
        focusPoint = point
        let id = focusID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if focusID == id { withAnimation { focusPoint = nil } }
        }
    }
}
