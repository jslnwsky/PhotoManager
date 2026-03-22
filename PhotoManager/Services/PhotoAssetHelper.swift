import Foundation
import Photos
import UIKit

enum PhotoAssetHelper {
    static let pathPrefix = "photos://asset/"

    static func isPhotosLibraryPhoto(_ photo: Photo) -> Bool {
        photo.filePath.hasPrefix(pathPrefix)
    }

    static func assetIdentifier(from photo: Photo) -> String? {
        guard isPhotosLibraryPhoto(photo) else { return nil }
        return String(photo.filePath.dropFirst(pathPrefix.count))
    }

    static func fetchAsset(for photo: Photo) -> PHAsset? {
        guard let identifier = assetIdentifier(from: photo) else { return nil }
        return PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    @discardableResult
    static func requestThumbnail(
        for photo: Photo,
        size: CGSize = CGSize(width: 300, height: 300),
        deliveryMode: PHImageRequestOptionsDeliveryMode = .opportunistic,
        networkAccess: Bool = true,
        completion: @escaping (UIImage?) -> Void
    ) -> PHImageRequestID? {
        guard let asset = fetchAsset(for: photo) else {
            completion(nil)
            return nil
        }
        let options = PHImageRequestOptions()
        options.deliveryMode = deliveryMode
        options.isNetworkAccessAllowed = networkAccess
        options.resizeMode = .exact
        return PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: options,
            resultHandler: { image, _ in completion(image) }
        )
    }

    static func requestFullImage(for photo: Photo) async -> UIImage? {
        guard let asset = fetchAsset(for: photo) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        return await withCheckedContinuation { continuation in
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: PHImageManagerMaximumSize,
                contentMode: .aspectFit,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    static func cancelRequest(_ requestID: PHImageRequestID?) {
        guard let id = requestID else { return }
        PHImageManager.default().cancelImageRequest(id)
    }
}
