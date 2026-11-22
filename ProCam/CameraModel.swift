import AVFoundation
import Photos
import SwiftUI
import UIKit

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo = "PHOTO"
    case video = "VIDEO"
    var id: String { rawValue }
}

/// Owns the AVCaptureSession. All session/device work happens on `sessionQueue`;
/// @Published properties are only ever changed on the main thread.
final class CameraModel: NSObject, ObservableObject {

    // MARK: Published UI state
    @Published var isAuthorized: Bool?
    @Published var mode: CaptureMode = .photo
    @Published var flashMode: AVCaptureDevice.FlashMode = .auto
    @Published var flashAvailable = false
    @Published var livePhotoSupported = false
    @Published var livePhotoEnabled = true
    @Published var proRAWSupported = false
    @Published var proRAWEnabled = false
    @Published var showGrid = false
    @Published var timerSeconds = 0
    @Published var countdown: Int?
    @Published var zoomFactor: CGFloat = 1          // as shown to the user (0.5x, 1x, 2x…)
    @Published var zoomPresets: [CGFloat] = [1]
    @Published var maxDisplayZoom: CGFloat = 10
    @Published var minDisplayZoom: CGFloat = 1
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var lastThumbnail: UIImage?
    @Published var shutterBlink = false
    @Published var controlsFullscreen = false       // Camera Control overlay is showing

