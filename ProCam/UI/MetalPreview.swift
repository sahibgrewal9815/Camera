import CoreImage
import MetalKit
import SwiftUI

/// Draws the filtered viewfinder frames with Metal (aspect fill).
struct MetalPreview: UIViewRepresentable {
    let store: FrameStore
    var mirrored: Bool

    func makeCoordinator() -> Renderer { Renderer(store: store) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: RenderContext.device)
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 60
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.backgroundColor = .black
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.mirrored = mirrored
    }

    final class Renderer: NSObject, MTKViewDelegate {
        private let store: FrameStore
        private let queue = RenderContext.device.makeCommandQueue()
        private var lastVersion = -1
        private var lastSize = CGSize.zero
        var mirrored = false

        init(store: FrameStore) { self.store = store }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { lastVersion = -1 }

        func draw(in view: MTKView) {
            let (frame, version) = store.latest()
            let size = view.drawableSize
            guard let frame, version != lastVersion || size != lastSize,
                  size.width > 0, size.height > 0,
                  let drawable = view.currentDrawable,
                  let commandBuffer = queue?.makeCommandBuffer() else { return }
            lastVersion = version
            lastSize = size

            var image = frame
            if mirrored {
                image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
                    .translatedBy(x: -image.extent.width, y: 0))
            }
            let s = max(size.width / image.extent.width, size.height / image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            image = image.transformed(by: CGAffineTransform(
                translationX: (size.width - image.extent.width) / 2 - image.extent.minX,
                y: (size.height - image.extent.height) / 2 - image.extent.minY))
            let bounds = CGRect(origin: .zero, size: size)
            image = image.composited(over: CIImage(color: .black).cropped(to: bounds))

            RenderContext.ciContext.render(image, to: drawable.texture, commandBuffer: commandBuffer,
                                           bounds: bounds, colorSpace: RenderContext.sRGB)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
