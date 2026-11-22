import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import simd

/// Turns a `FilmRecipe` into a Core Image filter chain. The same chain runs on the live
/// viewfinder, on video frames while recording, and on full-resolution photos.
final class FilmRenderer {
    static let shared = FilmRenderer()

    private let cubeSize = 33
    private var cubeCache: [String: Data] = [:]
    private let lock = NSLock()
    private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// - Parameters:
    ///   - intensity: 0 = original, 1 = full look.
    ///   - animateGrain: moves the grain every call so video grain "dances" like real film.
    func apply(_ recipe: FilmRecipe, to input: CIImage, intensity: Double = 1, animateGrain: Bool = false) -> CIImage {
        guard !recipe.isNeutral, intensity > 0.001 else { return input }
        let extent = input.extent
        let scale = max(extent.width, extent.height) / 1920
        var image = input

        // 1. White balance (Kelvin + red/blue shift)
        if let kelvin = recipe.whiteBalance {
            let wb = CIFilter.temperatureAndTint()
            wb.inputImage = image
            wb.neutral = CIVector(x: 6500 + CGFloat(kelvin - 5500), y: 0)
            wb.targetNeutral = CIVector(x: 6500, y: 0)
            image = wb.outputImage ?? image
        }
        if recipe.wbRed != 0 || recipe.wbBlue != 0 {
            let m = CIFilter.colorMatrix()
            m.inputImage = image
            m.rVector = CIVector(x: 1 + CGFloat(recipe.wbRed) * 0.022, y: 0, z: 0, w: 0)
            m.gVector = CIVector(x: 0, y: 1, z: 0, w: 0)
            m.bVector = CIVector(x: 0, y: 0, z: 1 + CGFloat(recipe.wbBlue) * 0.022, w: 0)
            m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
            image = m.outputImage ?? image
        }

        // 2. Film simulation 3D LUT (+ colour chrome effects baked in)
        let cube = CIFilter.colorCubeWithColorSpace()
        cube.inputImage = image
        cube.cubeDimension = Float(cubeSize)
        cube.cubeData = cubeData(for: recipe)
        cube.colorSpace = sRGB
        image = cube.outputImage ?? image

        // 3. Tone: highlight / shadow / dynamic range
        image = toneCurve(image, recipe: recipe)

        // 4. Colour (saturation)
        if recipe.color != 0, !recipe.simulation.isMonochrome {
            let c = CIFilter.colorControls()
            c.inputImage = image
            c.saturation = 1 + Float(recipe.color) * 0.07
            c.brightness = 0
            c.contrast = 1
            image = c.outputImage ?? image
        }

        // 5. Clarity (local contrast)
        if recipe.clarity > 0 {
            let u = CIFilter.unsharpMask()
            u.inputImage = image
            u.radius = Float(24 * scale)
            u.intensity = Float(recipe.clarity) * 0.12
            image = (u.outputImage ?? image).cropped(to: extent)
        } else if recipe.clarity < 0 {
            let soft = image.clampedToExtent().applyingGaussianBlur(sigma: Double(10 * scale)).cropped(to: extent)
            image = dissolve(from: image, to: soft, amount: Double(-recipe.clarity) * 0.07)
        }

        // 6. Sharpness and noise reduction
        if recipe.sharpness > 0 {
            let s = CIFilter.sharpenLuminance()
            s.inputImage = image
            s.sharpness = Float(recipe.sharpness) * 0.15
            s.radius = Float(1.5 * scale)
            image = s.outputImage ?? image
        } else if recipe.sharpness < 0 {
            image = image.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(-recipe.sharpness) * 0.3 * Double(scale))
                .cropped(to: extent)
        }
        if recipe.noiseReduction > 0 {
            let n = CIFilter.noiseReduction()
            n.inputImage = image
            n.noiseLevel = Float(recipe.noiseReduction) * 0.008
            n.sharpness = 0.4
            image = n.outputImage ?? image
        }

        // 7. Halation (red glow around bright lights, like cine film)
        if recipe.halation > 0 {
            image = halation(image, amount: recipe.halation, scale: scale, extent: extent)
        }

        // 8. Vignette
        if recipe.vignette > 0 {
            let v = CIFilter.vignetteEffect()
            v.inputImage = image
            v.center = CGPoint(x: extent.midX, y: extent.midY)
            v.radius = Float(hypot(extent.width, extent.height) * 0.42)
            v.intensity = Float(recipe.vignette)
            v.falloff = 0.6
            image = v.outputImage ?? image
        }

        // 9. Grain
        if recipe.grain != .off {
            image = grain(image, strength: recipe.grain, size: recipe.grainSize, scale: scale,
                          extent: extent, animate: animateGrain)
        }

