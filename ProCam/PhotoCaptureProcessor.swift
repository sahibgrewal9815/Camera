import AVFoundation
import Photos
import UIKit

/// Handles one photo capture from start to finish and saves the result to Photos.
/// Supports HEIF, Apple ProRAW (+ processed companion), Live Photos and deferred photo processing.
final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    private let livePhotoURL: URL?
    private let completion: (UIImage?) -> Void

    private var photoData: Data?
    private var rawData: Data?
    private var proxyData: Data?
    private var livePhotoMovieURL: URL?

    init(livePhotoURL: URL?, completion: @escaping (UIImage?) -> Void) {
        self.livePhotoURL = livePhotoURL
        self.completion = completion
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto { rawData = data } else { photoData = data }
    }

    /// iOS 17+: a quick proxy image is delivered now; Photos finishes the full processing later.
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCapturingDeferredPhotoProxy deferredPhotoProxy: AVCaptureDeferredPhotoProxy?,
                     error: Error?) {
        guard error == nil else { return }
        proxyData = deferredPhotoProxy?.fileDataRepresentation()
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL,
                     duration: CMTime, photoDisplayTime: CMTime,
                     resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if error == nil { livePhotoMovieURL = outputFileURL }
    }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        let previewData = proxyData ?? photoData
        let thumbnail = previewData.flatMap { UIImage(data: $0)?.preparingThumbnail(of: CGSize(width: 200, height: 200)) }

        guard error == nil, proxyData != nil || photoData != nil || rawData != nil else {
            finish(thumbnail: nil)
            return
        }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                self.finish(thumbnail: thumbnail)
                return
            }
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                if let proxy = self.proxyData {
                    request.addResource(with: .photoProxy, data: proxy, options: nil)
                } else if let photo = self.photoData {
                    request.addResource(with: .photo, data: photo, options: nil)
                    if let raw = self.rawData { request.addResource(with: .alternatePhoto, data: raw, options: nil) }
                } else if let raw = self.rawData {
                    request.addResource(with: .photo, data: raw, options: nil)
                }
                if let movie = self.livePhotoMovieURL {
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    request.addResource(with: .pairedVideo, fileURL: movie, options: options)
                }
            }) { _, _ in
                self.finish(thumbnail: thumbnail)
            }
        }
    }

    private func finish(thumbnail: UIImage?) {
        if let url = livePhotoURL { try? FileManager.default.removeItem(at: url) }
        if let url = livePhotoMovieURL { try? FileManager.default.removeItem(at: url) }
        completion(thumbnail)
    }
}
