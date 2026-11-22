import SwiftUI

/// Manual controls: ISO, shutter speed, white balance, focus and exposure compensation.
struct ProPanel: View {
    @ObservedObject var camera: CameraEngine
    @State private var selected: Param = .iso

    enum Param: String, CaseIterable, Identifiable {
        case iso = "ISO", shutter = "S", wb = "WB", focus = "FOCUS", ev = "EV"
        var id: String { rawValue }
    }

    private var p: ProState { camera.pro }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 0) {
                ForEach(Param.allCases) { param in
                    Button { selected = param } label: {
                        VStack(spacing: 3) {
                            Text(param.rawValue)
                                .font(.system(size: 9, weight: .heavy))
                                .opacity(0.7)
                            Text(valueText(param))
                                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            Circle()
                                .fill(isAuto(param) ? .clear : .yellow)
                                .frame(width: 4, height: 4)
                        }
                        .foregroundStyle(selected == param ? .yellow : .white)
                        .frame(maxWidth: .infinity)
                    }
                }
            }

            HStack(spacing: 12) {
                Button { setAuto(selected) } label: {
                    Text("AUTO")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(isAuto(selected) ? .black : .white)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(isAuto(selected) ? .yellow : .white.opacity(0.15), in: Capsule())
                }
                slider(for: selected)
                    .tint(.yellow)
            }

            HStack {
                Text(String(format: "ƒ/%.2g", p.aperture))
                Spacer()
                Button("Reset all") { camera.resetPro() }
            }
            .font(.system(size: 11, weight: .semibold))
            .opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(14)
        .glassPanel(cornerRadius: 24)
        .sensoryFeedback(.selection, trigger: selected)
    }

    // MARK: Values

    private func valueText(_ param: Param) -> String {
        switch param {
        case .iso: "\(Int(p.iso))"
        case .shutter: ProState.shutterLabel(p.shutter)
        case .wb: "\(Int(p.kelvin / 100) * 100)K"
        case .focus: String(format: "%.2f", p.lensPosition)
        case .ev: String(format: "%+.1f", p.exposureBias)
        }
    }

    private func isAuto(_ param: Param) -> Bool {
        switch param {
        case .iso: p.isoAuto
        case .shutter: p.shutterAuto
        case .wb: p.wbAuto
        case .focus: p.focusAuto
        case .ev: p.exposureBias == 0
        }
    }

    private func setAuto(_ param: Param) {
        switch param {
        case .iso: camera.setISO(nil)
        case .shutter: camera.setShutter(nil)
        case .wb: camera.setWhiteBalance(nil)
        case .focus: camera.setFocus(nil)
        case .ev: camera.setExposureBias(0)
        }
    }

    @ViewBuilder
    private func slider(for param: Param) -> some View {
        switch param {
        case .iso:
            let stops = ProState.isoStops.filter { $0 >= p.minISO && $0 <= p.maxISO }
            stepSlider(count: stops.count, index: nearestIndex(stops.map(Double.init), Double(p.iso))) { i in
                camera.setISO(stops[i])
            }
        case .shutter:
            let stops = ProState.shutterStops.filter { $0 >= p.minShutter && $0 <= p.maxShutter }
            stepSlider(count: stops.count, index: nearestIndex(stops, p.shutter)) { i in
                camera.setShutter(stops[i])
            }
        case .wb:
            Slider(value: Binding(get: { Double(p.kelvin) }, set: { camera.setWhiteBalance(Float($0)) }),
                   in: 2500...10000, step: 100)
        case .focus:
            Slider(value: Binding(get: { Double(p.lensPosition) }, set: { camera.setFocus(Float($0)) }), in: 0...1)
        case .ev:
            Slider(value: Binding(get: { Double(p.exposureBias) }, set: { camera.setExposureBias(Float($0)) }),
                   in: Double(max(p.minBias, -3))...Double(min(p.maxBias, 3)), step: 0.1)
        }
    }

    @ViewBuilder
    private func stepSlider(count: Int, index: Int, onChange: @escaping (Int) -> Void) -> some View {
        if count > 1 {
            Slider(value: Binding(get: { Double(index) },
                                  set: { onChange(min(max(Int($0.rounded()), 0), count - 1)) }),
                   in: 0...Double(count - 1), step: 1)
        } else {
            Spacer()
        }
    }

    private func nearestIndex(_ values: [Double], _ target: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        return values.indices.min(by: { abs(values[$0] - target) < abs(values[$1] - target) }) ?? 0
    }
}
