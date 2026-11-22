import Foundation

/// The base colour science of a look, like a camera's "film simulation".
enum FilmSimulation: String, Codable, CaseIterable, Identifiable {
    case natural = "NATURAL"
    case provia = "PROVIA"
    case velvia = "VELVIA"
    case astia = "ASTIA"
    case classicChrome = "CLASSIC CHROME"
    case classicNeg = "CLASSIC NEG"
    case eterna = "ETERNA"
    case acros = "ACROS"
    case portra = "PORTRA"
    case gold = "GOLD"
    case ektar = "EKTAR"
    case kodachrome = "KODACHROME"
    case triX = "TRI-X"
    case tungsten800 = "TUNGSTEN 800"
    case tealOrange = "TEAL & ORANGE"
    case instant = "INSTANT"
    case vintage = "VINTAGE 70s"

    var id: String { rawValue }
    var isMonochrome: Bool { self == .acros || self == .triX }
}

enum EffectStrength: String, Codable, CaseIterable, Identifiable {
    case off = "Off", weak = "Weak", strong = "Strong"
    var id: String { rawValue }
    var amount: Float {
        switch self {
        case .off: 0
        case .weak: 0.5
        case .strong: 1
        }
    }
}

enum GrainSize: String, Codable, CaseIterable, Identifiable {
    case small = "Small", large = "Large"
    var id: String { rawValue }
}

/// A complete look, laid out like a Fujifilm film recipe card.
struct FilmRecipe: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var subtitle: String = ""
    var simulation: FilmSimulation
    var whiteBalance: Int? = nil          // Kelvin; nil = AUTO
    var wbRed = 0                          // -9...9
    var wbBlue = 0                         // -9...9
    var grain: EffectStrength = .off
    var grainSize: GrainSize = .small
    var colorChrome: EffectStrength = .off
    var colorChromeBlue: EffectStrength = .off
    var dynamicRange = 100                 // 100 / 200 / 400
    var highlight: Double = 0              // -2...4
    var shadow: Double = 0                 // -2...4
    var color = 0                          // -4...4
    var sharpness = 0                      // -4...4
    var noiseReduction = 0                 // -4...4
    var clarity = 0                        // -5...5
    var halation: Double = 0               // 0...1 (extra, for cine/vintage looks)
    var vignette: Double = 0               // 0...1
    var isCustom = false

    var isNeutral: Bool {
        simulation == .natural && whiteBalance == nil && wbRed == 0 && wbBlue == 0 && grain == .off
            && colorChrome == .off && colorChromeBlue == .off && dynamicRange == 100 && highlight == 0
            && shadow == 0 && color == 0 && sharpness == 0 && noiseReduction == 0 && clarity == 0
            && halation == 0 && vignette == 0
    }

    var whiteBalanceLabel: String { whiteBalance.map { "\($0)K" } ?? "AUTO" }
    var grainLabel: String { grain == .off ? "Off" : "\(grain.rawValue)\n\(grainSize.rawValue)" }

    static func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
    static func signed(_ value: Double) -> String { value > 0 ? String(format: "+%.1f", value) : String(format: "%.1f", value) }
}

// MARK: - Built-in recipes

extension FilmRecipe {
    static let natural = FilmRecipe(name: "Natural", subtitle: "No look", simulation: .natural)

