import SwiftUI

struct SettingsSheet: View {
    @ObservedObject var camera: CameraEngine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    Picker("Aspect ratio", selection: $camera.settings.photoAspect) {
                        ForEach(PhotoAspect.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Grid", isOn: $camera.settings.showGrid)
                    Toggle("Level", isOn: $camera.settings.showLevel)
                    Toggle("Mirror front camera", isOn: $camera.settings.mirrorFrontCamera)
                    if camera.livePhotoSupported {
                        Toggle("Live Photos", isOn: $camera.livePhotoEnabled)
                    }
                    if camera.proRAWSupported {
                        Toggle("Apple ProRAW", isOn: $camera.proRAWEnabled)
                    }
                }

                Section {
                    Picker("Resolution", selection: $camera.settings.videoResolution) {
                        ForEach(VideoResolution.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Frame rate", selection: $camera.settings.frameRate) {
                        ForEach([24, 25, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Stabilization", selection: $camera.settings.stabilization) {
                        ForEach(StabilizationChoice.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Cinematic frame rate", selection: $camera.settings.cinematicFrameRate) {
                        ForEach([24, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    Picker("Time-lapse speed", selection: $camera.settings.timelapseInterval) {
                        Text("Fast (1 frame / 0.25s)").tag(0.25)
                        Text("Normal (1 frame / 0.5s)").tag(0.5)
                        Text("Slow (1 frame / 1s)").tag(1.0)
                        Text("Very slow (1 frame / 2s)").tag(2.0)
                    }
                } header: {
                    Text("Video")
                } footer: {
                    Text("Cinematic and Time-lapse always use extended stabilization; Action uses the strongest (enhanced) mode at 1080p.")
                }

                Section("Pro") {
                    Toggle("Live histogram", isOn: $camera.settings.showHistogram)
                }

                let customs = camera.recipes.filter(\.isCustom)
                if !customs.isEmpty {
                    Section("My recipes") {
                        ForEach(customs) { recipe in
                            Text(recipe.name)
                        }
                        .onDelete { offsets in
                            offsets.map { customs[$0] }.forEach(camera.deleteRecipe)
                        }
                    }
                }

                Section {
                    LabeledContent("Tip", value: "Double-tap a subject to track focus")
                    LabeledContent("Camera Control", value: "Zoom · Exposure · Looks · Strength")
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(32)
        .preferredColorScheme(.dark)
    }
}
