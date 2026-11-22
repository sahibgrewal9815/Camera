import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// Background blur ("Depth" photos and "Cinematic" video).
/// Uses Vision subject masks, so it works on every iPhone, not only ones with depth hardware.
enum DepthEffect {

    /// `aperture` is a simulated f-number (1.4 = strongest blur, 16 = almost none).
    static func apply(to image: CIImage, subjectMask: CIImage?, aperture: Double) -> CIImage {
        guard let subjectMask, aperture < 15.9 else { return image }
        let extent = image.extent
        let scale = max(extent.width, extent.height) / 1920

        // Fit the mask to the image, soften its edge, then invert so the background = 1 (blurred).
        let mx = extent.width / subjectMask.extent.width
        let my = extent.height / subjectMask.extent.height
        let fitted = subjectMask
            .transformed(by: CGAffineTransform(scaleX: mx, y: my))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(3 * scale))
            .cropped(to: extent)
        let invert = CIFilter.colorInvert()
        invert.inputImage = fitted
        guard let backgroundMask = invert.outputImage else { return image }

        let blur = CIFilter.maskedVariableBlur()
        blur.inputImage = image.clampedToExtent()
        blur.mask = backgroundMask
        blur.radius = Float(28 * scale * CGFloat(1.4 / aperture))
        return (blur.outputImage ?? image).cropped(to: extent)
    }

    /// Fast person mask for live preview / cinematic video.
    static func liveMask(for pixelBuffer: CVPixelBuffer, request: VNGeneratePersonSegmentationRequest) -> CIImage? {
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        try? handler.perform([request])
        guard let mask = request.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: mask)
    }

    /// High quality mask of any subject (people, pets, objects) for still photos.
    static func photoMask(for image: CIImage) -> CIImage? {
        // Work on a ~2K copy for speed; the mask is scaled up afterwards.
        let longSide = max(image.extent.width, image.extent.height)
        let s = min(1, 2048 / longSide)
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let handler = VNImageRequestHandler(ciImage: small, options: [:])

        let subject = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([subject])) != nil,
           let observation = subject.results?.first,
           let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler) {
            return CIImage(cvPixelBuffer: buffer)
        }

        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .accurate
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        guard (try? handler.perform([person])) != nil, let buffer = person.results?.first?.pixelBuffer else { return nil }
        return CIImage(cvPixelBuffer: buffer)
    }
}
