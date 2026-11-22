import AVFoundation
import SwiftUI

struct ShutterButton: View {
    let mode: CaptureMode
    let isRecording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 84, height: 84)
                RoundedRectangle(cornerRadius: isRecording ? 9 : 36, style: .continuous)
                    .fill(mode.isVideo ? Color.red : Color.white)
                    .frame(width: isRecording ? 34 : 72, height: isRecording ? 34 : 72)
            }
            .animation(.spring(duration: 0.3), value: isRecording)
            .animation(.easeInOut(duration: 0.25), value: mode.isVideo)
        }
        .buttonStyle(PressScaleStyle(scale: 0.92))
        .sensoryFeedback(.impact(weight: .medium), trigger: isRecording)
    }
}

struct ZoomPresetBar: View {
    @ObservedObject var camera: CameraEngine

    var body: some View {
        HStack(spacing: 4) {
            ForEach(camera.zoomPresets, id: \.self) { preset in
                let selected = isSelected(preset)
                Button { camera.setZoom(preset, animated: true) } label: {
                    Text(label(for: preset, selected: selected))
                        .font(.system(size: selected ? 13 : 11, weight: .bold))
                        .foregroundStyle(selected ? .yellow : .white)
                        .frame(width: selected ? 42 : 34, height: selected ? 42 : 34)
                        .background(Circle().fill(.black.opacity(selected ? 0.35 : 0.2)))
                }
            }
        }
        .padding(4)
        .glassBackground(Capsule())
        .animation(.snappy, value: camera.zoomFactor)
        .sensoryFeedback(.selection, trigger: camera.zoomPresets.firstIndex(where: isSelected))
    }

    private func isSelected(_ preset: CGFloat) -> Bool {
        let presets = camera.zoomPresets
        let active = presets.last(where: { $0 <= camera.zoomFactor + 0.05 }) ?? presets.first
        return active == preset
    }

    private func label(for preset: CGFloat, selected: Bool) -> String {
        let value = selected ? camera.zoomFactor : preset
        let text: String
        if value < 1 {
            text = String(format: "%.1f", value).replacingOccurrences(of: "0.", with: ".")
        } else if !selected || abs(value.rounded() - value) < 0.05 {
            text = String(format: "%.0f", value)
        } else {
            text = String(format: "%.1f", value)
        }
        return selected ? text + "×" : text
    }
}

/// Simulated aperture for Depth and Cinematic modes.
struct ApertureSlider: View {
    @Binding var aperture: Double

    var body: some View {
        HStack(spacing: 12) {
            Text("ƒ")
                .font(.system(size: 20, weight: .semibold, design: .serif))
                .italic()
            Slider(value: $aperture, in: 1.4...16, step: 0.1)
                .tint(.yellow)
            Text(String(format: "%.1f", aperture))
                .font(.system(size: 14, weight: .bold).monospacedDigit())
                .frame(width: 38)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: 22)
    }
}

struct GridOverlay: View {
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

/// Horizon level: turns yellow when the phone is straight.
struct LevelIndicator: View {
    @ObservedObject var live: LiveData

    var body: some View {
        let degrees = live.roll * 180 / .pi
        let level = abs(degrees) < 1
        if abs(degrees) < 25 {
            HStack(spacing: 6) {
                Rectangle().frame(width: 34, height: 1.5)
                Rectangle().frame(width: level ? 34 : 0, height: 1.5)
                Rectangle().frame(width: 34, height: 1.5)
            }
            .foregroundStyle(level ? .yellow : .white.opacity(0.8))
            .rotationEffect(.radians(level ? 0 : -live.roll))
            .animation(.linear(duration: 0.1), value: live.roll)
        }
    }
}

/// Yellow box that follows a double-tapped subject (smart focus tracking).
struct TrackingBox: View {
    @ObservedObject var live: LiveData
    let mapping: PreviewMapping

    var body: some View {
        if let rect = live.trackedRect {
            let r = mapping.viewRect(from: rect)
            RoundedRectangle(cornerRadius: 6)
                .stroke(.yellow, lineWidth: 1.5)
                .frame(width: r.width, height: r.height)
                .position(x: r.midX, y: r.midY)
                .animation(.linear(duration: 0.08), value: rect)
                .allowsHitTesting(false)
        }
    }
}

struct FocusSquare: View {
    @State private var appeared = false

    var body: some View {
        Rectangle()
            .stroke(.yellow, lineWidth: 1.2)
            .frame(width: 76, height: 76)
            .scaleEffect(appeared ? 1 : 1.4)
            .onAppear { withAnimation(.easeOut(duration: 0.25)) { appeared = true } }
    }
}

struct RecordingBadge: View {
    @ObservedObject var live: LiveData

    var body: some View {
        let total = Int(live.recordingDuration)
        Text(String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60))
            .font(.system(size: 16, weight: .medium).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.red, in: Capsule())
    }
}

struct HistogramView: View {
    @ObservedObject var live: LiveData

    var body: some View {
        Canvas { context, size in
            let bins = live.histogram
            guard bins.count > 1 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, value) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(value))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            context.fill(path, with: .color(.white.opacity(0.75)))
        }
        .frame(width: 112, height: 44)
        .padding(6)
        .glassBackground(RoundedRectangle(cornerRadius: 10))
    }
}

struct PermissionView: View {
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
