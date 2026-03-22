import Foundation
import SwiftData
import Photos

@Observable
class FoldersViewModel {
    var isScanning = false
    var scanProgress: Double = 0.0
    var scanError: String? = nil
    var isEnriching = false
    var enrichProgress: Double = 0.0
    var enrichError: String? = nil
    var isScanningPhotos = false
    var photoScanProgress: Double = 0.0
    var photoScanError: String? = nil
    var isGeocoding = false
    var geocodeProgress: Double = 0.0
    var geocodeStatus: String = ""
    var geocodeError: String? = nil

    // Retained to prevent ModelActor deallocation during scan
    private var photoLibraryService: PhotoLibraryService? = nil

    var isBusy: Bool {
        isScanning || isEnriching || isScanningPhotos || isGeocoding
    }

    var storedRootURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: "rootFolderBookmark") else { return nil }
        var isStale = false
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        if isStale { UserDefaults.standard.removeObject(forKey: "rootFolderBookmark") }
        return isStale ? nil : url
    }

    func saveBookmark(for url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: "rootFolderBookmark")
        }
    }

    func startScan(rootURL: URL, container: ModelContainer) {
        isScanning = true
        scanError = nil
        scanProgress = 0.0
        Task {
            let accessing = rootURL.startAccessingSecurityScopedResource()
            let service = IndexingService(modelContainer: container)
            let error = await service.startIndexing(rootURL: rootURL) { progress in
                Task { @MainActor in self.scanProgress = progress }
            }
            if accessing { rootURL.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                self.isScanning = false
                self.scanError = error
            }
        }
    }

    func startEnrich(rootURL: URL?, container: ModelContainer) {
        isEnriching = true
        enrichError = nil
        enrichProgress = 0.0
        Task {
            let accessing = rootURL?.startAccessingSecurityScopedResource() ?? false
            let service = IndexingService(modelContainer: container)
            let error = await service.enrichMetadata(rootURL: rootURL) { progress in
                Task { @MainActor in self.enrichProgress = progress }
            }
            if accessing { rootURL?.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                self.isEnriching = false
                self.enrichError = error
            }
        }
    }

    func startPhotoLibraryScan(container: ModelContainer) {
        isScanningPhotos = true
        photoScanError = nil
        photoScanProgress = 0.0
        Task {
            let service = PhotoLibraryService(modelContainer: container)
            await MainActor.run { self.photoLibraryService = service }
            do {
                let result = try await service.scanPhotosLibrary()
                await MainActor.run {
                    self.isScanningPhotos = false
                    self.photoLibraryService = nil
                    print("Photos Library scan complete: \(result.photoCount) photos in \(result.albumCount) albums")
                }
            } catch {
                await MainActor.run {
                    self.isScanningPhotos = false
                    self.photoLibraryService = nil
                    self.photoScanError = error.localizedDescription
                }
            }
        }
    }

    func startGeocoding(container: ModelContainer) {
        isGeocoding = true
        geocodeError = nil
        geocodeProgress = 0.0
        geocodeStatus = ""
        Task {
            // First, backfill PhotoLocation for existing geotagged photos
            await backfillPhotoLocations(container: container)
            
            // Then run geocoding (which will also populate PhotoLocation for newly geocoded photos)
            let service = GeocodingService(modelContainer: container)
            let error = await service.geocodePhotos { progress, status in
                Task { @MainActor in
                    self.geocodeProgress = progress
                    self.geocodeStatus = status
                }
            }
            await MainActor.run {
                self.isGeocoding = false
                self.geocodeError = error
            }
        }
    }
    
    private func backfillPhotoLocations(container: ModelContainer) async {
        let context = ModelContext(container)
        do {
            // Find all geotagged photos
            let descriptor = FetchDescriptor<Photo>(
                predicate: #Predicate { $0.latitude != nil }
            )
            let geotaggedPhotos = try context.fetch(descriptor)
            
            print("🗺️ Backfilling PhotoLocation for \(geotaggedPhotos.count) geotagged photos...")
            
            // Fetch all existing PhotoLocations once
            let allLocations = (try? context.fetch(FetchDescriptor<PhotoLocation>())) ?? []
            let existingPaths = Set(allLocations.map { $0.photoFilePath })
            
            var created = 0
            for photo in geotaggedPhotos {
                guard let lat = photo.latitude, let lon = photo.longitude else { continue }
                
                // Check if PhotoLocation already exists
                if !existingPaths.contains(photo.filePath) {
                    let photoLocation = PhotoLocation(
                        photoFilePath: photo.filePath,
                        latitude: lat,
                        longitude: lon,
                        captureDate: photo.captureDate
                    )
                    context.insert(photoLocation)
                    created += 1
                }
                
                if created % 500 == 0 && created > 0 {
                    try? context.save()
                    print("  💾 Created \(created) PhotoLocation records...")
                }
            }
            
            try? context.save()
            print("✅ Backfill complete: \(created) PhotoLocation records created")
        } catch {
            print("❌ Backfill error: \(error)")
        }
    }
}
