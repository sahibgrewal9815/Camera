import AVFoundation
import AVKit
import SwiftUI

struct CameraView: View {
    @StateObject private var camera = CameraModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var focusPoint: CGPoint?
    @State private var focusID = UUID()
    @State private var pinchStartZoom: CGFloat?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch camera.isAuthorized {
            case .some(false): PermissionView()
            default: cameraUI
            }

            // Shutter "blink" like the system camera.
            Color.black.opacity(camera.shutterBlink ? 0.9 : 0)
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
        .statusBarHidden()
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { camera.start() } else if phase == .background { camera.stop() }
        }
        // Volume buttons, Camera Control click and AirPods stem press take a photo (iOS 18).
        .onCameraCaptureEvent { event in
            if event.phase == .ended { camera.shutterPressed() }
        }
    }

    // MARK: Layout

    private var cameraUI: some View {
        VStack(spacing: 0) {
            topBar
                .frame(height: 52)
                .opacity(camera.controlsFullscreen ? 0 : 1)

            ZStack {
                CameraPreview(session: camera.session) { point, devicePoint in
                    camera.focus(at: devicePoint)
                    showFocus(at: point)
                }

                if camera.showGrid { GridOverlay().allowsHitTesting(false) }

                if let focusPoint {
                    FocusSquare()
                        .position(focusPoint)
                        .id(focusID)
                        .allowsHitTesting(false)
                }

                if let countdown = camera.countdown {
                    Text("\(countdown)")
                        .font(.system(size: 120, weight: .thin, design: .rounded))
                        .foregroundStyle(.white)
                        .contentTransition(.numericText(countdown: true))
                        .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    ZoomPresetBar(camera: camera)
                        .padding(.bottom, 12)
                        .opacity(camera.controlsFullscreen ? 0 : 1)
                }
            }
            .aspectRatio(camera.mode == .photo ? 3 / 4 : 9 / 16, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: camera.mode == .photo ? 0 : 12))
            .gesture(pinchToZoom)
            .animation(.easeInOut(duration: 0.25), value: camera.mode)

            Spacer(minLength: 8)

            ModePicker(camera: camera)
                .padding(.bottom, 14)

            bottomBar
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .gesture(modeSwipe)
    }

    private var topBar: some View {
        HStack(spacing: 22) {
            if camera.isRecording {
                Spacer()
                RecordingBadge(duration: camera.recordingDuration)
                Spacer()
            } else {
                if camera.mode == .photo, camera.flashAvailable {
                    IconButton(systemName: flashIcon, active: camera.flashMode == .on) { camera.cycleFlash() }
                }
                if camera.mode == .photo, camera.livePhotoSupported, !camera.proRAWEnabled {
                    IconButton(systemName: camera.livePhotoEnabled ? "livephoto" : "livephoto.slash",
                               active: camera.livePhotoEnabled) { camera.livePhotoEnabled.toggle() }
                }
                Spacer()
                if camera.mode == .photo, camera.proRAWSupported {
                    Button { camera.proRAWEnabled.toggle() } label: {
                        Text("RAW")
                            .font(.caption.weight(.bold))
                            .strikethrough(!camera.proRAWEnabled)
                            .foregroundStyle(camera.proRAWEnabled ? .yellow : .white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(lineWidth: 1.2)
                                .foregroundStyle(camera.proRAWEnabled ? .yellow : .white))
                    }
                }
                Button { camera.cycleTimer() } label: {
                    HStack(spacing: 2) {
                        Image(systemName: "timer")
                        if camera.timerSeconds > 0 { Text("\(camera.timerSeconds)s").font(.caption.bold()) }
                    }
                    .foregroundStyle(camera.timerSeconds > 0 ? .yellow : .white)
                }
                IconButton(systemName: "grid", active: camera.showGrid) { camera.showGrid.toggle() }
            }
        }
        .font(.system(size: 18))
        .padding(.horizontal, 20)
    }

    private var bottomBar: some View {
        HStack {
            Button {
                if let url = URL(string: "photos-redirect://") { UIApplication.shared.open(url) }
            } label: {
                Group {
                    if let thumb = camera.lastThumbnail {
                        Image(uiImage: thumb).resizable().scaledToFill()
                    } else {
                        Color.white.opacity(0.12)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.3)))
            }
            .opacity(camera.isRecording ? 0 : 1)

            Spacer()
            ShutterButton(mode: camera.mode, isRecording: camera.isRecording) { camera.shutterPressed() }
            Spacer()

            Button { camera.switchCamera() } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .glassBackground(Circle())
            }
            .opacity(camera.isRecording ? 0 : 1)
        }
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
        DragGesture(minimumDistance: 40)
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
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

    private var flashIcon: String {
        switch camera.flashMode {
        case .on: "bolt.fill"
        case .auto: "bolt.badge.automatic"
        default: "bolt.slash"
        }
    }
}