        image = image.cropped(to: extent)
        return intensity < 0.999 ? dissolve(from: input, to: image, amount: intensity) : image
    }

    // MARK: Steps

    private func toneCurve(_ image: CIImage, recipe: FilmRecipe) -> CIImage {
        let h = CGFloat(recipe.highlight), s = CGFloat(recipe.shadow)
        let dr: CGFloat = recipe.dynamicRange >= 400 ? 0.06 : (recipe.dynamicRange >= 200 ? 0.03 : 0)
        guard h != 0 || s != 0 || dr != 0 else { return image }
        let curve = CIFilter.toneCurve()
        curve.inputImage = image
        curve.point0 = CGPoint(x: 0, y: max(0, -s * 0.015))
        curve.point1 = CGPoint(x: 0.25, y: 0.25 - s * 0.018)
        curve.point2 = CGPoint(x: 0.5, y: 0.5)
        curve.point3 = CGPoint(x: 0.75, y: 0.75 + h * 0.018 - dr)
        curve.point4 = CGPoint(x: 1, y: 1 - dr * 0.5 - max(0, -h) * 0.01)
        return curve.outputImage ?? image
    }

    private func halation(_ image: CIImage, amount: Double, scale: CGFloat, extent: CGRect) -> CIImage {
        let mono = CIFilter.colorControls()
        mono.inputImage = image
        mono.saturation = 0
        mono.brightness = 0
        mono.contrast = 1
        let threshold = CIFilter.toneCurve()
        threshold.inputImage = mono.outputImage
        threshold.point0 = CGPoint(x: 0, y: 0)
        threshold.point1 = CGPoint(x: 0.6, y: 0)
        threshold.point2 = CGPoint(x: 0.8, y: 0.25)
        threshold.point3 = CGPoint(x: 0.9, y: 0.6)
        threshold.point4 = CGPoint(x: 1, y: 1)
        guard let bright = threshold.outputImage else { return image }
        let glow = bright.clampedToExtent().applyingGaussianBlur(sigma: Double(14 * scale)).cropped(to: extent)
        let tint = CIFilter.colorMatrix()
        tint.inputImage = glow
        let a = CGFloat(amount)
        tint.rVector = CIVector(x: 1.0 * a, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: 0.28 * a, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: 0.12 * a, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        let screen = CIFilter.screenBlendMode()
        screen.inputImage = tint.outputImage
        screen.backgroundImage = image
        return (screen.outputImage ?? image).cropped(to: extent)
    }

    private func grain(_ image: CIImage, strength: EffectStrength, size: GrainSize, scale: CGFloat,
                       extent: CGRect, animate: Bool) -> CIImage {
        guard var noise = CIFilter.randomGenerator().outputImage else { return image }
        if animate {
            noise = noise.transformed(by: CGAffineTransform(translationX: CGFloat.random(in: 0...512),
                                                             y: CGFloat.random(in: 0...512)))
        }
        let grainScale = max(1, scale) * (size == .large ? 2.2 : 1.1)
        noise = noise.transformed(by: CGAffineTransform(scaleX: grainScale, y: grainScale))
        let k: CGFloat = strength == .strong ? 0.22 : 0.12
        let m = CIFilter.colorMatrix()
        m.inputImage = noise
        m.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        m.gVector = CIVector(x: k, y: 0, z: 0, w: 0)
        m.bVector = CIVector(x: k, y: 0, z: 0, w: 0)
        m.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        m.biasVector = CIVector(x: 0.5 - 0.5 * k, y: 0.5 - 0.5 * k, z: 0.5 - 0.5 * k, w: 1)
        guard let grainImage = m.outputImage?.cropped(to: extent) else { return image }
        let overlay = CIFilter.overlayBlendMode()
        overlay.inputImage = grainImage
        overlay.backgroundImage = image
        return overlay.outputImage ?? image
    }

    private func dissolve(from a: CIImage, to b: CIImage, amount: Double) -> CIImage {
        let d = CIFilter.dissolveTransition()
        d.inputImage = a
        d.targetImage = b
        d.time = Float(min(max(amount, 0), 1))
        return (d.outputImage ?? b).cropped(to: a.extent)
    }

    // MARK: 3D LUT generation

    private func cubeData(for recipe: FilmRecipe) -> Data {
        let key = "\(recipe.simulation.rawValue)|\(recipe.colorChrome.rawValue)|\(recipe.colorChromeBlue.rawValue)"
        lock.lock()
        defer { lock.unlock() }
        if let cached = cubeCache[key] { return cached }

        let look = BaseLook.for(recipe.simulation)
        let chrome = recipe.colorChrome.amount
        let chromeBlue = recipe.colorChromeBlue.amount
        let n = cubeSize
        var values = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        let step = 1 / Float(n - 1)
        for b in 0..<n {
            for g in 0..<n {
                for r in 0..<n {
                    let out = look.transform(SIMD3(Float(r) * step, Float(g) * step, Float(b) * step),
                                             chrome: chrome, chromeBlue: chromeBlue)
                    values[i] = out.x
                    values[i + 1] = out.y
                    values[i + 2] = out.z
                    values[i + 3] = 1
                    i += 4
                }
            }
        }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        cubeCache[key] = data
        return data
    }
}

