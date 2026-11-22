import AVFoundation
import CoreImage

/// Writes filtered frames (+ audio) to a .mov with AVAssetWriter.
/// Also handles slow motion (re-timed high-frame-rate capture) and time-lapse (frame sampling).
/// Every method must be called on the same serial queue (the camera's video queue).
final class VideoRecorder {
    enum Timing {
        case realtime
        case slowMotion(factor: Double)          // e.g. 240fps → 30fps = 8×
        case timelapse(interval: Double)          // seconds between kept frames
    }

    let url: URL
    private let timing: Timing
    private let audioSettings: [String: Any]?
    private let transform: CGAffineTransform
    private let frameRate: Int

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var lastKeptTime: CMTime?
    private var frameIndex: Int64 = 0
    private var finishing = false

    init(timing: Timing, audioSettings: [String: Any]?, transform: CGAffineTransform, frameRate: Int) {
        self.url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        self.timing = timing
        self.audioSettings = audioSettings
        self.transform = transform
        self.frameRate = frameRate
    }

    func appendVideo(_ image: CIImage, at time: CMTime) {
        guard !finishing else { return }
        if writer == nil { setUp(size: image.extent.size, firstTime: time) }
        guard let writer, writer.status == .writing, let videoInput, videoInput.isReadyForMoreMediaData,
              let adaptor, let pool = adaptor.pixelBufferPool, let start = startTime else { return }

        let outputTime: CMTime
        switch timing {
        case .realtime:
            outputTime = time
        case .slowMotion(let factor):
            outputTime = CMTimeAdd(start, CMTimeMultiplyByFloat64(CMTimeSubtract(time, start), multiplier: factor))
        case .timelapse(let interval):
            if let last = lastKeptTime, CMTimeSubtract(time, last).seconds < interval { return }
            lastKeptTime = time
            outputTime = CMTime(value: frameIndex, timescale: 30)
            frameIndex += 1
        }

        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { return }
        let origin = image.extent.origin
        RenderContext.ciContext.render(image.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y)),
                                       to: buffer,
                                       bounds: CGRect(origin: .zero, size: image.extent.size),
                                       colorSpace: RenderContext.sRGB)
        adaptor.append(buffer, withPresentationTime: outputTime)
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard !finishing, let writer, writer.status == .writing, let audioInput, audioInput.isReadyForMoreMediaData,
              let start = startTime, CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start else { return }
        audioInput.append(sampleBuffer)
    }

    func finish(completion: @escaping (URL?) -> Void) {
        finishing = true
        guard let writer, writer.status == .writing else {
            completion(nil)
            return
        }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        writer.finishWriting { [url] in
            completion(writer.status == .completed ? url : nil)
        }
    }

    private func setUp(size: CGSize, firstTime: CMTime) {
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }
        let width = Int(size.width), height = Int(size.height)
        let bitRate = width * height * (frameRate > 30 ? 9 : 6)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ],
        ]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        video.expectsMediaDataInRealTime = true
        video.transform = transform
        guard writer.canAdd(video) else { return }
        writer.add(video)

        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])

        if let audioSettings, case .realtime = timing {
            let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            audio.expectsMediaDataInRealTime = true
            if writer.canAdd(audio) {
                writer.add(audio)
                audioInput = audio
            }
        }

        guard writer.startWriting() else { return }
        if case .timelapse = timing {
            writer.startSession(atSourceTime: .zero)
        } else {
            writer.startSession(atSourceTime: firstTime)
        }
        self.writer = writer
        self.videoInput = video
        self.startTime = firstTime
    }
}
