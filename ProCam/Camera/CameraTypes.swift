import AVFoundation
import CoreImage
import Metal
import SwiftUI

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case photo, depth
    case video, cinematic, action, sloMo, timelapse

    var id: String { rawValue }
    var isVideo: Bool { ![.photo, .depth].contains(self) }
    var usesDepthEffect: Bool { self == .depth || self == .cinematic }
    var recordsAudio: Bool { [.video, .cinematic, .action].contains(self) }

    var title: String {
        switch self {
        case .photo: "PHOTO"
        case .depth: "DEPTH"
        case .video: "VIDEO"
        case .cinematic: "CINEMATIC"
        case .action: "ACTION"
        case .sloMo: "SLO-MO"
        case .timelapse: "TIMELAPSE"
        }
    }
}

enum VideoResolution: String, Codable, CaseIterable, Identifiable {
    case hd1080 = "HD", uhd4K = "4K"
    var id: String { rawValue }
}

enum PhotoAspect: String, Codable, CaseIterable, Identifiable {
    case threeFour = "4:3", square = "1:1", nineSixteen = "16:9"
    var id: String { rawValue }
    /// width / height in portrait
    var ratio: CGFloat {
        switch self {
        case .threeFour: 3.0 / 4.0
        case .square: 1
        case .nineSixteen: 9.0 / 16.0
        }
    }
    var next: PhotoAspect {
        switch self {
        case .threeFour: .square
        case .square: .nineSixteen
        case .nineSixteen: .threeFour
        }
    }
}

enum StabilizationChoice: String, Codable, CaseIterable, Identifiable {
    case off = "Off"
    case standard = "Standard"
    case cinematic = "Cinematic"
    case cinematicExtended = "Extended"
    case enhanced = "Action (Enhanced)"

    var id: String { rawValue }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        case .cinematicExtended: .cinematicExtended
        case .enhanced: .cinematicExtendedEnhanced
        }
    }
    var symbol: String {
        switch self {
        case .off: "hand.raised.slash"
        case .standard: "hand.raised"
        case .cinematic, .cinematicExtended: "gyroscope"
        case .enhanced: "figure.run"
        }
    }
}

struct CameraSettings: Codable, Equatable {
    var showGrid = false
    var showLevel = true
    var showHistogram = true
    var photoAspect: PhotoAspect = .threeFour
    var videoResolution: VideoResolution = .uhd4K
    var frameRate = 30
    var stabilization: StabilizationChoice = .cinematic
    var mirrorFrontCamera = true
    var cinematicFrameRate = 24
    var timelapseInterval = 0.5     // seconds between frames
    var selectedRecipeName = FilmRecipe.natural.name
    var lookIntensity = 1.0

    static func load() -> CameraSettings {
        guard let data = UserDefaults.standard.data(forKey: "settings"),
              let settings = try? JSONDecoder().decode(CameraSettings.self, from: data) else { return CameraSettings() }
        return settings
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "settings") }
    }
}

/// Manual ("Pro") controls state.
struct ProState: Equatable {
    var isoAuto = true
    var iso: Float = 100
    var minISO: Float = 32
    var maxISO: Float = 3200

    var shutterAuto = true
    var shutter: Double = 1.0 / 60     // seconds
    var minShutter: Double = 1.0 / 8000
    var maxShutter: Double = 1.0 / 2

    var wbAuto = true
    var kelvin: Float = 5500

    var focusAuto = true
    var lensPosition: Float = 0.5

    var exposureBias: Float = 0
    var minBias: Float = -4
    var maxBias: Float = 4

    var aperture: Float = 1.8

    static let isoStops: [Float] = [25, 32, 50, 64, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800,
                                    1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800]
    static let shutterStops: [Double] = [1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250,
                                         1.0 / 125, 1.0 / 60, 1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1]

    static func shutterLabel(_ s: Double) -> String {
        s >= 0.5 ? String(format: "%.1f\"", s) : "1/\(Int((1 / s).rounded()))"
    }
}

/// Shared Metal-backed Core Image context.
enum RenderContext {
    static let device: MTLDevice = MTLCreateSystemDefaultDevice()!
    static let ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "ProCam"])
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
}

/// Hands the latest filtered viewfinder frame to the Metal preview.
final class FrameStore {
    private let lock = NSLock()
    private var image: CIImage?
    private(set) var version = 0

    func update(_ newImage: CIImage) {
        lock.lock()
        image = newImage
        version &+= 1
        lock.unlock()
    }

    func latest() -> (CIImage?, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (image, version)
    }
}

/// Maps between view coordinates and normalized image coordinates for an aspect-fill preview.
struct PreviewMapping {
    var viewSize: CGSize
    var imageSize: CGSize
    var mirrored: Bool

    private var fill: (scale: CGFloat, dx: CGFloat, dy: CGFloat) {
        guard imageSize.width > 0, imageSize.height > 0 else { return (1, 0, 0) }
        let s = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        return (s, (viewSize.width - imageSize.width * s) / 2, (viewSize.height - imageSize.height * s) / 2)
    }

    /// View point → normalized image point (0...1, top-left origin).
    func imagePoint(from p: CGPoint) -> CGPoint {
        let f = fill
        var u = (p.x - f.dx) / (imageSize.width * f.scale)
        let v = (p.y - f.dy) / (imageSize.height * f.scale)
        if mirrored { u = 1 - u }
        return CGPoint(x: min(max(u, 0), 1), y: min(max(v, 0), 1))
    }

    /// Normalized image rect → view rect.
    func viewRect(from r: CGRect) -> CGRect {
        let f = fill
        let w = imageSize.width * f.scale, h = imageSize.height * f.scale
        let x = mirrored ? (1 - r.maxX) : r.minX
        return CGRect(x: f.dx + x * w, y: f.dy + r.minY * h, width: r.width * w, height: r.height * h)
    }
}