    // MARK: Capture plumbing
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "procam.session")
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var photoProcessors: [Int64: PhotoCaptureProcessor] = [:]
    private var isConfigured = false
    private var countdownTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var recordingStart = Date()

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.resetFocus() }
    }

    // MARK: Lifecycle

    func start() {
        Task {
            let granted = await Self.requestPermissions()
            await MainActor.run { self.isAuthorized = granted }
            guard granted else { return }
            sessionQueue.async {
                if !self.isConfigured { self.configureSession() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.movieOutput.isRecording { self.movieOutput.stopRecording() }
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private static func requestPermissions() async -> Bool {
        let video: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: video = true
        case .notDetermined: video = await AVCaptureDevice.requestAccess(for: .video)
        default: video = false
        }
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        return video
    }

    // MARK: Session setup (sessionQueue)

    private func configureSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = Self.bestDevice(for: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input),
              session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoInput = input
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()

        configurePhotoOutput()
        deviceDidChange()
        isConfigured = true
    }

    /// Prefers the multi-lens virtual camera so the system switches lenses automatically while zooming.
    private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices
        for type in types {
            if let device = devices.first(where: { $0.deviceType == type }) { return device }
        }
        return nil
    }

    /// Turns on the newest photo pipeline features the current device supports.
    private func configurePhotoOutput() {
        if let device = videoInput?.device {
            // Up to ~24MP by default (like the system camera), otherwise the largest available.
            let dims = device.activeFormat.supportedMaxPhotoDimensions
                .sorted { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
            if let best = dims.last(where: { Int($0.width) * Int($0.height) <= 25_000_000 }) ?? dims.last {
                photoOutput.maxPhotoDimensions = best
            }
        }
        photoOutput.isLivePhotoCaptureEnabled = photoOutput.isLivePhotoCaptureSupported
        photoOutput.isAppleProRAWEnabled = photoOutput.isAppleProRAWSupported
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = true }
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
        if photoOutput.isFastCapturePrioritizationSupported { photoOutput.isFastCapturePrioritizationEnabled = true }
        if photoOutput.isAutoDeferredPhotoDeliverySupported { photoOutput.isAutoDeferredPhotoDeliveryEnabled = true }

        let live = photoOutput.isLivePhotoCaptureSupported
        let raw = photoOutput.isAppleProRAWSupported
        DispatchQueue.main.async {
            self.livePhotoSupported = live
            self.proRAWSupported = raw
            if !raw { self.proRAWEnabled = false }
        }
    }

    /// Called whenever the active camera changes.
    private func deviceDidChange() {
        guard let device = videoInput?.device else { return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

        // On multi-lens cameras the raw zoom factor 1.0 is the ultra wide; the multiplier maps it to "0.5x".
        let multiplier = device.displayVideoZoomFactorMultiplier
        let minDisplay = device.minAvailableVideoZoomFactor * multiplier
        let maxDisplay = min(device.maxAvailableVideoZoomFactor * multiplier, 25)

        var presets: [CGFloat] = []
        if minDisplay < 0.99 { presets.append(minDisplay) }
        presets.append(1)
        for factor in device.virtualDeviceSwitchOverVideoZoomFactors {
            let display = CGFloat(truncating: factor) * multiplier
            if display > 1.01 { presets.append(display) }
        }
        // 48MP sensors give an optical-quality 2x crop.
        if device.position == .back, maxDisplay >= 2, !presets.contains(where: { abs($0 - 2) < 0.3 }) {
            presets.append(2)
        }
        presets.sort()

        // Start at the main "1x" lens.
        let start = min(max(1 / multiplier, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = start
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }

        let flash = device.isFlashAvailable
        DispatchQueue.main.async {
            self.zoomPresets = presets
            self.minDisplayZoom = minDisplay
            self.maxDisplayZoom = maxDisplay
            self.zoomFactor = start * multiplier
            self.flashAvailable = flash
        }
        setupCameraControl(for: device)
    }

    // MARK: Camera Control button (iPhone 16 and later)

    private func setupCameraControl(for device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }

        let zoom = AVCaptureSystemZoomSlider(device: device) { [weak self, weak device] _ in
            guard let self, let device else { return }
            let display = device.videoZoomFactor * device.displayVideoZoomFactorMultiplier
            DispatchQueue.main.async { self.zoomFactor = display }
        }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device)
        for control in [zoom, exposure] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
        session.setControlsDelegate(self, queue: sessionQueue)
        session.commitConfiguration()
    }

    // MARK: User actions

    func shutterPressed() {
        switch mode {
        case .photo:
            if countdown != nil { cancelCountdown(); return }
            if timerSeconds > 0 { runCountdown { self.takePhoto() } } else { takePhoto() }
        case .video:
            if !isRecording, timerSeconds > 0, countdown == nil { runCountdown { self.toggleRecording() } }
            else if countdown != nil { cancelCountdown() }
            else { toggleRecording() }
        }
    }

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording else { return }
        mode = newMode
        sessionQueue.async {
            self.session.beginConfiguration()
            if newMode == .video {
                self.session.sessionPreset = .high
                if self.audioInput == nil,
                   let mic = AVCaptureDevice.default(for: .audio),
                   let input = try? AVCaptureDeviceInput(device: mic),
                   self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.audioInput = input
                }
                if self.session.canAddOutput(self.movieOutput) { self.session.addOutput(self.movieOutput) }
                self.applyStabilization()
            } else {
                self.session.removeOutput(self.movieOutput)
                if let audio = self.audioInput { self.session.removeInput(audio); self.audioInput = nil }
                self.session.sessionPreset = .photo
            }
            self.session.commitConfiguration()
            self.configurePhotoOutput()
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        sessionQueue.async {
            guard let current = self.videoInput else { return }
            let position: AVCaptureDevice.Position = current.device.position == .back ? .front : .back
            guard let device = Self.bestDevice(for: position),
                  let input = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            self.session.removeInput(current)
            if self.session.canAddInput(input) {
                self.session.addInput(input)
                self.videoInput = input
            } else {
                self.session.addInput(current)
            }
            if self.mode == .video { self.applyStabilization() }
            self.session.commitConfiguration()
            self.configurePhotoOutput()
            self.deviceDidChange()
        }
    }

    func cycleFlash() {
        switch flashMode {
        case .off: flashMode = .auto
        case .auto: flashMode = .on
        default: flashMode = .off
        }
    }

    func cycleTimer() {
        timerSeconds = timerSeconds == 0 ? 3 : (timerSeconds == 3 ? 10 : 0)
    }

    /// `display` is the user-facing zoom (0.5, 1, 2, 5…).
    func setZoom(_ display: CGFloat, animated: Bool = false) {
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            let multiplier = device.displayVideoZoomFactorMultiplier
            let maxFactor = min(device.maxAvailableVideoZoomFactor, 25 / multiplier)
            let factor = min(max(display / multiplier, device.minAvailableVideoZoomFactor), maxFactor)
            guard (try? device.lockForConfiguration()) != nil else { return }
            if animated { device.ramp(toVideoZoomFactor: factor, withRate: 10) } else { device.videoZoomFactor = factor }
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.zoomFactor = factor * multiplier }
        }
    }

    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }
    }

    /// When the scene changes a lot after a tap-to-focus, go back to continuous auto focus.
    private func resetFocus() {
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let center = CGPoint(x: 0.5, y: 0.5)
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = center
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = center
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        }
    }

    // MARK: Countdown timer

    private func runCountdown(then action: @escaping () -> Void) {
        let seconds = timerSeconds
        countdownTask = Task { @MainActor in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                self.countdown = remaining
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            self.countdown = nil
            action()
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdown = nil
    }

    // MARK: Photo capture

    private func takePhoto() {
        let flash = flashMode
        let wantLive = livePhotoEnabled
        let wantRAW = proRAWEnabled
        blink()

        sessionQueue.async {
            let output = self.photoOutput
            var settings: AVCapturePhotoSettings
            if wantRAW, output.isAppleProRAWEnabled,
               let raw = output.availableRawPhotoPixelFormatTypes.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
                let processed: [String: Any]? = output.availablePhotoCodecTypes.contains(.hevc)
                    ? [AVVideoCodecKey: AVVideoCodecType.hevc] : nil
                settings = AVCapturePhotoSettings(rawPixelFormatType: raw, processedFormat: processed)
            } else if output.availablePhotoCodecTypes.contains(.hevc) {
                settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
            } else {
                settings = AVCapturePhotoSettings()
            }

            settings.maxPhotoDimensions = output.maxPhotoDimensions
            settings.photoQualityPrioritization = .balanced
            if self.videoInput?.device.isFlashAvailable == true, output.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            var liveURL: URL?
            if wantLive, !wantRAW, output.isLivePhotoCaptureEnabled {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
                settings.livePhotoMovieFileURL = url
                liveURL = url
            }
            self.applyCaptureRotation(to: output.connection(with: .video))

            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(livePhotoURL: liveURL) { [weak self] thumbnail in
                guard let self else { return }
                DispatchQueue.main.async { if let thumbnail { self.lastThumbnail = thumbnail } }
                self.sessionQueue.async { self.photoProcessors[id] = nil }
            }
            self.photoProcessors[id] = processor
            output.capturePhoto(with: settings, delegate: processor)
        }
    }

    private func blink() {
        shutterBlink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self.shutterBlink = false }
    }

    // MARK: Video capture

    private func toggleRecording() {
        sessionQueue.async {
            if self.movieOutput.isRecording {
                self.movieOutput.stopRecording()
                return
            }
            guard let connection = self.movieOutput.connection(with: .video) else { return }
            self.applyCaptureRotation(to: connection)
            if self.movieOutput.availableVideoCodecTypes.contains(.hevc) {
                self.movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
            }
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            self.movieOutput.startRecording(to: url, recordingDelegate: self)
        }
    }

    private func applyStabilization() {
        guard let connection = movieOutput.connection(with: .video),
              connection.isVideoStabilizationSupported else { return }
        connection.preferredVideoStabilizationMode = .cinematicExtendedEnhanced
    }

    private func applyCaptureRotation(to connection: AVCaptureConnection?) {
        guard let connection, let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    private func saveVideo(at url: URL) {
        Task {
            if let thumb = await Self.videoThumbnail(url) {
                await MainActor.run { self.lastThumbnail = thumb }
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            if status == .authorized || status == .limited {
                try? await PHPhotoLibrary.shared().performChanges {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: options)
                }
            }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func videoThumbnail(_ url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Recording delegate

extension CameraModel: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStart = Date()
            self.recordingDuration = 0
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.recordingDuration = Date().timeIntervalSince(self.recordingStart)
            }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
        }
        // A recording can report an error and still be usable (e.g. disk nearly full).
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        if finished { saveVideo(at: outputFileURL) } else { try? FileManager.default.removeItem(at: outputFileURL) }
    }
}

// MARK: - Camera Control overlay

extension CameraModel: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.controlsFullscreen = true }
    }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.controlsFullscreen = false }
    }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) {
        DispatchQueue.main.async { self.controlsFullscreen = false }
    }
}