    static let presets: [FilmRecipe] = [
        natural,
        // The four recipes from the cards you shared.
        FilmRecipe(name: "Portra 800", subtitle: "Film Recipe · Classic Chrome base", simulation: .classicChrome,
                   whiteBalance: 6600, wbRed: -1, wbBlue: -3, grain: .strong, grainSize: .large,
                   colorChrome: .strong, colorChromeBlue: .off, dynamicRange: 400, highlight: -2, shadow: -0.5,
                   color: 3, sharpness: -2, noiseReduction: -4, clarity: -3),
        FilmRecipe(name: "Leica X", subtitle: "Film Recipe · Street", simulation: .classicChrome,
                   wbRed: 1, wbBlue: -2, grain: .weak, grainSize: .small, colorChrome: .strong,
                   colorChromeBlue: .strong, dynamicRange: 200, highlight: -1, shadow: 0, color: 4,
                   sharpness: 0, noiseReduction: -4, clarity: 0),
        FilmRecipe(name: "Alpine Gold", subtitle: "Film Recipe · Warm summer", simulation: .classicChrome,
                   wbRed: 5, wbBlue: -6, colorChrome: .strong, colorChromeBlue: .weak, dynamicRange: 400,
                   highlight: -2, shadow: -2, color: 3, sharpness: 1, noiseReduction: -2, clarity: 0),
        FilmRecipe(name: "The Times", subtitle: "Teal sky · warm skin · grain", simulation: .tealOrange,
                   wbRed: 1, wbBlue: -1, grain: .strong, grainSize: .large, colorChrome: .weak,
                   dynamicRange: 400, highlight: -1, shadow: 1, color: 1, sharpness: -1, clarity: -1,
                   halation: 0.25, vignette: 0.35),

        // Fujifilm-style
        FilmRecipe(name: "Classic Chrome", subtitle: "Muted documentary colour", simulation: .classicChrome,
                   colorChrome: .weak, dynamicRange: 200, shadow: 1),
        FilmRecipe(name: "Classic Neg", subtitle: "Superia-like snapshot film", simulation: .classicNeg,
                   grain: .weak, colorChrome: .strong, dynamicRange: 200, highlight: -1, shadow: 1, color: 1),
        FilmRecipe(name: "Velvia", subtitle: "Punchy landscape slide film", simulation: .velvia,
                   colorChrome: .strong, colorChromeBlue: .strong, highlight: 0, shadow: 1, color: 2, sharpness: 1),
        FilmRecipe(name: "Eterna", subtitle: "Soft cinema film", simulation: .eterna,
                   grain: .weak, dynamicRange: 400, highlight: -1, shadow: -1, color: -1, sharpness: -1),
        FilmRecipe(name: "Acros", subtitle: "Fine-grain black & white", simulation: .acros,
                   grain: .weak, grainSize: .small, shadow: 1, sharpness: 1),

        // Kodak-style
        FilmRecipe(name: "Portra 400", subtitle: "Soft pastel skin tones", simulation: .portra,
                   whiteBalance: 5800, grain: .weak, dynamicRange: 400, highlight: -1, shadow: -1, clarity: -1),
        FilmRecipe(name: "Gold 200", subtitle: "Golden everyday film", simulation: .gold,
                   grain: .weak, grainSize: .large, dynamicRange: 200, shadow: 1, color: 1, vignette: 0.2),
        FilmRecipe(name: "Ektar 100", subtitle: "Vivid fine-grain colour", simulation: .ektar,
                   colorChrome: .weak, highlight: 0, shadow: 1, color: 1, sharpness: 1),
        FilmRecipe(name: "Kodachrome", subtitle: "Classic 64 slide look", simulation: .kodachrome,
                   grain: .weak, colorChrome: .strong, colorChromeBlue: .weak, shadow: 2, vignette: 0.2),
        FilmRecipe(name: "Tri-X 400", subtitle: "Gritty black & white", simulation: .triX,
                   grain: .strong, grainSize: .large, shadow: 2, sharpness: 1, vignette: 0.25),

        // Vintage / cine
        FilmRecipe(name: "Cine 800T", subtitle: "Tungsten night film + halation", simulation: .tungsten800,
                   grain: .strong, grainSize: .small, dynamicRange: 200, highlight: -1, halation: 0.6, vignette: 0.2),
        FilmRecipe(name: "Instant", subtitle: "Faded instant print", simulation: .instant,
                   grain: .weak, highlight: -2, shadow: -2, color: -1, sharpness: -2, clarity: -2, vignette: 0.45),
        FilmRecipe(name: "Vintage 70s", subtitle: "Warm, faded, nostalgic", simulation: .vintage,
                   grain: .strong, grainSize: .large, highlight: -1, shadow: -1, color: -1, sharpness: -1,
                   clarity: -2, halation: 0.3, vignette: 0.4),
    ]
}
