import SwiftUI

/// The frosted tray under the shutter: quick modes/tools on top, PHOTO ⌄ VIDEO underneath.
struct ModeTray: View {
    @ObservedObject var camera: CameraEngine
    @Binding var expanded: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let active: Bool
        let action: () -> Void
    }

    private var items: [Item] {
        if camera.mode.isVideo {
            return [CaptureMode.cinematic, .action, .sloMo, .timelapse].map { mode in
                Item(id: mode.rawValue, title: mode.title, symbol: symbol(for: mode), active: camera.mode == mode) {
                    camera.setMode(camera.mode == mode ? .video : mode)
                }
            }
        }
        return [
            Item(id: "depth", title: "DEPTH", symbol: "f.cursive", active: camera.mode == .depth) {
                camera.setMode(camera.mode == .depth ? .photo : .depth)
            },
            Item(id: "timer", title: camera.timerSeconds == 0 ? "TIMER" : "\(camera.timerSeconds)S",
                 symbol: "timer", active: camera.timerSeconds > 0) { camera.cycleTimer() },
            Item(id: "aspect", title: camera.settings.photoAspect.rawValue, symbol: "aspectratio",
                 active: camera.settings.photoAspect != .threeFour) {
                camera.settings.photoAspect = camera.settings.photoAspect.next
            },
            Item(id: "grid", title: "GRID", symbol: "grid", active: camera.settings.showGrid) {
                camera.settings.showGrid.toggle()
            },
        ]
    }

    private func symbol(for mode: CaptureMode) -> String {
        switch mode {
        case .cinematic: "f.cursive"
        case .action: "figure.run"
        case .sloMo: "circle.dotted"
        case .timelapse: "circle.dashed"
        default: "circle"
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            if expanded && !camera.isRecording {
                HStack(spacing: 0) {
                    ForEach(items) { item in
                        Button(action: item.action) {
                            VStack(spacing: 7) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 19, weight: .medium))
                                    .foregroundStyle(item.active ? .yellow : .white)
                                    .frame(width: 50, height: 50)
                                    .background(Circle().fill(.black.opacity(0.28)))
                                    .overlay(Circle().stroke(item.active ? .yellow.opacity(0.6) : .white.opacity(0.08)))
                                Text(item.title)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(item.active ? .yellow : .white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 20) {
                Button { camera.setMode(.photo) } label: {
                    Text("PHOTO")
                        .foregroundStyle(camera.mode.isVideo ? .white : .yellow)
                }
                Button {
                    withAnimation(.spring(duration: 0.35)) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.compact.down")
                        .font(.system(size: 22, weight: .semibold))
                        .rotationEffect(.degrees(expanded ? 0 : 180))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 20)
                }
                Button { camera.setMode(.video) } label: {
                    Text("VIDEO")
                        .foregroundStyle(camera.mode.isVideo ? .yellow : .white)
                }
            }
            .font(.system(size: 16, weight: .medium))
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.4 : 1)
        }
        .padding(.top, 16)
        .padding(.bottom, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .glassPanel(cornerRadius: 30)
        .sensoryFeedback(.selection, trigger: camera.mode)
    }
}
