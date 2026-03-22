import Foundation
import Photos
import SwiftData
import UIKit

@ModelActor
actor PhotoLibraryService {
    func scanPhotosLibrary() async throws -> (photoCount: Int, albumCount: Int) {
        print("📸 Starting Photos Library scan...")
        
        // Request permission
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            print("❌ Photo library permission denied")
            throw PhotoLibraryError.permissionDenied
        }
        
        print("✅ Photo library permission granted")
        
        var photoCount = 0
        var albumCount = 0
        
        // Create root folder for Photos Library
        let rootFolder = Folder(
            name: "Photos Library",
            path: "photos://library",
            sourceType: .localPhotos
        )
        modelContext.insert(rootFolder)
        print("📁 Created root folder: Photos Library")
        
        // Fetch all albums (user albums + smart albums)
        let albumFetchOptions = PHFetchOptions()
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumFetchOptions)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: albumFetchOptions)
        
        // Process user albums
        print("📚 Processing \(userAlbums.count) user albums...")
        let (userAlbumCount, userPhotoCount) = await processAlbums(userAlbums, rootFolder: rootFolder)
        albumCount += userAlbumCount
        photoCount += userPhotoCount
        print("✅ User albums complete: \(userAlbumCount) albums, \(userPhotoCount) photos")
        
        // Process smart albums (skip Recents - we'll use All Photos instead)
        print("📚 Processing \(smartAlbums.count) smart albums (skipping duplicates)...")
        let (smartAlbumCount, smartPhotoCount) = await processAlbums(smartAlbums, rootFolder: rootFolder, skipRecents: true)
        albumCount += smartAlbumCount
        photoCount += smartPhotoCount
        print("✅ Smart albums complete: \(smartAlbumCount) albums, \(smartPhotoCount) photos")
        
        // Add "All Photos" album (replaces Recents)
        print("📚 Creating 'All Photos' album...")
        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allAssets = PHAsset.fetchAssets(with: .image, options: allPhotosOptions)
        print("📊 Found \(allAssets.count) total photos")
        
        if allAssets.count > 0 {
            let allPhotosFolder = Folder(
                name: "All Photos",
                path: "photos://all",
                sourceType: .localPhotos,
                parentFolder: rootFolder
            )
            modelContext.insert(allPhotosFolder)
            albumCount += 1
            
            print("🔄 Processing all photos...")
            let allPhotosCount = await processAssets(allAssets, folder: allPhotosFolder)
            photoCount += allPhotosCount
            print("✅ All Photos complete: \(allPhotosCount) photos indexed")
            
            // Save after All Photos
            try modelContext.save()
            print("💾 Saved All Photos to database")
        }
        
        print("🎉 Photos Library scan complete: \(photoCount) photos in \(albumCount) albums")
        
        return (photoCount, albumCount)
    }
    
    private func processAlbums(_ albums: PHFetchResult<PHAssetCollection>, rootFolder: Folder, skipRecents: Bool = false) async -> (albumCount: Int, photoCount: Int) {
        var albumCount = 0
        var photoCount = 0
        
        for i in 0..<albums.count {
            let collection = albums.object(at: i)
            let albumName = collection.localizedTitle ?? "Untitled Album"
            
            // Skip Recents if requested (we'll use All Photos instead)
            if skipRecents && albumName == "Recents" {
                print("  ⏭️  Skipping \(albumName) (using All Photos instead)")
                continue
            }
            
            // Fetch assets in this album
            let assetFetchOptions = PHFetchOptions()
            assetFetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(in: collection, options: assetFetchOptions)
            
            if assets.count > 0 {
                print("  📁 [\(i+1)/\(albums.count)] \(albumName): \(assets.count) photos")
                
                let albumFolder = Folder(
                    name: albumName,
                    path: "photos://album/\(collection.localIdentifier)",
                    sourceType: .localPhotos,
                    parentFolder: rootFolder
                )
                modelContext.insert(albumFolder)
                albumCount += 1
                
                let processedCount = await processAssets(assets, folder: albumFolder)
                photoCount += processedCount
                print("  ✅ \(albumName): indexed \(processedCount) photos")
                
                // Save after each album for incremental UI updates
                do {
                    try modelContext.save()
                    print("  💾 Saved \(albumName) to database")
                } catch {
                    print("  ⚠️  Failed to save \(albumName): \(error.localizedDescription)")
                }
            }
        }
        
        return (albumCount, photoCount)
    }
    
    private func processAssets(_ assets: PHFetchResult<PHAsset>, folder: Folder) async -> Int {
        var count = 0
        let totalAssets = assets.count
        
        assets.enumerateObjects { asset, index, _ in
            if index % 100 == 0 {
                print("    🔄 Processing photo \(index)/\(totalAssets)...")
            }
            
            let filePath = "photos://asset/\(asset.localIdentifier)"
            
            // Check if this photo already exists (from another album)
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { photo in
                photo.filePath == filePath
            })
            if let existing = try? self.modelContext.fetch(descriptor).first {
                // Just add this folder to the existing photo
                if !existing.folders.contains(where: { $0.persistentModelID == folder.persistentModelID }) {
                    existing.folders.append(folder)
                }
                count += 1
                return
            }
            
            // Create new photo record
            let photo = Photo(
                filePath: filePath,
                fileName: self.getAssetFileName(asset),
                fileSize: self.estimateAssetSize(asset),
                folder: folder
            )
            
            // Extract metadata from PHAsset
            photo.captureDate = asset.creationDate
            photo.modificationDate = asset.modificationDate
            photo.width = asset.pixelWidth
            photo.height = asset.pixelHeight
            
            if let location = asset.location {
                photo.latitude = location.coordinate.latitude
                photo.longitude = location.coordinate.longitude
                photo.altitude = location.altitude
            }
            
            photo.hasFullMetadata = false
            
            self.modelContext.insert(photo)
            count += 1
        }
        
        return count
    }
    
    private func getAssetFileName(_ asset: PHAsset) -> String {
        // Try to get original filename
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first {
            return resource.originalFilename
        }
        
        // Fallback to identifier-based name
        return "IMG_\(asset.localIdentifier.prefix(8)).jpg"
    }
    
    private func estimateAssetSize(_ asset: PHAsset) -> Int64 {
        let resources = PHAssetResource.assetResources(for: asset)
        if let resource = resources.first,
           let size = resource.value(forKey: "fileSize") as? Int64 {
            return size
        }
        
        // Rough estimate based on dimensions
        let pixels = Int64(asset.pixelWidth * asset.pixelHeight)
        return pixels * 3 // Rough estimate: 3 bytes per pixel
    }
    
    private func generateThumbnail(for asset: PHAsset, imageManager: PHImageManager) async -> Data? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: 300, height: 300),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
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

enum PhotoLibraryError: Error {
    case permissionDenied
    case scanFailed
}
