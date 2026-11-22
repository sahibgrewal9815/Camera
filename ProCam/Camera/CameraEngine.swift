import AVFoundation
import CoreImage.CIFilterBuiltins
import CoreMotion
import Photos
import SwiftUI
import Vision

/// Fast-changing values live in their own object so they don't redraw the whole camera screen.
final class LiveData: ObservableObject {
    @Published var histogram: [Float] = []
    @Published var trackedRect: CGRect?
    @Published var lookThumbnails: [UUID: UIImage] = [:]
    @Published var recordingDuration: TimeInterval = 0
    @Published var roll: Double = 0          // device tilt for the level, radians
}

/// Snapshot of everything the frame pipeline needs, read on the video queue.
struct RenderState {
    var recipe: FilmRecipe = .natural
    var intensity = 1.0
    var depth = false
    var aperture = 2.8
    var wantsHistogram = false
    var wantsThumbnails = false
    var recipes: [FilmRecipe] = []
}

final class CameraEngine: NSObject, ObservableObject {

    // MARK: Published UI state
    @Published var isAuthorized: Bool?
    @Published private(set) var mode: CaptureMode = .photo
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published var flashAvailable = false
    @Published var livePhotoSupported = false
    @Published var livePhotoEnabled = true
    @Published var proRAWSupported = false
    @Published var proRAWEnabled = false
    @Published var timerSeconds = 0
    @Published var countdown: Int?
    @Published var zoomFactor: CGFloat = 1
    @Published var zoomPresets: [CGFloat] = [1]
    @Published var isRecording = false
    @Published var lastThumbnail: UIImage?
    @Published var shutterBlink = false
    @Published var controlsFullscreen = false
    @Published var isFrontCamera = false
    @Published var processingCount = 0
    @Published var imageSize = CGSize(width: 1080, height: 1440)
    @Published var activeStabilization: AVCaptureVideoStabilizationMode = .off
    @Published var activeFrameRate = 30

    // Looks
    @Published private(set) var recipes: [FilmRecipe]
    @Published var selectedRecipe: FilmRecipe = .natural {
        didSet { pushRenderState(); if settings.selectedRecipeName != selectedRecipe.name { settings.selectedRecipeName = selectedRecipe.name } }
    }
    @Published var lookIntensity = 1.0 {
        didSet { pushRenderState(); settings.lookIntensity = lookIntensity }
    }
    @Published var showLooks = false { didSet { pushRenderState() } }

    // Depth / cinematic
    @Published var aperture: Double = 2.8 { didSet { pushRenderState() } }

    // Pro controls
    @Published var showPro = false { didSet { pushRenderState(); proPanelChanged() } }
    @Published var pro = ProState()

    @Published var settings: CameraSettings {
        didSet { settings.save(); settingsChanged(from: oldValue) }
    }

    let live = LiveData()
    let frameStore = FrameStore()          // styled viewfinder frames
    private let unstyledStore = FrameStore()   // same frames before the look, for recipe previews

