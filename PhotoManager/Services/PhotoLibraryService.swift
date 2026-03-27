import Foundation
import Photos
import SwiftData

@ModelActor
actor PhotoLibraryService {
    // In-memory set of known file paths — eliminates ALL DB queries for duplicate detection
    private var knownPaths: Set<String> = []
    
    private enum CheckpointPhase: String {
        case allPhotos
        case userAlbums
        case smartAlbums
    }
    
    private enum CheckpointKey {
        static let phase = "photos.scan.checkpoint.phase"
        static let allPhotosStartIndex = "photos.scan.checkpoint.allPhotosStartIndex"
        static let userAlbumIndex = "photos.scan.checkpoint.userAlbumIndex"
        static let smartAlbumIndex = "photos.scan.checkpoint.smartAlbumIndex"
    }
    
    private struct ScanCheckpoint {
        let phase: CheckpointPhase?
        let allPhotosStartIndex: Int
        let userAlbumIndex: Int
        let smartAlbumIndex: Int
    }
    
    func scanPhotosLibrary() async throws -> (photoCount: Int, albumCount: Int) {
        print("📸 Starting Photos Library scan...")
        
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized else {
            print("❌ Photo library permission denied")
            throw PhotoLibraryError.permissionDenied
        }
        
        print("✅ Photo library permission granted")
        
        var photoCount = 0
        var albumCount = 0
        knownPaths = loadExistingPhotoPaths()
        knownPaths.reserveCapacity(max(20_000, knownPaths.count + 20_000))
        print("📊 Loaded \(knownPaths.count) existing photo paths")
        
        let checkpoint = loadScanCheckpoint()
        if let phase = checkpoint.phase {
            print("♻️ Resuming scan from checkpoint: \(phase.rawValue) (all=\(checkpoint.allPhotosStartIndex), user=\(checkpoint.userAlbumIndex), smart=\(checkpoint.smartAlbumIndex))")
        }
        
        // Ensure root folder exists
        guard getOrCreateFolder(
            in: modelContext,
            name: "Photos Library",
            path: "photos://library",
            sourceType: .localPhotos,
            parentPath: nil
        ) != nil else {
            throw PhotoLibraryError.scanFailed
        }
        try modelContext.save()
        print("📁 Ready root folder: Photos Library")
        
        // Phase A: Canonical photo creation from All Photos first
        print("📚 Creating/updating 'All Photos' canonical set...")
        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allAssets = PHAsset.fetchAssets(with: .image, options: allPhotosOptions)
        print("📊 Found \(allAssets.count) total photos")
        
        if allAssets.count > 0 {
            let resumeAllPhotosIndex = checkpoint.phase == .allPhotos ? checkpoint.allPhotosStartIndex : 0
            let allPhotosContext = ModelContext(modelContainer)
            guard getOrCreateFolder(
                in: allPhotosContext,
                name: "All Photos",
                path: "photos://all",
                sourceType: .localPhotos,
                parentPath: "photos://library"
            ) != nil else {
                throw PhotoLibraryError.scanFailed
            }
            try allPhotosContext.save()
            albumCount += 1
            print("💾 Saved All Photos folder to database")
            
            let newAllPhotos = await processAllPhotosCanonical(allAssets, folderPath: "photos://all", startIndex: resumeAllPhotosIndex)
            photoCount += newAllPhotos
            print("✅ All Photos complete: \(newAllPhotos) new photos indexed")
        }
        
        // Phase B: Album membership linking only (no photo creation)
        let albumFetchOptions = PHFetchOptions()
        let userAlbums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: albumFetchOptions)
        let smartAlbums = PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .any, options: albumFetchOptions)
        
        let userStartIndex: Int
        if checkpoint.phase == .smartAlbums {
            userStartIndex = userAlbums.count
        } else if checkpoint.phase == .userAlbums {
            userStartIndex = checkpoint.userAlbumIndex
        } else {
            userStartIndex = 0
        }
        
        print("📚 Linking memberships for \(userAlbums.count) user albums...")
        let (userAlbumCount, userLinkedCount) = await processAlbumsMembershipOnly(
            userAlbums,
            phase: .userAlbums,
            startIndex: userStartIndex
        )
        albumCount += userAlbumCount
        print("✅ User albums complete: \(userAlbumCount) albums, \(userLinkedCount) memberships linked")
        
        print("📚 Linking memberships for \(smartAlbums.count) smart albums...")
        let smartStartIndex = checkpoint.phase == .smartAlbums ? checkpoint.smartAlbumIndex : 0
        let (smartAlbumCount, smartLinkedCount) = await processAlbumsMembershipOnly(
            smartAlbums,
            phase: .smartAlbums,
            startIndex: smartStartIndex,
            skipRecents: true
        )
        albumCount += smartAlbumCount
        print("✅ Smart albums complete: \(smartAlbumCount) albums, \(smartLinkedCount) memberships linked")
        
        clearScanCheckpoint()
        print("🎉 Photos Library scan complete: \(photoCount) new photos, \(albumCount) albums")
        return (photoCount, albumCount)
    }
    
    private func processAlbumsMembershipOnly(
        _ albums: PHFetchResult<PHAssetCollection>,
        phase: CheckpointPhase,
        startIndex: Int,
        skipRecents: Bool = false
    ) async -> (albumCount: Int, linkedCount: Int) {
        var albumCount = 0
        var linkedCount = 0
        
        for i in max(0, startIndex)..<albums.count {
            let collection = albums.object(at: i)
            let albumName = collection.localizedTitle ?? "Untitled Album"
            
            if skipRecents && albumName == "Recents" {
                print("  ⏭️  Skipping \(albumName) (using All Photos instead)")
                saveScanCheckpoint(phase: phase, userAlbumIndex: phase == .userAlbums ? i + 1 : nil, smartAlbumIndex: phase == .smartAlbums ? i + 1 : nil)
                continue
            }
            
            let assetFetchOptions = PHFetchOptions()
            assetFetchOptions.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
            let assets = PHAsset.fetchAssets(in: collection, options: assetFetchOptions)
            
            if assets.count > 0 {
                print("  📁 [\(i+1)/\(albums.count)] \(albumName): \(assets.count) photos")
                
                let albumContext = ModelContext(modelContainer)
                let albumPath = "photos://album/\(collection.localIdentifier)"
                
                guard getOrCreateFolder(
                    in: albumContext,
                    name: albumName,
                    path: albumPath,
                    sourceType: .localPhotos,
                    parentPath: "photos://library"
                ) != nil else {
                    print("  ⚠️ Failed to create/fetch folder for \(albumName)")
                    continue
                }
                albumCount += 1
                
                do {
                    try albumContext.save()
                    print("  💾 Saved folder to database")
                } catch {
                    print("  ⚠️  Failed to save folder: \(error.localizedDescription)")
                    continue
                }
                
                let linked = linkExistingPhotosToFolder(assets, folderPath: albumPath)
                linkedCount += linked
                print("  ✅ \(albumName): linked \(linked) photos")
            }
            
            saveScanCheckpoint(phase: phase, userAlbumIndex: phase == .userAlbums ? i + 1 : nil, smartAlbumIndex: phase == .smartAlbums ? i + 1 : nil)
        }
        
        return (albumCount, linkedCount)
    }
    
    /// Phase A: Create canonical Photo rows from All Photos only (idempotent via knownPaths)
    private func processAllPhotosCanonical(_ assets: PHFetchResult<PHAsset>, folderPath: String, startIndex: Int) async -> Int {
        let totalAssets = assets.count
        var totalNewCount = 0
        var totalSkippedCount = 0
        let chunkSize = 500
        
        var currentIndex = max(0, startIndex)
        while currentIndex < totalAssets {
            let endIndex = min(currentIndex + chunkSize, totalAssets)
            let chunkStartTime = Date()
            let chunkContext = ModelContext(modelContainer)

            let folderDesc = FetchDescriptor<Folder>(predicate: #Predicate { $0.path == folderPath })
            guard let folder = try? chunkContext.fetch(folderDesc).first else {
                print("    ⚠️ Failed to fetch folder in chunk context")
                return totalNewCount
            }
            
            var chunkNewCount = 0
            var chunkSkippedCount = 0
            var chunkIndexIDs: [PersistentIdentifier] = []
            for index in startIndex..<endIndex {
                autoreleasepool {
                    let asset = assets.object(at: index)
                    let filePath = "photos://asset/\(asset.localIdentifier)"
                    
                    if knownPaths.contains(filePath) {
                        chunkSkippedCount += 1
                        return
                    }
                    
                    let photo = Photo(
                        filePath: filePath,
                        fileName: "IMG_\(asset.localIdentifier.prefix(8)).jpg",
                        fileSize: assetFileSize(asset),
                        folder: folder
                    )
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
                    chunkContext.insert(photo)
                    chunkIndexIDs.append(photo.persistentModelID)
                    knownPaths.insert(filePath)
                    chunkNewCount += 1
                }
            }
            
            try? chunkContext.save()
            await publishIndexUpserts(for: chunkIndexIDs)
            totalNewCount += chunkNewCount
            totalSkippedCount += chunkSkippedCount
            let chunkDurationMs = Int(Date().timeIntervalSince(chunkStartTime) * 1000)
            saveScanCheckpoint(phase: .allPhotos, allPhotosStartIndex: endIndex)
            
            print("    🔄 All Photos chunk \(currentIndex)-\(endIndex): +\(chunkNewCount) new, \(chunkSkippedCount) skipped, \(chunkDurationMs)ms, knownPaths=\(knownPaths.count)")
            currentIndex = endIndex
        }
        saveScanCheckpoint(phase: .userAlbums, allPhotosStartIndex: 0, userAlbumIndex: 0, smartAlbumIndex: 0)
        
        print("    📊 All Photos: \(totalNewCount) new, \(totalSkippedCount) skipped, total=\(totalAssets)")
        return totalNewCount
    }

    private func publishIndexUpserts(for ids: [PersistentIdentifier]) async {
        guard !ids.isEmpty else { return }

        let idSet = Set(ids)
        let container = modelContainer

        await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Photo>(
                predicate: #Predicate { photo in
                    idSet.contains(photo.persistentModelID)
                }
            )

            guard let photos = try? context.fetch(descriptor), !photos.isEmpty else { return }
            SearchIndexService.shared.upsertPhotos(photos)
        }
    }
    
    /// Phase B: Link existing canonical photos to album folder memberships only
    private func linkExistingPhotosToFolder(_ assets: PHFetchResult<PHAsset>, folderPath: String) -> Int {
        let totalAssets = assets.count
        let chunkSize = 500
        var linkedCount = 0
        var foundCount = 0
        var missingCanonicalCount = 0
        
        var startIndex = 0
        while startIndex < totalAssets {
            let endIndex = min(startIndex + chunkSize, totalAssets)
            let chunkStartTime = Date()
            let chunkContext = ModelContext(modelContainer)
            
            let folderDesc = FetchDescriptor<Folder>(predicate: #Predicate { $0.path == folderPath })
            guard let folder = try? chunkContext.fetch(folderDesc).first else {
                print("    ⚠️ Failed to fetch folder in membership chunk context")
                return linkedCount
            }
            
            var chunkLinkedCount = 0
            var chunkFoundCount = 0
            var chunkMissingCanonicalCount = 0
            for index in startIndex..<endIndex {
                autoreleasepool {
                    let asset = assets.object(at: index)
                    let filePath = "photos://asset/\(asset.localIdentifier)"
                    
                    guard knownPaths.contains(filePath) else {
                        chunkMissingCanonicalCount += 1
                        return
                    }
                    chunkFoundCount += 1
                    
                    let photoDesc = FetchDescriptor<Photo>(predicate: #Predicate { $0.filePath == filePath })
                    guard let photo = try? chunkContext.fetch(photoDesc).first else {
                        return
                    }
                    
                    if !photo.folders.contains(where: { $0.path == folder.path }) {
                        photo.folders.append(folder)
                        linkedCount += 1
                        chunkLinkedCount += 1
                    }
                }
            }
            
            try? chunkContext.save()
            foundCount += chunkFoundCount
            missingCanonicalCount += chunkMissingCanonicalCount
            let chunkDurationMs = Int(Date().timeIntervalSince(chunkStartTime) * 1000)
            print("    🔗 Membership chunk \(startIndex)-\(endIndex): linked=\(chunkLinkedCount), found=\(chunkFoundCount), missingCanonical=\(chunkMissingCanonicalCount), \(chunkDurationMs)ms")
            startIndex = endIndex
        }
        print("    📊 Membership summary for \(folderPath): linked=\(linkedCount), found=\(foundCount), missingCanonical=\(missingCanonicalCount), total=\(totalAssets)")
        
        return linkedCount
    }
    
    private func loadExistingPhotoPaths() -> Set<String> {
        var descriptor = FetchDescriptor<Photo>()
        descriptor.propertiesToFetch = [\.filePath]
        let existingPhotos = (try? modelContext.fetch(descriptor)) ?? []
        return Set(existingPhotos.map { $0.filePath })
    }

    private func assetFileSize(_ asset: PHAsset) -> Int64 {
        for resource in PHAssetResource.assetResources(for: asset) {
            if let value = resource.value(forKey: "fileSize") as? Int64 {
                return max(0, value)
            }
            if let value = resource.value(forKey: "fileSize") as? CLong {
                return max(0, Int64(value))
            }
            if let value = resource.value(forKey: "fileSize") as? NSNumber {
                return max(0, value.int64Value)
            }
        }
        return 0
    }

    private func loadScanCheckpoint() -> ScanCheckpoint {
        let defaults = UserDefaults.standard
        let phaseRaw = defaults.string(forKey: CheckpointKey.phase)
        let phase = phaseRaw.flatMap(CheckpointPhase.init(rawValue:))
        let allIndex = defaults.integer(forKey: CheckpointKey.allPhotosStartIndex)
        let userIndex = defaults.integer(forKey: CheckpointKey.userAlbumIndex)
        let smartIndex = defaults.integer(forKey: CheckpointKey.smartAlbumIndex)
        return ScanCheckpoint(
            phase: phase,
            allPhotosStartIndex: max(0, allIndex),
            userAlbumIndex: max(0, userIndex),
            smartAlbumIndex: max(0, smartIndex)
        )
    }

    private func saveScanCheckpoint(
        phase: CheckpointPhase,
        allPhotosStartIndex: Int? = nil,
        userAlbumIndex: Int? = nil,
        smartAlbumIndex: Int? = nil
    ) {
        let defaults = UserDefaults.standard
        defaults.set(phase.rawValue, forKey: CheckpointKey.phase)
        if let allPhotosStartIndex {
            defaults.set(allPhotosStartIndex, forKey: CheckpointKey.allPhotosStartIndex)
        }
        if let userAlbumIndex {
            defaults.set(userAlbumIndex, forKey: CheckpointKey.userAlbumIndex)
        }
        if let smartAlbumIndex {
            defaults.set(smartAlbumIndex, forKey: CheckpointKey.smartAlbumIndex)
        }
    }

    private func clearScanCheckpoint() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: CheckpointKey.phase)
        defaults.removeObject(forKey: CheckpointKey.allPhotosStartIndex)
        defaults.removeObject(forKey: CheckpointKey.userAlbumIndex)
        defaults.removeObject(forKey: CheckpointKey.smartAlbumIndex)
    }
    
    private func getOrCreateFolder(
        in context: ModelContext,
        name: String,
        path: String,
        sourceType: FolderSource,
        parentPath: String?
    ) -> Folder? {
        let existingDesc = FetchDescriptor<Folder>(predicate: #Predicate { $0.path == path })
        if let existing = try? context.fetch(existingDesc).first {
            return existing
        }
        
        var parentFolder: Folder? = nil
        if let parentPath {
            let parentDesc = FetchDescriptor<Folder>(predicate: #Predicate { $0.path == parentPath })
            parentFolder = try? context.fetch(parentDesc).first
        }
        
        let folder = Folder(
            name: name,
            path: path,
            sourceType: sourceType,
            parentFolder: parentFolder
        )
        context.insert(folder)
        return folder
    }
    
}

enum PhotoLibraryError: Error {
    case permissionDenied
    case scanFailed
}
