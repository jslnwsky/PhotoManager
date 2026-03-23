import Foundation
import SwiftData
import Photos
import UIKit

@ModelActor
actor IndexingService {
    private let iCloudService = iCloudDriveService()
    private let metadataExtractor = MetadataExtractor()
    private var searchIndexRecords: [SearchIndexService.PhotoSearchRecord] = []
    
    func startIndexing(rootURL: URL, progressHandler: @escaping (Double) -> Void) async -> String? {
        do {
            progressHandler(0.0)

            let rootFolderName = rootURL.lastPathComponent
            let rootFolder = Folder(
                name: rootFolderName,
                path: "",
                sourceType: .iCloudDrive,
                parentFolder: nil
            )
            modelContext.insert(rootFolder)

            progressHandler(0.05)

            var photosProcessed = 0
            
            // Stream photos as they're discovered - process immediately
            try await iCloudService.streamPhotos(in: rootURL) { photoURL, folderPath in
                await self.processPhoto(url: photoURL, folderPath: folderPath)
                photosProcessed += 1
                
                // Save periodically to make photos visible in UI
                if photosProcessed % 50 == 0 {
                    try? await self.modelContext.save()
                }
            } progressHandler: { photosFound in
                // Progress updates continuously as photos are found
                // Using logarithmic scale so progress moves faster initially
                let progress = min(0.95, 0.05 + (log(Double(photosFound + 1)) / 10.0))
                progressHandler(progress)
                
                if photosFound % 100 == 0 {
                    print("📸 Found \(photosFound) photos so far...")
                }
            }
            
            try? modelContext.save()
            
            // Save search index records
            await saveSearchIndex()
            
            progressHandler(1.0)
            print("✅ Indexing complete: \(photosProcessed) photos indexed, \(searchIndexRecords.count) search records built")
            return nil
            
        } catch {
            print("❌ Indexing error: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }
    
    private func saveSearchIndex() async {
        guard !searchIndexRecords.isEmpty else { return }
        
        let startTime = Date()
        print("🔍 Saving search index with \(searchIndexRecords.count) records...")
        
        await SearchIndexService.shared.setIndex(searchIndexRecords)
        
        print("🔍 Search index saved in \(Date().timeIntervalSince(startTime))s")
    }
    
    private func createFolderHierarchy(from nodes: [FolderNode], parent: Folder) async {
        for node in nodes {
            let folder = Folder(
                name: node.name,
                path: node.path,
                sourceType: .iCloudDrive,
                parentFolder: parent
            )
            
            modelContext.insert(folder)
            
            if !node.children.isEmpty {
                await createFolderHierarchy(from: node.children, parent: folder)
            }
        }
    }
    
    private func processPhoto(url: URL, folderPath: String) async {
        let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { photo in
            photo.filePath == url.path
        })
        if let existing = try? modelContext.fetch(descriptor), !existing.isEmpty {
            print("Photo already indexed: \(url.lastPathComponent)")
            return
        }

        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = fileAttributes?[.size] as? Int64 ?? 0
        let folder = await findOrCreateFolder(path: folderPath)

        do {
            let metadata = try await metadataExtractor.extractMetadata(from: url)
            let thumbnailData = try await metadataExtractor.generateThumbnail(from: url)
            let metadataJSON = try? JSONSerialization.data(withJSONObject: sanitizeForJSON(metadata.rawMetadata), options: [.prettyPrinted])

            let photo = Photo(
                filePath: url.path,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                captureDate: metadata.captureDate,
                modificationDate: metadata.modificationDate,
                latitude: metadata.latitude,
                longitude: metadata.longitude,
                altitude: metadata.altitude,
                width: metadata.width,
                height: metadata.height,
                orientation: metadata.orientation,
                cameraMake: metadata.cameraMake,
                cameraModel: metadata.cameraModel,
                lensModel: metadata.lensModel,
                focalLength: metadata.focalLength,
                aperture: metadata.aperture,
                shutterSpeed: metadata.shutterSpeed,
                iso: metadata.iso,
                flash: metadata.flash,
                photoDescription: metadata.description,
                keywords: metadata.keywords ?? [],
                originalMetadataJSON: metadataJSON.flatMap { String(data: $0, encoding: .utf8) },
                thumbnailData: thumbnailData,
                hasFullMetadata: true,
                folder: folder
            )
            modelContext.insert(photo)
            
            // Build search index record
            addSearchIndexRecord(for: photo)
        } catch {
            print("Cloud-only photo, indexing with partial data: \(url.lastPathComponent)")
            let photo = Photo(
                filePath: url.path,
                fileName: url.lastPathComponent,
                fileSize: fileSize,
                thumbnailData: nil,
                hasFullMetadata: false,
                folder: folder
            )
            modelContext.insert(photo)
            
            // Build search index record (with limited data)
            addSearchIndexRecord(for: photo)
        }
    }
    
    private func addSearchIndexRecord(for photo: Photo) {
        let record = SearchIndexService.PhotoSearchRecord(
            id: photo.persistentModelID,
            fileName: photo.fileName,
            description: photo.photoDescription,
            keywords: photo.keywords,
            cameraMake: photo.cameraMake,
            cameraModel: photo.cameraModel,
            lensModel: photo.lensModel,
            city: photo.city,
            country: photo.country,
            captureDate: photo.captureDate,
            filePath: photo.filePath,
            tagNames: [] // Tags will be empty during initial scan
        )
        searchIndexRecords.append(record)
    }

    func enrichMetadata(rootURL: URL?, progressHandler: @escaping (Double) -> Void) async -> String? {
        do {
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { photo in
                photo.hasFullMetadata == false
            })
            let pending = try modelContext.fetch(descriptor)
            guard !pending.isEmpty else { return nil }

            let total = pending.count
            for (index, photo) in pending.enumerated() {
                await enrichSinglePhoto(photo, rootURL: rootURL)
                progressHandler(Double(index + 1) / Double(total))
            }
            try? modelContext.save()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func enrichSinglePhoto(_ photo: Photo, rootURL: URL?) async {
        // Check if this is a Photos Library photo (path starts with "photos://")
        if PhotoAssetHelper.isPhotosLibraryPhoto(photo) {
            await enrichPhotosLibraryPhoto(photo)
            return
        }
        
        // Handle iCloud Drive photos - skip if no rootURL provided
        guard let rootURL = rootURL else {
            print("[\(photo.fileName)] Skipping iCloud Drive photo - no rootURL")
            return
        }
        
        guard let url = photo.fileURL else { return }
        let accessing = rootURL.startAccessingSecurityScopedResource()
        defer { if accessing { rootURL.stopAccessingSecurityScopedResource() } }

        // Try to extract metadata and thumbnail without downloading
        // QLThumbnailGenerator can work with iCloud stubs
        let thumbnailData = await metadataExtractor.generateQLThumbnail(from: url)
        
        // Try to extract whatever metadata is available locally
        do {
            let metadata = try await metadataExtractor.extractMetadata(from: url)
            let metadataJSON = try? JSONSerialization.data(withJSONObject: sanitizeForJSON(metadata.rawMetadata), options: [.prettyPrinted])
            
            photo.captureDate = metadata.captureDate
            photo.modificationDate = metadata.modificationDate
            photo.latitude = metadata.latitude
            photo.longitude = metadata.longitude
            photo.altitude = metadata.altitude
            photo.width = metadata.width
            photo.height = metadata.height
            photo.orientation = metadata.orientation
            photo.cameraMake = metadata.cameraMake
            photo.cameraModel = metadata.cameraModel
            photo.lensModel = metadata.lensModel
            photo.focalLength = metadata.focalLength
            photo.aperture = metadata.aperture
            photo.shutterSpeed = metadata.shutterSpeed
            photo.iso = metadata.iso
            photo.flash = metadata.flash
            photo.photoDescription = metadata.description
            photo.keywords = metadata.keywords ?? []
            photo.originalMetadataJSON = metadataJSON.flatMap { String(data: $0, encoding: .utf8) }
            photo.thumbnailData = thumbnailData
            photo.hasFullMetadata = true
            
            print("[\(photo.fileName)] Enriched successfully")
        } catch {
            // If metadata extraction fails, at least save the thumbnail if we got one
            if thumbnailData != nil {
                photo.thumbnailData = thumbnailData
                print("[\(photo.fileName)] Thumbnail only (metadata unavailable)")
            } else {
                print("[\(photo.fileName)] Enrichment failed: \(error.localizedDescription)")
            }
        }
    }
    
    private func enrichPhotosLibraryPhoto(_ photo: Photo) async {
        guard let asset = PhotoAssetHelper.fetchAsset(for: photo) else {
            print("[\(photo.fileName)] Asset not found in Photos Library")
            return
        }
        
        // Request full image data to extract EXIF
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isSynchronous = false
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { imageData, _, _, _ in
                guard let imageData = imageData else {
                    print("[\(photo.fileName)] Failed to get image data")
                    continuation.resume()
                    return
                }
                
                Task {
                    // Always update fields available directly from PHAsset (more reliable than EXIF)
                    photo.captureDate = asset.creationDate
                    photo.modificationDate = asset.modificationDate
                    photo.width = asset.pixelWidth
                    photo.height = asset.pixelHeight
                    if let location = asset.location {
                        photo.latitude = location.coordinate.latitude
                        photo.longitude = location.coordinate.longitude
                        photo.altitude = location.altitude
                    }
                    
                    // Generate thumbnail from image data
                    if let uiImage = UIImage(data: imageData) {
                        let thumbSize = CGSize(width: 300, height: 300)
                        let renderer = UIGraphicsImageRenderer(size: thumbSize)
                        let scale = min(thumbSize.width / uiImage.size.width, thumbSize.height / uiImage.size.height)
                        let scaledSize = CGSize(width: uiImage.size.width * scale, height: uiImage.size.height * scale)
                        let origin = CGPoint(x: (thumbSize.width - scaledSize.width) / 2,
                                            y: (thumbSize.height - scaledSize.height) / 2)
                        let thumb = renderer.image { _ in
                            uiImage.draw(in: CGRect(origin: origin, size: scaledSize))
                        }
                        photo.thumbnailData = thumb.jpegData(compressionQuality: 0.7)
                    }
                    
                    // Extract EXIF metadata from image data
                    do {
                        let metadata = try await self.metadataExtractor.extractMetadataFromData(imageData)
                        let metadataJSON = try? JSONSerialization.data(withJSONObject: self.sanitizeForJSON(metadata.rawMetadata), options: [.prettyPrinted])
                        
                        photo.cameraMake = metadata.cameraMake
                        photo.cameraModel = metadata.cameraModel
                        photo.lensModel = metadata.lensModel
                        photo.focalLength = metadata.focalLength
                        photo.aperture = metadata.aperture
                        photo.shutterSpeed = metadata.shutterSpeed
                        photo.iso = metadata.iso
                        photo.flash = metadata.flash
                        photo.photoDescription = metadata.description
                        photo.keywords = metadata.keywords ?? []
                        photo.originalMetadataJSON = metadataJSON.flatMap { String(data: $0, encoding: .utf8) }
                        print("[\(photo.fileName)] Photos Library photo enriched with full EXIF")
                    } catch {
                        print("[\(photo.fileName)] EXIF extraction failed: \(error.localizedDescription)")
                    }
                    
                    photo.hasFullMetadata = true
                    continuation.resume()
                }
            }
        }
    }
    
    private func sanitizeForJSON(_ dict: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        for (key, value) in dict {
            if value is Data || value is NSData {
                continue
            } else if let nested = value as? [String: Any] {
                result[key] = sanitizeForJSON(nested)
            } else if let array = value as? [Any] {
                result[key] = array.filter { !($0 is Data) && !($0 is NSData) }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private func findOrCreateFolder(path: String) async -> Folder? {
        if path.isEmpty {
            let descriptor = FetchDescriptor<Folder>(
                predicate: #Predicate { folder in
                    folder.path == "" && folder.sourceType == "iCloudDrive"
                }
            )
            return try? modelContext.fetch(descriptor).first
        }
        
        let descriptor = FetchDescriptor<Folder>(
            predicate: #Predicate { folder in
                folder.path == path && folder.sourceType == "iCloudDrive"
            }
        )
        
        if let existingFolder = try? modelContext.fetch(descriptor).first {
            return existingFolder
        }
        
        let pathComponents = path.split(separator: "/").map(String.init)
        var currentPath = ""
        var parentFolder: Folder? = nil
        
        for component in pathComponents {
            currentPath = currentPath.isEmpty ? component : "\(currentPath)/\(component)"
            
            let folderDescriptor = FetchDescriptor<Folder>(
                predicate: #Predicate { folder in
                    folder.path == currentPath && folder.sourceType == "iCloudDrive"
                }
            )
            
            if let existing = try? modelContext.fetch(folderDescriptor).first {
                parentFolder = existing
            } else {
                let newFolder = Folder(
                    name: component,
                    path: currentPath,
                    sourceType: .iCloudDrive,
                    parentFolder: parentFolder
                )
                modelContext.insert(newFolder)
                parentFolder = newFolder
            }
        }
        
        return parentFolder
    }
}
