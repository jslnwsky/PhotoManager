import Foundation
import SwiftData
import Photos
import UIKit

@MainActor
class ThumbnailExtractionService: ObservableObject {
    static let shared = ThumbnailExtractionService()
    
    @Published var isExtracting = false
    @Published var progress: Double = 0.0
    @Published var photosProcessed: Int = 0
    @Published var totalPhotos: Int = 0
    
    private var extractionTask: Task<Void, Never>?
    private let maxConcurrentRequests = 3
    
    private init() {}
    
    func startExtraction(modelContext: ModelContext) {
        guard !isExtracting else { return }
        
        extractionTask?.cancel()
        extractionTask = Task {
            await extractMissingThumbnails(modelContext: modelContext)
        }
    }
    
    func cancelExtraction() {
        extractionTask?.cancel()
        extractionTask = nil
        isExtracting = false
    }
    
    private func extractMissingThumbnails(modelContext: ModelContext) async {
        isExtracting = true
        photosProcessed = 0
        progress = 0.0
        
        print("🖼️ Starting background thumbnail extraction...")
        
        // Get all Photos Library photo file paths
        var photoDesc = FetchDescriptor<Photo>()
        photoDesc.propertiesToFetch = [\.filePath]
        guard let allPhotos = try? modelContext.fetch(photoDesc) else {
            print("❌ Failed to fetch photos for thumbnail extraction")
            isExtracting = false
            return
        }
        let photosLibraryPhotos = allPhotos.filter { $0.filePath.hasPrefix("photos://") }
        
        // Get file paths that already have thumbnails
        let thumbDesc = FetchDescriptor<PhotoThumbnail>()
        let existingThumbs = (try? modelContext.fetch(thumbDesc)) ?? []
        let existingPaths = Set(existingThumbs.map { $0.photoFilePath })
        
        // Find photos missing thumbnails
        let photosToProcess = photosLibraryPhotos.filter { !existingPaths.contains($0.filePath) }
        
        totalPhotos = photosToProcess.count
        print("🖼️ Found \(totalPhotos) photos without thumbnails")
        
        guard totalPhotos > 0 else {
            isExtracting = false
            return
        }
        
        // Process in batches with throttling
        let batchSize = maxConcurrentRequests
        var currentIndex = 0
        
        while currentIndex < photosToProcess.count && !Task.isCancelled {
            let endIndex = min(currentIndex + batchSize, photosToProcess.count)
            let batch = Array(photosToProcess[currentIndex..<endIndex])
            
            await withTaskGroup(of: (String, Data?)?.self) { group in
                for photo in batch {
                    let filePath = photo.filePath
                    group.addTask {
                        guard let asset = PhotoAssetHelper.fetchAsset(for: photo) else {
                            return nil
                        }
                        let data = await self.extractThumbnail(from: asset)
                        return (filePath, data)
                    }
                }
                
                for await result in group {
                    guard let (filePath, thumbnailData) = result, let data = thumbnailData else { continue }
                    
                    let thumb = PhotoThumbnail(photoFilePath: filePath, imageData: data)
                    modelContext.insert(thumb)
                    photosProcessed += 1
                    progress = Double(photosProcessed) / Double(totalPhotos)
                    
                    if photosProcessed % 10 == 0 {
                        try? modelContext.save()
                    }
                }
            }
            
            currentIndex = endIndex
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }
        
        try? modelContext.save()
        
        print("🖼️ Thumbnail extraction complete: \(photosProcessed)/\(totalPhotos) thumbnails extracted")
        isExtracting = false
    }
    
    private func extractThumbnail(from asset: PHAsset) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat  // Single callback only
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true  // Allow iCloud download in background
            options.resizeMode = .fast
            
            var hasResumed = false
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard !hasResumed else { return }
                hasResumed = true
                if let image = image,
                   let data = image.jpegData(compressionQuality: 0.8) {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }
}