// MARK: - Components

private struct IconButton: View {
    let systemName: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(active ? .yellow : .white)
                .frame(width: 36, height: 36)
        }
    }
}

private struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 78, height: 78)
                RoundedRectangle(cornerRadius: isRecording ? 8 : 33)
                    .fill(mode == .video ? Color.red : Color.white)
                    .frame(width: isRecording ? 32 : 66, height: isRecording ? 32 : 66)
            }
            .animation(.spring(duration: 0.3), value: isRecording)
        }
        .buttonStyle(ShutterPressStyle())
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
    }
}

private struct ShutterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.92 : 1)
    }
}

private struct ModePicker: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        HStack(spacing: 28) {
            ForEach(CaptureMode.allCases) { mode in
                Button { camera.setMode(mode) } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 14, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(camera.mode == mode ? .yellow : .white)
                }
            }
        }
        .opacity(camera.isRecording ? 0 : 1)
        .sensoryFeedback(.selection, trigger: camera.mode)
    }
}

private struct ZoomPresetBar: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let selected = isSelected(preset)
                Button { camera.setZoom(preset, animated: true) } label: {
                    Text(label(for: preset, selected: selected))
                        .font(.system(size: selected ? 13 : 11, weight: .bold))
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(width: selected ? 40 : 32, height: selected ? 40 : 32)
                        .glassBackground(Circle())
                }
            }
        }
        .padding(4)
        .glassBackground(Capsule())
        .animation(.snappy, value: camera.zoomFactor)
        .sensoryFeedback(.selection, trigger: camera.zoomPresets.firstIndex(where: isSelected))
    }

    /// The active preset is the highest one at or below the current zoom.
    private func isSelected(_ preset: CGFloat) -> Bool {
        let presets = camera.zoomPresets
        let active = presets.last(where: { $0 <= camera.zoomFactor + 0.05 }) ?? presets.first
        return active == preset
    }

    private func label(for preset: CGFloat, selected: Bool) -> String {
        let value = selected ? camera.zoomFactor : preset
        let text = value < 1 ? String(format: "%.1f", value).replacingOccurrences(of: "0.", with: ".")
            : (value.rounded() == value || !selected ? String(format: "%.0f", value) : String(format: "%.1f", value))
        return selected ? text + "×" : text
    }
}

private struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                for i in 1...2 {
                    let x = geo.size.width * CGFloat(i) / 3
                    let y = geo.size.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geo.size.height))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.6)
        }
    }
}

private struct FocusSquare: View {
    @State private var appeared = false

    var body: some View {
        Rectangle()
            .stroke(.yellow, lineWidth: 1.2)
            .frame(width: 76, height: 76)
            .scaleEffect(appeared ? 1 : 1.4)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { appeared = true } }
    }
}

private struct RecordingBadge: View {
    let duration: TimeInterval

    var body: some View {
        let total = Int(duration)
        Text(String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60))
            .font(.system(size: 16, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill").font(.system(size: 44))
            Text("Camera access needed").font(.title3.bold())
            Text("Turn on camera access in Settings to use ProCam.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
        .foregroundStyle(.white)
    }
}

// MARK: - Liquid Glass with fallback

extension View {
    /// Uses iOS 26 Liquid Glass when available, frosted material otherwise.
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}