// MARK: - Film colour science

/// Hue-selective adjustment. Hues in degrees: red 0, orange 30, yellow 60, green 120, cyan 180, blue 220, magenta 300.
struct HueBand {
    var center: Float
    var width: Float = 45
    var hueShift: Float = 0
    var sat: Float = 1
    var lum: Float = 1
}

struct BaseLook {
    var saturation: Float = 1
    var contrast: Float = 0           // -1...1, S-curve
    var fade: Float = 0               // lifted blacks
    var warmth: Float = 0
    var shadowTint = SIMD3<Float>(0, 0, 0)
    var highlightTint = SIMD3<Float>(0, 0, 0)
    var bands: [HueBand] = []
    var mono: SIMD3<Float>? = nil     // channel mix for black & white

    static func `for`(_ sim: FilmSimulation) -> BaseLook {
        switch sim {
        case .natural:
            return BaseLook()
        case .provia:
            return BaseLook(saturation: 1.08, contrast: 0.15)
        case .velvia:
            return BaseLook(saturation: 1.35, contrast: 0.35, bands: [
                HueBand(center: 0, sat: 1.15), HueBand(center: 120, sat: 1.2),
                HueBand(center: 220, sat: 1.1, lum: 0.85)])
        case .astia:
            return BaseLook(saturation: 1.05, contrast: -0.05, bands: [
                HueBand(center: 25, width: 30, sat: 0.95, lum: 1.03)])
        case .classicChrome:
            return BaseLook(saturation: 0.78, contrast: 0.15, fade: 0.02,
                            shadowTint: SIMD3(-0.01, 0, 0.015), bands: [
                HueBand(center: 0, sat: 0.85, lum: 0.95),
                HueBand(center: 25, width: 30, sat: 0.9),
                HueBand(center: 110, width: 60, hueShift: -15, sat: 0.7),
                HueBand(center: 215, width: 50, hueShift: -10, sat: 0.75, lum: 0.9)])
        case .classicNeg:
            return BaseLook(saturation: 0.9, contrast: 0.35, fade: 0.02,
                            shadowTint: SIMD3(-0.02, 0.01, 0.03), highlightTint: SIMD3(0.03, 0.015, -0.02), bands: [
                HueBand(center: 0, hueShift: 5, sat: 1.05),
                HueBand(center: 115, width: 60, hueShift: 15, sat: 0.8)])
        case .eterna:
            return BaseLook(saturation: 0.7, contrast: -0.25, fade: 0.04,
                            shadowTint: SIMD3(-0.005, 0.005, 0.01), highlightTint: SIMD3(0.01, 0.005, -0.005))
        case .acros:
            return BaseLook(contrast: 0.3, mono: SIMD3(0.30, 0.60, 0.10))
        case .triX:
            return BaseLook(contrast: 0.45, fade: 0.03, mono: SIMD3(0.35, 0.55, 0.10))
        case .portra:
            return BaseLook(saturation: 0.88, contrast: -0.05, fade: 0.02, warmth: 0.03,
                            highlightTint: SIMD3(0.02, 0.01, -0.01), bands: [
                HueBand(center: 25, width: 30, hueShift: 3, sat: 0.9, lum: 1.04),
                HueBand(center: 115, width: 60, hueShift: -10, sat: 0.8),
                HueBand(center: 215, width: 50, hueShift: -8, sat: 0.85)])
        case .gold:
            return BaseLook(saturation: 1.1, contrast: 0.15, warmth: 0.06,
                            highlightTint: SIMD3(0.03, 0.02, -0.02), bands: [
                HueBand(center: 55, width: 35, sat: 1.15)])
        case .ektar:
            return BaseLook(saturation: 1.3, contrast: 0.25, bands: [
                HueBand(center: 0, sat: 1.2), HueBand(center: 220, sat: 1.2, lum: 0.9)])
        case .kodachrome:
            return BaseLook(saturation: 1.2, contrast: 0.35,
                            shadowTint: SIMD3(0, 0, -0.01), highlightTint: SIMD3(0.015, 0.01, 0), bands: [
                HueBand(center: 0, hueShift: -5, sat: 1.25),
                HueBand(center: 55, width: 35, sat: 1.1),
                HueBand(center: 215, hueShift: 8, sat: 1.1, lum: 0.85)])
        case .tungsten800:
            return BaseLook(saturation: 0.95, contrast: 0.2, warmth: -0.04,
                            shadowTint: SIMD3(-0.02, 0, 0.035), highlightTint: SIMD3(0.03, 0, -0.01))
        case .tealOrange:
            return BaseLook(saturation: 1, contrast: 0.2,
                            shadowTint: SIMD3(-0.03, 0.01, 0.04), highlightTint: SIMD3(0.04, 0.015, -0.03), bands: [
                HueBand(center: 28, width: 35, sat: 1.15),
                HueBand(center: 120, width: 60, hueShift: 40, sat: 0.7),
                HueBand(center: 215, width: 60, hueShift: -25, sat: 0.9)])
        case .instant:
            return BaseLook(saturation: 0.85, contrast: -0.1, fade: 0.08,
                            shadowTint: SIMD3(0, 0.02, 0.03), highlightTint: SIMD3(0.03, 0.02, -0.01))
        case .vintage:
            return BaseLook(saturation: 0.8, contrast: 0.05, fade: 0.06, warmth: 0.08,
                            shadowTint: SIMD3(0.03, 0.01, -0.02), highlightTint: SIMD3(0.04, 0.025, -0.03), bands: [
                HueBand(center: 115, width: 60, hueShift: -20, sat: 0.7)])
        }
    }

