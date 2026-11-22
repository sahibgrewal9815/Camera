import SwiftUI

/// A film recipe shown as a frosted card (like the recipe cards you shared). Tap any tile to change it.
struct RecipeCardView: View {
    @ObservedObject var camera: CameraEngine
    @State var recipe: FilmRecipe
    @State private var preview: UIImage?
    @State private var showSaveAlert = false
    @State private var newName = ""
    @Environment(\.dismiss) private var dismiss

    private let refresh = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            // Blurred photo behind the card, like the reference design.
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
                    .blur(radius: 40).opacity(0.7)
                    .ignoresSafeArea()
            }
            Color.black.opacity(0.25).ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    photo
                    rowOne
                    rowTwo
                    rowThree
                    extras
                    actions
                }
                .padding(20)
            }
        }
        .foregroundStyle(.white)
        .presentationDetents([.large])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(36)
        .onAppear(perform: renderPreview)
        .onChange(of: recipe) { _, _ in renderPreview() }
        .onReceive(refresh) { _ in renderPreview() }
        .alert("Save recipe", isPresented: $showSaveAlert) {
            TextField("Name", text: $newName)
            Button("Save") {
                var copy = recipe
                copy.name = newName.isEmpty ? "My Recipe" : newName
                camera.saveRecipe(copy, asNew: true)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.name)
                    .font(.system(size: 34, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(recipe.subtitle.isEmpty ? "Film Recipe" : recipe.subtitle)
                    .font(.system(size: 15))
                    .opacity(0.8)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("PRO").font(.system(size: 22, weight: .heavy))
                Text("CAM").font(.system(size: 22, weight: .heavy))
            }
            .overlay(alignment: .topTrailing) {
                Circle().fill(.red).frame(width: 7, height: 7).offset(x: 6, y: -2)
            }
        }
    }

    private var photo: some View {
        ZStack {
            if let preview {
                Image(uiImage: preview).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(height: 300)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var rowOne: some View {
        HStack(spacing: 10) {
            RecipeTile(value: recipe.simulation.rawValue, label: "Film simulations", large: true) {
                Picker("Film simulation", selection: $recipe.simulation) {
                    ForEach(FilmSimulation.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
            }
            RecipeTile(value: recipe.whiteBalanceLabel,
                       label: "Red: \(FilmRecipe.signed(recipe.wbRed)) Blue: \(FilmRecipe.signed(recipe.wbBlue))",
                       large: true) {
                Picker("White balance", selection: $recipe.whiteBalance) {
                    Text("AUTO").tag(Int?.none)
                    ForEach(Array(stride(from: 2500, through: 10000, by: 100)), id: \.self) { Text("\($0)K").tag(Int?.some($0)) }
                }
                Menu("Red shift") { intPicker(-9...9, $recipe.wbRed) }
                Menu("Blue shift") { intPicker(-9...9, $recipe.wbBlue) }
            }
            RecipeTile(value: recipe.grainLabel, label: "Grain Effect") {
                Picker("Grain", selection: $recipe.grain) {
                    ForEach(EffectStrength.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Size", selection: $recipe.grainSize) {
                    ForEach(GrainSize.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            .frame(width: 96)
        }
    }

    private var rowTwo: some View {
        HStack(spacing: 8) {
            RecipeTile(value: recipe.colorChrome.rawValue, label: "Color Effect") {
                Picker("Color Chrome Effect", selection: $recipe.colorChrome) {
                    ForEach(EffectStrength.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            RecipeTile(value: recipe.colorChromeBlue.rawValue, label: "Color FX Blue") {
                Picker("Color Chrome FX Blue", selection: $recipe.colorChromeBlue) {
                    ForEach(EffectStrength.allCases) { Text($0.rawValue).tag($0) }
                }
            }
            RecipeTile(value: "DR\(recipe.dynamicRange)", label: "Dynamic Range") {
                Picker("Dynamic range", selection: $recipe.dynamicRange) {
                    ForEach([100, 200, 400], id: \.self) { Text("DR\($0)").tag($0) }
                }
            }
            RecipeTile(value: FilmRecipe.signed(recipe.highlight), label: "Highlight") {
                halfStepPicker($recipe.highlight)
            }
            RecipeTile(value: FilmRecipe.signed(recipe.shadow), label: "Shadow") {
                halfStepPicker($recipe.shadow)
            }
        }
    }

    private var rowThree: some View {
        HStack(spacing: 8) {
            RecipeTile(value: FilmRecipe.signed(recipe.color), label: "Color") { intPicker(-4...4, $recipe.color) }
            RecipeTile(value: FilmRecipe.signed(recipe.sharpness), label: "Sharpness") { intPicker(-4...4, $recipe.sharpness) }
            RecipeTile(value: FilmRecipe.signed(recipe.noiseReduction), label: "ISO Denoise") {
                intPicker(-4...4, $recipe.noiseReduction)
            }
            RecipeTile(value: FilmRecipe.signed(recipe.clarity), label: "Clarity") { intPicker(-5...5, $recipe.clarity) }
            RecipeTile(value: "\(Int(camera.lookIntensity * 100))%", label: "Strength") {
                Picker("Strength", selection: $camera.lookIntensity) {
                    ForEach([0.25, 0.5, 0.75, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
            }
        }
    }

    private var extras: some View {
        VStack(spacing: 12) {
            labeledSlider("Halation", value: $recipe.halation)
            labeledSlider("Vignette", value: $recipe.vignette)
        }
        .padding(16)
        .glassBackground(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button {
                // Custom recipes are updated in place; an edited preset is used for now
                // and can be kept with "Save as new recipe".
                if recipe.isCustom { camera.saveRecipe(recipe, asNew: false) } else { camera.selectedRecipe = recipe }
                dismiss()
            } label: {
                Text("Use this look").bold().frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(.white, in: Capsule()).foregroundStyle(.black)
            }
            Button {
                newName = recipe.isCustom ? recipe.name : "\(recipe.name) Custom"
                showSaveAlert = true
            } label: {
                Text("Save as new recipe").bold().frame(maxWidth: .infinity).padding(.vertical, 14)
                    .glassBackground(Capsule())
            }
            if recipe.isCustom {
                Button(role: .destructive) {
                    camera.deleteRecipe(recipe)
                    dismiss()
                } label: {
                    Text("Delete recipe").frame(maxWidth: .infinity).padding(.vertical, 10)
                }
                .foregroundStyle(.red)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Helpers

    private func intPicker(_ range: ClosedRange<Int>, _ binding: Binding<Int>) -> some View {
        Picker("", selection: binding) {
            ForEach(Array(range.reversed()), id: \.self) { Text(FilmRecipe.signed($0)).tag($0) }
        }
    }

    private func halfStepPicker(_ binding: Binding<Double>) -> some View {
        Picker("", selection: binding) {
            ForEach(Array(stride(from: 4.0, through: -2.0, by: -0.5)), id: \.self) { Text(FilmRecipe.signed($0)).tag($0) }
        }
    }

    private func labeledSlider(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 13, weight: .semibold)).frame(width: 74, alignment: .leading)
            Slider(value: value, in: 0...1).tint(.white)
            Text("\(Int(value.wrappedValue * 100))").font(.system(size: 12, weight: .bold).monospacedDigit())
                .frame(width: 30)
        }
    }

    private func renderPreview() {
        let recipe = recipe
        DispatchQueue.global(qos: .userInitiated).async {
            let image = camera.renderPreview(of: recipe)
            DispatchQueue.main.async { if let image { preview = image } }
        }
    }
}

/// One frosted tile of the recipe card. Tapping it opens a menu to change the value.
struct RecipeTile<MenuContent: View>: View {
    let value: String
    let label: String
    var large = false
    @ViewBuilder var menu: () -> MenuContent

    var body: some View {
        Menu {
            menu()
        } label: {
            VStack(spacing: 8) {
                if large {
                    Text(value)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.55)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .padding(.horizontal, 6)
                        .background(.white.opacity(0.22), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    Text(value)
                        .font(.system(size: 20, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                }
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.85)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: large ? 100 : 72)
            .padding(8)
            .glassBackground(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }
}
