import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit

/// What to do with a photo once it has been captured.
struct PhotoJob {
    var recipe: FilmRecipe
    var intensity: Double
    var aspect: PhotoAspect
    var depth: Bool
    var aperture: Double
    var mirror: Bool

    /// Nothing to bake in: save the camera's original file untouched (best quality, keeps Live Photo).
    var isPassthrough: Bool { recipe.isNeutral && aspect == .threeFour && !depth && !mirror }
}

/// Collects one capture's data, bakes in the look / depth blur / crop, and saves to Photos.
final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let job: PhotoJob
    private let livePhotoURL: URL?
    private let queue: DispatchQueue
    private let completion: (UIImage?) -> Void

    private var photoData: Data?
    private var rawData: Data?
    private var livePhotoMovieURL: URL?

    init(job: PhotoJob, livePhotoURL: URL?, queue: DispatchQueue, completion: @escaping (UIImage?) -> Void) {
        self.job = job
        self.livePhotoURL = livePhotoURL
        self.queue = queue
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { rawData = data } else { photoData = data }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error == nil { livePhotoMovieURL = outputFileURL }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        queue.async { self.process() }
    }

    private func process() {
        guard let photoData else {
            if let rawData { save(main: rawData, raw: nil, thumbnail: nil) } else { finish(nil) }
            return
        }

        if job.isPassthrough {
            let thumb = UIImage(data: photoData)?.preparingThumbnail(of: CGSize(width: 200, height: 200))
            save(main: photoData, raw: rawData, thumbnail: thumb, live: livePhotoMovieURL)
            return
        }

        guard var image = CIImage(data: photoData, options: [.applyOrientationProperty: true]) else {
            save(main: photoData, raw: rawData, thumbnail: nil)
            return
        }
        let originalProperties = image.properties
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))

        if job.mirror {
            image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1).translatedBy(x: -image.extent.width, y: 0))
        }
        if job.depth {
            image = DepthEffect.apply(to: image, subjectMask: DepthEffect.photoMask(for: image), aperture: job.aperture)
        }
        image = Self.crop(image, to: job.aspect)
        image = FilmRenderer.shared.apply(job.recipe, to: image, intensity: job.intensity)

        // Orientation is now baked into the pixels.
        var properties = originalProperties
        properties[kCGImagePropertyOrientation as String] = 1
        if var tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            properties[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        image = image.settingProperties(properties)

        let context = RenderContext.ciContext
        guard let heif = context.heifRepresentation(of: image, format: .RGBA8,
                                                    colorSpace: RenderContext.displayP3, options: [:]) else {
            save(main: photoData, raw: rawData, thumbnail: nil)
            return
        }
        let thumbScale = 300 / max(image.extent.width, image.extent.height)
        let thumbImage = image.transformed(by: CGAffineTransform(scaleX: thumbScale, y: thumbScale))
        let thumb = context.createCGImage(thumbImage, from: thumbImage.extent).map { UIImage(cgImage: $0) }
        save(main: heif, raw: rawData, thumbnail: thumb)
    }

    static func crop(_ image: CIImage, to aspect: PhotoAspect) -> CIImage {
        let e = image.extent
        // Ratio is defined for portrait; flip it for landscape shots.
        let ratio = e.width <= e.height ? aspect.ratio : 1 / aspect.ratio
        var target = e
        if e.width / e.height > ratio {
            target.size.width = e.height * ratio
            target.origin.x = e.minX + (e.width - target.width) / 2
        } else {
            target.size.height = e.width / ratio
            target.origin.y = e.minY + (e.height - target.height) / 2
        }
        let cropped = image.cropped(to: target.integral)
        return cropped.transformed(by: CGAffineTransform(translationX: -cropped.extent.minX, y: -cropped.extent.minY))
    }

    private func save(main: Data, raw: Data?, thumbnail: UIImage?, live: URL? = nil) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.finish(thumbnail)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: main, options: nil)
                if let raw { request.addResource(with: .alternatePhoto, data: raw, options: nil) }
                if let live {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: live, options: options)
                }
            }) { _, _ in self.finish(thumbnail) }
        }
    }

    private func finish(_ thumbnail: UIImage?) {
        if let url = livePhotoURL { try? FileManager.default.removeItem(at: url) }
        if let url = livePhotoMovieURL { try? FileManager.default.removeItem(at: url) }
        completion(thumbnail)
    }
}
