import SwiftUI

extension View {
    /// Frosted glass: Liquid Glass on iOS 26+, blurred material on iOS 18.
    @ViewBuilder
    func glassBackground<S: Shape>(_ shape: S, tint: Color? = nil) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .background((tint ?? .clear).opacity(0.25), in: shape)
                .overlay(shape.stroke(.white.opacity(0.12), lineWidth: 0.5))
        }
    }

    /// Larger frosted panel used for trays and cards.
    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self.glassBackground(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
    }
}

/// Round frosted button, like the ones on the system camera.
struct GlassCircleButton: View {
    let systemName: String
    var size: CGFloat = 44
    var active = false
    var activeColor: Color = .yellow
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.4, weight: .medium))
                .foregroundStyle(active ? activeColor : .white)
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassBackground(Circle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

struct PressScaleStyle: ButtonStyle {
    var scale: CGFloat = 0.9
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
