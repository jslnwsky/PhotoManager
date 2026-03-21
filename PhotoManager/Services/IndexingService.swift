import Foundation
import SwiftData
import Photos

@ModelActor
actor IndexingService {
    private let iCloudService = iCloudDriveService()
    private let metadataExtractor = MetadataExtractor()
    
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

            // Skip pre-building folder tree to avoid hanging on large directories
            // Folders will be created on-demand during photo processing
            // let folderStructure = try await iCloudService.getFolderStructure(in: rootURL)
            // await createFolderHierarchy(from: folderStructure, parent: rootFolder)

            progressHandler(0.1)

            var discoveredPhotos: [(url: URL, folderPath: String)] = []

            discoveredPhotos = try await iCloudService.discoverPhotos(in: rootURL) { processed, total in
                let progress = 0.1 + (Double(processed) / Double(total)) * 0.3
                progressHandler(progress)
            }
            
            progressHandler(0.4)
            
            let totalPhotos = discoveredPhotos.count
            var processedPhotos = 0
            
            for (photoURL, folderPath) in discoveredPhotos {
                await processPhoto(url: photoURL, folderPath: folderPath)
                processedPhotos += 1
                
                if processedPhotos % 10 == 0 || processedPhotos == totalPhotos {
                    let progress = 0.4 + (Double(processedPhotos) / Double(totalPhotos)) * 0.6
                    progressHandler(progress)
                }
            }
            
            try? modelContext.save()
            progressHandler(1.0)
            print("Indexing complete: \(totalPhotos) photos indexed")
            return nil
            
        } catch {
            print("Indexing error: \(error.localizedDescription)")
            return error.localizedDescription
        }
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
        }
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
        if photo.filePath.hasPrefix("photos://asset/") {
            await enrichPhotosLibraryPhoto(photo)
            return
        }
        
        // Handle iCloud Drive photos - skip if no rootURL provided
        guard let rootURL = rootURL else {
            print("[\(photo.fileName)] Skipping iCloud Drive photo - no rootURL")
            return
        }
        
        let url = photo.fileURL
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
        // Extract asset identifier from path (format: "photos://asset/{localIdentifier}")
        let identifier = String(photo.filePath.dropFirst("photos://asset/".count))
        
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
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
                
                // Extract EXIF metadata from image data
                Task {
                    do {
                        let metadata = try await self.metadataExtractor.extractMetadataFromData(imageData)
                        let metadataJSON = try? JSONSerialization.data(withJSONObject: self.sanitizeForJSON(metadata.rawMetadata), options: [.prettyPrinted])
                        
                        // Update photo with full EXIF data
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
                        photo.hasFullMetadata = true
                        
                        print("[\(photo.fileName)] Photos Library photo enriched with full EXIF")
                    } catch {
                        print("[\(photo.fileName)] EXIF extraction failed: \(error.localizedDescription)")
                    }
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