    // MARK: Capture plumbing
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "procam.session")
    private let videoQueue = DispatchQueue(label: "procam.video", qos: .userInteractive)
    private let processingQueue = DispatchQueue(label: "procam.photo", qos: .userInitiated)
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var photoProcessors: [Int64: PhotoProcessor] = [:]
    private var isConfigured = false
    private var countdownTask: Task<Void, Never>?
    private var recordingTimer: Timer?
    private var proTimer: Timer?
    private let motion = CMMotionManager()

    // Video queue state
    private let stateLock = NSLock()
    private var renderState = RenderState()
    private var recorder: VideoRecorder?
    private var frameCounter = 0
    private var lastImageSize = CGSize.zero
    private var subjectMask: CIImage?
    private var trackingRequest: VNTrackObjectRequest?
    private var sequenceHandler = VNSequenceRequestHandler()
    private var trackingLostFrames = 0
    private var captureFrameRate = 30
    private lazy var segmentationRequest: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()

    override init() {
        let saved = CameraSettings.load()
        settings = saved
        recipes = FilmRecipe.presets + CustomRecipes.load()
        super.init()
        selectedRecipe = recipes.first { $0.name == saved.selectedRecipeName } ?? .natural
        lookIntensity = saved.lookIntensity
        pushRenderState()
        NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.resetFocusIfNotTracking() }
    }

    // MARK: - Lifecycle

    func start() {
        Task {
            let granted = await Self.requestPermissions()
            await MainActor.run { self.isAuthorized = granted }
            guard granted else { return }
            let mode = await MainActor.run { self.mode }
            let settings = await MainActor.run { self.settings }
            sessionQueue.async {
                if !self.isConfigured { self.configureSession(mode: mode, settings: settings) }
                if !self.session.isRunning { self.session.startRunning() }
            }
            await MainActor.run { self.startLevel() }
        }
    }

    func stop() {
        if isRecording { stopRecording() }
        motion.stopDeviceMotionUpdates()
        sessionQueue.async {
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

    private func startLevel() {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 30
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let self, let g = data?.gravity, self.settings.showLevel else { return }
            self.live.roll = atan2(g.x, -g.y)
        }
    }

    // MARK: - Session setup (sessionQueue)

    private func configureSession(mode: CaptureMode, settings: CameraSettings) {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = Self.bestDevice(for: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            return
        }
        session.addInput(input)
        videoInput = input

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        photoOutput.maxPhotoQualityPrioritization = .quality
        session.commitConfiguration()

        isConfigured = true
        applyMode(mode, settings: settings)
    }

    /// Prefers the multi-lens virtual camera so lenses switch automatically while zooming.
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

    /// Sets formats, frame rate, audio and stabilization for a capture mode.
    private func applyMode(_ mode: CaptureMode, settings: CameraSettings) {
        guard isConfigured, let device = videoInput?.device else { return }

        session.beginConfiguration()
        if mode.recordsAudio {
            if audioInput == nil, let mic = AVCaptureDevice.default(for: .audio),
               let input = try? AVCaptureDeviceInput(device: mic), session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
        } else if let audio = audioInput {
            session.removeInput(audio)
            audioInput = nil
        }

        switch mode {
        case .photo, .depth:
            session.sessionPreset = .photo
        case .sloMo:
            session.sessionPreset = .hd1920x1080
        default:
            let want4K = settings.videoResolution == .uhd4K && mode != .action
            session.sessionPreset = want4K && session.canSetSessionPreset(.hd4K3840x2160) ? .hd4K3840x2160 : .hd1920x1080
        }
        session.commitConfiguration()

        var fps = 30
        switch mode {
        case .photo, .depth: fps = 30
        case .sloMo: fps = configureSloMo(device)
        case .cinematic: fps = setFrameRate(settings.cinematicFrameRate, on: device)
        case .video: fps = setFrameRate(settings.frameRate, on: device)
        case .action, .timelapse: fps = setFrameRate(30, on: device)
        }
        captureFrameRate = fps

        applyVideoConnection(mode: mode, settings: settings)
        configurePhotoOutput(settings: settings)
        deviceDidChange()
        DispatchQueue.main.async { self.activeFrameRate = fps }
    }

    /// Picks the fastest 1080p format (up to 240fps) for slow motion.
    private func configureSloMo(_ device: AVCaptureDevice) -> Int {
        func maxFPS(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        let candidates = device.formats.filter { format in
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return d.width == 1920 && d.height == 1080 && maxFPS(format) >= 120
        }
        guard let best = candidates.max(by: { maxFPS($0) < maxFPS($1) }),
              (try? device.lockForConfiguration()) != nil else { return 30 }
        let fps = Int(min(240, maxFPS(best)))
        device.activeFormat = best
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()
        return fps
    }

    @discardableResult
    private func setFrameRate(_ fps: Int, on device: AVCaptureDevice) -> Int {
        let supported = device.activeFormat.videoSupportedFrameRateRanges.contains {
            $0.minFrameRate <= Double(fps) && Double(fps) <= $0.maxFrameRate
        }
        guard supported, (try? device.lockForConfiguration()) != nil else { return 30 }
        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        device.unlockForConfiguration()
        return fps
    }

    private func applyVideoConnection(mode: CaptureMode, settings: CameraSettings) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }

        var applied: AVCaptureVideoStabilizationMode = .off
        if connection.isVideoStabilizationSupported, let format = videoInput?.device.activeFormat {
            let wanted: AVCaptureVideoStabilizationMode
            switch mode {
            case .photo, .depth: wanted = .off
            case .video: wanted = settings.stabilization.mode
            case .cinematic, .timelapse: wanted = .cinematicExtended
            case .action: wanted = .cinematicExtendedEnhanced
            case .sloMo: wanted = .standard
            }
            if format.isVideoStabilizationModeSupported(wanted) {
                applied = wanted
            } else if wanted != .off, format.isVideoStabilizationModeSupported(.cinematic) {
                applied = .cinematic
            } else if wanted != .off, format.isVideoStabilizationModeSupported(.standard) {
                applied = .standard
            }
            connection.preferredVideoStabilizationMode = applied
        }
        DispatchQueue.main.async { self.activeStabilization = applied }
    }

    /// Newest photo pipeline features the device supports.
    private func configurePhotoOutput(settings: CameraSettings) {
        if let device = videoInput?.device {
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

        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = videoInput?.device.position == .front && settings.mirrorFrontCamera
        }

        let live = photoOutput.isLivePhotoCaptureSupported
        let raw = photoOutput.isAppleProRAWSupported
        DispatchQueue.main.async {
            self.livePhotoSupported = live
            self.proRAWSupported = raw
            if !raw { self.proRAWEnabled = false }
        }
    }

    /// Called whenever the active camera or format changes.
    private func deviceDidChange() {
        guard let device = videoInput?.device else { return }
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

        // On multi-lens cameras raw zoom 1.0 is the ultra wide; the multiplier maps it to "0.5×".
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
        if device.position == .back, maxDisplay >= 2, !presets.contains(where: { abs($0 - 2) < 0.3 }) {
            presets.append(2)
        }
        presets.sort()

        let start = min(max(1 / multiplier, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        if (try? device.lockForConfiguration()) != nil {
            device.videoZoomFactor = start
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }

        let format = device.activeFormat
        var pro = ProState()
        pro.minISO = format.minISO
        pro.maxISO = format.maxISO
        pro.minShutter = format.minExposureDuration.seconds
        pro.maxShutter = min(format.maxExposureDuration.seconds, 1)
        pro.minBias = device.minExposureTargetBias
        pro.maxBias = device.maxExposureTargetBias
        pro.iso = device.iso
        pro.shutter = device.exposureDuration.seconds
        pro.aperture = device.lensAperture
        pro.lensPosition = device.lensPosition

        let flash = device.isFlashAvailable
        let front = device.position == .front
        DispatchQueue.main.async {
            self.zoomPresets = presets
            self.zoomFactor = start * multiplier
            self.flashAvailable = flash
            self.isFrontCamera = front
            self.pro = pro
        }
        setupCameraControl(for: device)
    }

    // MARK: - Camera Control button (iPhone 16 and later)

    private func setupCameraControl(for device: AVCaptureDevice) {
        guard session.supportsControls else { return }
        let (names, selectedIndex, intensity) = DispatchQueue.main.sync {
            (recipes.map(\.name), recipes.firstIndex(of: selectedRecipe) ?? 0, lookIntensity)
        }

        session.beginConfiguration()
        for control in session.controls { session.removeControl(control) }

        let zoom = AVCaptureSystemZoomSlider(device: device) { [weak self, weak device] _ in
            guard let self, let device else { return }
            let display = device.videoZoomFactor * device.displayVideoZoomFactorMultiplier
            DispatchQueue.main.async { self.zoomFactor = display }
        }
        let exposure = AVCaptureSystemExposureBiasSlider(device: device)

        let looks = AVCaptureIndexPicker("Looks", symbolName: "camera.filters", localizedIndexTitles: names)
        looks.selectedIndex = selectedIndex
        looks.setActionQueue(.main) { [weak self] index in
            guard let self, self.recipes.indices.contains(index) else { return }
            self.selectedRecipe = self.recipes[index]
        }

        let strength = AVCaptureSlider("Look Strength", symbolName: "dial.medium", in: 0...1)
        strength.value = Float(intensity)
        strength.setActionQueue(.main) { [weak self] value in self?.lookIntensity = Double(value) }

        for control in [zoom, exposure, looks, strength] as [AVCaptureControl] where session.canAddControl(control) {
            session.addControl(control)
        }
        session.setControlsDelegate(self, queue: .main)
        session.commitConfiguration()
    }

    // MARK: - Modes & settings

    func setMode(_ newMode: CaptureMode) {
        guard newMode != mode, !isRecording else { return }
        cancelCountdown()
        stopTracking()
        mode = newMode
        pushRenderState()
        let settings = settings
        sessionQueue.async { self.applyMode(newMode, settings: settings) }
    }

    private func settingsChanged(from old: CameraSettings) {
        let new = settings
        pushRenderState()
        let videoChanged = old.videoResolution != new.videoResolution || old.frameRate != new.frameRate
            || old.stabilization != new.stabilization || old.cinematicFrameRate != new.cinematicFrameRate
        if (videoChanged && mode.isVideo || old.mirrorFrontCamera != new.mirrorFrontCamera), !isRecording {
            let mode = mode
            sessionQueue.async { self.applyMode(mode, settings: new) }
        }
    }

    private func pushRenderState() {
        let state = RenderState(recipe: selectedRecipe, intensity: lookIntensity, depth: mode.usesDepthEffect,
                                aperture: aperture, wantsHistogram: showPro && settings.showHistogram,
                                wantsThumbnails: showLooks, recipes: recipes)
        stateLock.lock()
        renderState = state
        stateLock.unlock()
    }

    private func currentRenderState() -> RenderState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return renderState
    }

    // MARK: - Looks

    func saveRecipe(_ recipe: FilmRecipe, asNew: Bool) {
        var recipe = recipe
        recipe.isCustom = true
        var customs = recipes.filter(\.isCustom)
        if !asNew, let index = customs.firstIndex(where: { $0.id == recipe.id }) {
            customs[index] = recipe
        } else {
            recipe.id = UUID()
            customs.append(recipe)
        }
        CustomRecipes.save(customs)
        recipes = FilmRecipe.presets + customs
        selectedRecipe = recipe
    }

    /// Renders the current viewfinder frame with any recipe (for the recipe card). Safe off the main thread.
    func renderPreview(of recipe: FilmRecipe, maxSide: CGFloat = 900) -> UIImage? {
        guard let source = unstyledStore.latest().0 else { return nil }
        let s = min(1, maxSide / max(source.extent.width, source.extent.height))
        var image = source.transformed(by: CGAffineTransform(scaleX: s, y: s))
        image = FilmRenderer.shared.apply(recipe, to: image)
        guard let cg = RenderContext.ciContext.createCGImage(image, from: image.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    func deleteRecipe(_ recipe: FilmRecipe) {
        guard recipe.isCustom else { return }
        let customs = recipes.filter { $0.isCustom && $0.id != recipe.id }
        CustomRecipes.save(customs)
        recipes = FilmRecipe.presets + customs
        if selectedRecipe.id == recipe.id { selectedRecipe = .natural }
    }

    // MARK: - User actions

    func shutterPressed() {
        if countdown != nil { cancelCountdown(); return }
        if mode.isVideo {
            if isRecording { stopRecording() }
            else if timerSeconds > 0 { runCountdown { self.startRecording() } }
            else { startRecording() }
        } else {
            if timerSeconds > 0 { runCountdown { self.takePhoto() } } else { takePhoto() }
        }
    }

    func switchCamera() {
        guard !isRecording else { return }
        stopTracking()
        let mode = mode, settings = settings
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
            self.session.commitConfiguration()
            self.applyMode(mode, settings: settings)
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

    /// `display` is the user-facing zoom (0.5, 1, 2, 4…).
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

    /// Focus + expose at a point. `imagePoint` is normalized (0...1, top-left) in the upright frame.
    func focus(atImagePoint imagePoint: CGPoint, continuous: Bool = false) {
        // Portrait frame → landscape sensor coordinates.
        let devicePoint = CGPoint(x: imagePoint.y, y: 1 - imagePoint.x)
        let pro = pro
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let focusMode: AVCaptureDevice.FocusMode = continuous ? .continuousAutoFocus : .autoFocus
            if pro.focusAuto, device.isFocusPointOfInterestSupported, device.isFocusModeSupported(focusMode) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = focusMode
            }
            let exposureMode: AVCaptureDevice.ExposureMode = continuous ? .continuousAutoExposure : .autoExpose
            if pro.isoAuto, pro.shutterAuto, device.isExposurePointOfInterestSupported,
               device.isExposureModeSupported(exposureMode) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = exposureMode
            }
            device.isSubjectAreaChangeMonitoringEnabled = !continuous
            device.unlockForConfiguration()
        }
    }

    private func resetFocusIfNotTracking() {
        DispatchQueue.main.async {
            guard self.live.trackedRect == nil else { return }
            self.focus(atImagePoint: CGPoint(x: 0.5, y: 0.5), continuous: true)
        }
    }

    // MARK: - Smart focus tracking (double-tap a subject)

    func startTracking(atImagePoint p: CGPoint) {
        let w: CGFloat = 0.22, h: CGFloat = 0.16
        var box = CGRect(x: p.x - w / 2, y: (1 - p.y) - h / 2, width: w, height: h)   // Vision: bottom-left origin
        box = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !box.isNull, box.width > 0.01, box.height > 0.01 else { return }
        videoQueue.async {
            let request = VNTrackObjectRequest(detectedObjectObservation: VNDetectedObjectObservation(boundingBox: box))
            request.trackingLevel = .accurate
            self.sequenceHandler = VNSequenceRequestHandler()
            self.trackingRequest = request
            self.trackingLostFrames = 0
        }
        live.trackedRect = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        focus(atImagePoint: p, continuous: true)
    }

    func stopTracking() {
        videoQueue.async { self.trackingRequest = nil }
        live.trackedRect = nil
    }

    // MARK: - Pro controls

    func setISO(_ iso: Float?) {
        if let iso { pro.iso = iso; pro.isoAuto = false } else { pro.isoAuto = true }
        applyExposure()
    }

    func setShutter(_ seconds: Double?) {
        if let seconds { pro.shutter = seconds; pro.shutterAuto = false } else { pro.shutterAuto = true }
        applyExposure()
    }

    func setExposureBias(_ bias: Float) {
        pro.exposureBias = bias
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            device.setExposureTargetBias(min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias))
            device.unlockForConfiguration()
        }
    }

    func setWhiteBalance(_ kelvin: Float?) {
        if let kelvin { pro.kelvin = kelvin; pro.wbAuto = false } else { pro.wbAuto = true }
        let p = pro
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if p.wbAuto {
                if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
            } else if device.isLockingWhiteBalanceWithCustomDeviceGainsSupported {
                var gains = device.deviceWhiteBalanceGains(
                    for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: p.kelvin, tint: 0))
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(gains.redGain, 1), maxGain)
                gains.greenGain = min(max(gains.greenGain, 1), maxGain)
                gains.blueGain = min(max(gains.blueGain, 1), maxGain)
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    func setFocus(_ lensPosition: Float?) {
        if let lensPosition { pro.lensPosition = lensPosition; pro.focusAuto = false } else { pro.focusAuto = true }
        let p = pro
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if p.focusAuto {
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            } else if device.isLockingFocusWithCustomLensPositionSupported {
                device.setFocusModeLocked(lensPosition: p.lensPosition, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    func resetPro() {
        pro.isoAuto = true
        pro.shutterAuto = true
        applyExposure()
        setWhiteBalance(nil)
        setFocus(nil)
        setExposureBias(0)
    }

    private func applyExposure() {
        let p = pro
        sessionQueue.async {
            guard let device = self.videoInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if p.isoAuto && p.shutterAuto {
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            } else if device.isExposureModeSupported(.custom) {
                let format = device.activeFormat
                let duration: CMTime
                if p.shutterAuto {
                    duration = device.exposureDuration
                } else {
                    let s = min(max(p.shutter, format.minExposureDuration.seconds), format.maxExposureDuration.seconds)
                    duration = CMTime(seconds: s, preferredTimescale: 1_000_000)
                }
                let iso = p.isoAuto ? device.iso : min(max(p.iso, format.minISO), format.maxISO)
                device.setExposureModeCustom(duration: duration, iso: iso, completionHandler: nil)
            }
            device.unlockForConfiguration()
        }
    }

    /// While the Pro panel is open, keep the "auto" readouts live.
    private func proPanelChanged() {
        proTimer?.invalidate()
        proTimer = nil
        guard showPro else { return }
        proTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                guard let device = self.videoInput?.device else { return }
                let iso = device.iso
                let shutter = device.exposureDuration.seconds
                let lens = device.lensPosition
                let aperture = device.lensAperture
                let kelvin = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains).temperature
                DispatchQueue.main.async {
                    var p = self.pro
                    if p.isoAuto { p.iso = iso }
                    if p.shutterAuto { p.shutter = shutter }
                    if p.focusAuto { p.lensPosition = lens }
                    if p.wbAuto { p.kelvin = kelvin }
                    p.aperture = aperture
                    if p != self.pro { self.pro = p }
                }
            }
        }
    }

    // MARK: - Countdown

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

    // MARK: - Photo

    private func takePhoto() {
        let job = PhotoJob(recipe: selectedRecipe, intensity: lookIntensity, aspect: settings.photoAspect,
                           depth: mode == .depth, aperture: aperture, mirror: false)
        let flash = flashMode
        let wantLive = livePhotoEnabled && job.isPassthrough
        let wantRAW = proRAWEnabled && mode == .photo
        blink()
        processingCount += 1

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
            settings.photoQualityPrioritization = job.depth ? .quality : .balanced
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
            if let connection = output.connection(with: .video),
               let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }

            let id = settings.uniqueID
            let processor = PhotoProcessor(job: job, livePhotoURL: liveURL, queue: self.processingQueue) { [weak self] thumbnail in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.processingCount = max(0, self.processingCount - 1)
                    if let thumbnail { self.lastThumbnail = thumbnail }
                }
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

    // MARK: - Video

    private func startRecording() {
        let mode = mode
        let interval = settings.timelapseInterval
        let fps = captureFrameRate
        let timing: VideoRecorder.Timing
        switch mode {
        case .sloMo: timing = .slowMotion(factor: Double(fps) / 30)
        case .timelapse: timing = .timelapse(interval: interval)
        default: timing = .realtime
        }
        isRecording = true
        live.recordingDuration = 0
        let start = Date()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.live.recordingDuration = Date().timeIntervalSince(start)
        }

        videoQueue.async {
            let angle = self.rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
            let transform = CGAffineTransform(rotationAngle: (angle - 90) * .pi / 180)
            let audio = mode.recordsAudio
                ? self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any]
                : nil
            self.recorder = VideoRecorder(timing: timing, audioSettings: audio, transform: transform,
                                          frameRate: mode == .sloMo || mode == .timelapse ? 30 : fps)
        }
    }

    private func stopRecording() {
        recordingTimer?.invalidate()
        recordingTimer = nil
        isRecording = false
        processingCount += 1
        videoQueue.async {
            guard let recorder = self.recorder else {
                DispatchQueue.main.async { self.processingCount = max(0, self.processingCount - 1) }
                return
            }
            self.recorder = nil
            recorder.finish { url in
                if let url { self.saveVideo(at: url) }
                DispatchQueue.main.async { self.processingCount = max(0, self.processingCount - 1) }
            }
        }
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
        generator.maximumSize = CGSize(width: 300, height: 300)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Frame pipeline (video queue)

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            recorder?.appendAudio(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let state = currentRenderState()
        frameCounter &+= 1

        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let size = source.extent.size
        if size != lastImageSize {
            lastImageSize = size
            DispatchQueue.main.async { self.imageSize = size }
        }

        // High frame rates: only process every Nth frame for preview/analysis.
        let stride = max(1, captureFrameRate / 60)
        let isPreviewFrame = frameCounter % stride == 0

        if state.depth {
            if subjectMask == nil || frameCounter % (2 * stride) == 0 {
                subjectMask = DepthEffect.liveMask(for: pixelBuffer, request: segmentationRequest)
            }
        } else {
            subjectMask = nil
        }

        if trackingRequest != nil, isPreviewFrame { updateTracking(pixelBuffer) }

        // Full-resolution frame for the recording.
        if let recorder {
            var frame = source
            if state.depth { frame = DepthEffect.apply(to: frame, subjectMask: subjectMask, aperture: state.aperture) }
            frame = FilmRenderer.shared.apply(state.recipe, to: frame, intensity: state.intensity, animateGrain: true)
            recorder.appendVideo(frame, at: time)
        }

        guard isPreviewFrame else { return }

        // Smaller copy for the viewfinder.
        let previewScale = min(1, 1440 / max(size.width, size.height))
        var preview = source.transformed(by: CGAffineTransform(scaleX: previewScale, y: previewScale))
        if state.depth { preview = DepthEffect.apply(to: preview, subjectMask: subjectMask, aperture: state.aperture) }
        let unstyled = preview
        unstyledStore.update(unstyled)
        preview = FilmRenderer.shared.apply(state.recipe, to: preview, intensity: state.intensity, animateGrain: true)
        frameStore.update(preview)

        if state.wantsHistogram, frameCounter % (6 * stride) == 0 { updateHistogram(preview) }
        if state.wantsThumbnails, frameCounter % (20 * stride) == 0 { updateLookThumbnails(unstyled, recipes: state.recipes) }
    }

    private func updateTracking(_ pixelBuffer: CVPixelBuffer) {
        guard let request = trackingRequest else { return }
        try? sequenceHandler.perform([request], on: pixelBuffer, orientation: .up)
        guard let observation = request.results?.first as? VNDetectedObjectObservation,
              observation.confidence > 0.3 else {
            // Keep the box for ~1.5s in case the subject briefly leaves the frame.
            trackingLostFrames += 1
            if trackingLostFrames > 45 {
                trackingRequest = nil
                DispatchQueue.main.async { self.live.trackedRect = nil }
            }
            return
        }
        trackingLostFrames = 0
        request.inputObservation = observation
        let bb = observation.boundingBox
        let rect = CGRect(x: bb.minX, y: 1 - bb.maxY, width: bb.width, height: bb.height)
        let refocus = frameCounter % 8 == 0
        DispatchQueue.main.async {
            guard self.live.trackedRect != nil else { return }
            self.live.trackedRect = rect
            if refocus { self.focus(atImagePoint: CGPoint(x: rect.midX, y: rect.midY), continuous: true) }
        }
    }

    private func updateHistogram(_ image: CIImage) {
        let s = 160 / max(image.extent.width, 1)
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let gray = small.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let histogram = CIFilter.areaHistogram()
        histogram.inputImage = gray
        histogram.extent = small.extent
        histogram.count = 64
        histogram.scale = 1
        guard let output = histogram.outputImage else { return }
        var bins = [Float](repeating: 0, count: 64 * 4)
        bins.withUnsafeMutableBytes { raw in
            RenderContext.ciContext.render(output, toBitmap: raw.baseAddress!, rowBytes: 64 * 16,
                                           bounds: CGRect(x: 0, y: 0, width: 64, height: 1),
                                           format: .RGBAf, colorSpace: nil)
        }
        var values = Swift.stride(from: 0, to: bins.count, by: 4).map { bins[$0] }
        let peak = values.max() ?? 0
        if peak > 0 { values = values.map { $0 / peak } }
        DispatchQueue.main.async { self.live.histogram = values }
    }

    private func updateLookThumbnails(_ image: CIImage, recipes: [FilmRecipe]) {
        let e = image.extent
        let side = min(e.width, e.height)
        let square = image.cropped(to: CGRect(x: e.midX - side / 2, y: e.midY - side / 2, width: side, height: side))
        let s = 132 / side
        let small = square
            .transformed(by: CGAffineTransform(translationX: -square.extent.minX, y: -square.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: s, y: s))
        var thumbnails: [UUID: UIImage] = [:]
        for recipe in recipes {
            let styled = FilmRenderer.shared.apply(recipe, to: small)
            if let cg = RenderContext.ciContext.createCGImage(styled, from: styled.extent) {
                thumbnails[recipe.id] = UIImage(cgImage: cg)
            }
        }
        DispatchQueue.main.async { self.live.lookThumbnails = thumbnails }
    }
}

// MARK: - Camera Control overlay

extension CameraEngine: AVCaptureSessionControlsDelegate {
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { controlsFullscreen = true }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { controlsFullscreen = false }
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { controlsFullscreen = false }
}

// MARK: - Saved custom recipes

enum CustomRecipes {
    static func load() -> [FilmRecipe] {
        guard let data = UserDefaults.standard.data(forKey: "customRecipes"),
              let recipes = try? JSONDecoder().decode([FilmRecipe].self, from: data) else { return [] }
        return recipes
    }

    static func save(_ recipes: [FilmRecipe]) {
        if let data = try? JSONEncoder().encode(recipes) { UserDefaults.standard.set(data, forKey: "customRecipes") }
    }
}