    func transform(_ input: SIMD3<Float>, chrome: Float, chromeBlue: Float) -> SIMD3<Float> {
        var rgb = input
        if let mono {
            rgb = SIMD3(repeating: simd_dot(rgb, mono))
        } else {
            var (h, s, v) = Self.rgbToHsv(rgb)
            for band in bands {
                var w = max(0, 1 - Self.hueDistance(h, band.center) / band.width)
                w = w * w * (3 - 2 * w)
                w *= min(1, s * 3)   // leave greys alone
                h += band.hueShift * w
                s *= 1 + (band.sat - 1) * w
                v *= 1 + (band.lum - 1) * w
            }
            s *= saturation
            if chrome > 0 { v *= 1 - chrome * 0.12 * s * s }
            if chromeBlue > 0 {
                let w = max(0, 1 - Self.hueDistance(h, 220) / 50)
                v *= 1 - chromeBlue * 0.18 * w * s
                s *= 1 + chromeBlue * 0.1 * w
            }
            h = fmodf(h + 360, 360)
            rgb = Self.hsvToRgb(h, simd_clamp(s, 0, 1), max(0, v))
            rgb += SIMD3(warmth, warmth * 0.4, -warmth)
        }
        if contrast != 0 {
            let x = simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
            let sCurve = x * x * (3 - 2 * x)
            rgb = x + contrast * (sCurve - x)
        }
        let l = simd_dot(simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1)), SIMD3(0.2126, 0.7152, 0.0722))
        rgb += shadowTint * (1 - l) * (1 - l) + highlightTint * l * l
        rgb = fade + rgb * (1 - fade)
        return simd_clamp(rgb, SIMD3(repeating: 0), SIMD3(repeating: 1))
    }

    static func hueDistance(_ a: Float, _ b: Float) -> Float {
        let d = abs(fmodf(a - b + 540, 360) - 180)
        return d
    }

    static func rgbToHsv(_ c: SIMD3<Float>) -> (Float, Float, Float) {
        let maxV = max(c.x, max(c.y, c.z)), minV = min(c.x, min(c.y, c.z))
        let delta = maxV - minV
        var h: Float = 0
        if delta > 1e-5 {
            if maxV == c.x { h = 60 * fmodf((c.y - c.z) / delta, 6) }
            else if maxV == c.y { h = 60 * ((c.z - c.x) / delta + 2) }
            else { h = 60 * ((c.x - c.y) / delta + 4) }
        }
        if h < 0 { h += 360 }
        let s = maxV > 1e-5 ? delta / maxV : 0
        return (h, s, maxV)
    }

    static func hsvToRgb(_ h: Float, _ s: Float, _ v: Float) -> SIMD3<Float> {
        let c = v * s
        let x = c * (1 - abs(fmodf(h / 60, 2) - 1))
        let m = v - c
        let rgb: SIMD3<Float>
        switch h {
        case ..<60: rgb = SIMD3(c, x, 0)
        case ..<120: rgb = SIMD3(x, c, 0)
        case ..<180: rgb = SIMD3(0, c, x)
        case ..<240: rgb = SIMD3(0, x, c)
        case ..<300: rgb = SIMD3(x, 0, c)
        default: rgb = SIMD3(c, 0, x)
        }
        return rgb + m
    }
}
