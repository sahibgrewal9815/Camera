import SwiftUI

/// Swipeable row of film looks with live thumbnails of what the camera sees.
struct LooksStrip: View {
    @ObservedObject var camera: CameraEngine
    @ObservedObject var live: LiveData
    var onOpenRecipe: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(camera.recipes) { recipe in
                            let selected = recipe.id == camera.selectedRecipe.id
                            Button {
                                if selected { onOpenRecipe() } else { camera.selectedRecipe = recipe }
                            } label: {
                                VStack(spacing: 5) {
                                    ZStack {
                                        if let thumb = live.lookThumbnails[recipe.id] {
                                            Image(uiImage: thumb).resizable().scaledToFill()
                                        } else {
                                            Color.white.opacity(0.08)
                                        }
                                    }
                                    .frame(width: 58, height: 58)
                                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .stroke(selected ? .yellow : .white.opacity(0.15), lineWidth: selected ? 2 : 0.5)
                                    )
                                    Text(recipe.name)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(selected ? .yellow : .white)
                                        .lineLimit(1)
                                }
                                .frame(width: 66)
                            }
                            .buttonStyle(PressScaleStyle())
                            .id(recipe.id)
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .onAppear { proxy.scrollTo(camera.selectedRecipe.id, anchor: .center) }
            }

            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled")
                Slider(value: $camera.lookIntensity, in: 0...1)
                    .tint(.yellow)
                    .disabled(camera.selectedRecipe.isNeutral)
                Text("\(Int(camera.lookIntensity * 100))")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .frame(width: 30)
                Button(action: onOpenRecipe) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .frame(width: 34, height: 34)
                        .glassBackground(Circle())
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
        }
        .padding(.vertical, 12)
        .glassPanel(cornerRadius: 26)
        .sensoryFeedback(.selection, trigger: camera.selectedRecipe.id)
    }
}
