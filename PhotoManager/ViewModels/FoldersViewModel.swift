import Foundation
import SwiftData
import Photos

@Observable
class FoldersViewModel {
    struct RootFolderMetrics: Codable {
        let totalPhotosRecursive: Int
        let duplicatePhotosRecursive: Int
        let uniquePhotosRecursive: Int
        let ungeotaggedPhotosRecursive: Int
        let updatedAt: Date
    }

    private enum RootFolderMetricsStore {
        private static let storageKey = "folders.root.metrics.v1"

        static func load() -> [FolderSource: RootFolderMetrics] {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let raw = try? JSONDecoder().decode([String: RootFolderMetrics].self, from: data) else {
                return [:]
            }

            var parsed: [FolderSource: RootFolderMetrics] = [:]
            for (key, value) in raw {
                if let source = FolderSource(rawValue: key) {
                    parsed[source] = value
                }
            }
            return parsed
        }

        static func save(_ metrics: [FolderSource: RootFolderMetrics]) {
            let raw = Dictionary(uniqueKeysWithValues: metrics.map { ($0.key.rawValue, $0.value) })
            guard let data = try? JSONEncoder().encode(raw) else { return }
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }

    enum EnrichmentTriggerSource: String {
        case postICloudScan = "post_iCloud_scan"
        case postPhotosLibraryScan = "post_photos_library_scan"
    }

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
    var isRecalculatingFileSizes = false
    var fileSizeRecalcProgress: Double = 0.0
    var fileSizeRecalcStatus: String = ""
    var fileSizeRecalcError: String? = nil
    var isBackingUp = false
    var backupStatus: String = ""
    var backupError: String? = nil
    var isRestoring = false
    var restoreStatus: String = ""
    var restoreError: String? = nil
    private var pendingSafetySnapshotPath: String? = nil
    var rootFolderMetrics: [FolderSource: RootFolderMetrics] = RootFolderMetricsStore.load()
    private var rootMetricsRefreshTask: Task<Void, Never>?

    var backupAutomationEnabled: Bool = BackupAutomationSettingsStore.automationEnabled {
        didSet {
            BackupAutomationSettingsStore.automationEnabled = backupAutomationEnabled
        }
    }

    var preferredBackupHour: Int = BackupAutomationSettingsStore.preferredHour {
        didSet {
            BackupAutomationSettingsStore.preferredHour = preferredBackupHour
        }
    }

    var backupFrequency: BackupAutomationSettingsStore.BackupFrequency = BackupAutomationSettingsStore.backupFrequency {
        didSet {
            BackupAutomationSettingsStore.backupFrequency = backupFrequency
        }
    }

    var backupDestinationDisplayName: String?

    var hasStoredBackupDestination: Bool {
        backupDestinationDisplayName != nil
    }
    
    // Background enrichment pipeline status
    var enrichmentPhase: EnrichmentPhase = .idle
    var enrichmentProgress: Double = 0.0
    var enrichmentDetail: String = ""
    var lastEnrichmentTrigger: String = ""

    // Retained to prevent ModelActor deallocation during scan
    private var photoLibraryService: PhotoLibraryService? = nil

    var isBusy: Bool {
        isScanning || isEnriching || isScanningPhotos || isGeocoding || isRecalculatingFileSizes || isBackingUp || isRestoring || enrichmentPhase != .idle
    }

    var hasPendingRestoreAcceptance: Bool {
        pendingSafetySnapshotPath != nil && !isRestoring
    }
    
    var isEnrichmentRunning: Bool {
        enrichmentPhase != .idle
    }

    private var isPhotoPipelineLocked: Bool {
        isScanningPhotos || isEnrichmentRunning || isEnriching
    }

    private var isAnyPipelineLocked: Bool {
        isScanning || isPhotoPipelineLocked
    }
    
    enum EnrichmentPhase: String {
        case idle = ""
        case buildingSearchIndex = "Building search index..."
        case extractingMetadata = "Extracting photo metadata..."
        case hashing = "Computing content hashes..."
        case geocoding = "Geocoding locations..."
    }

    init() {
        refreshBackupDestinationState()
    }

    var storedRootURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: "rootFolderBookmark") else { return nil }
        var isStale = false
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        if isStale { UserDefaults.standard.removeObject(forKey: "rootFolderBookmark") }
        return isStale ? nil : url
    }

    var storedBackupDestinationURL: URL? {
        BackupAutomationSettingsStore.resolveDestinationURL()
    }

    func refreshBackupDestinationState() {
        backupDestinationDisplayName = storedBackupDestinationURL?.lastPathComponent
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

    func saveBackupDestinationBookmark(for url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        do {
            let bookmark = try url.bookmarkData(
                options: .minimalBookmark,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            BackupAutomationSettingsStore.destinationBookmarkData = bookmark
            refreshBackupDestinationState()
            backupError = nil
            backupStatus = "Backup destination set: \(backupDestinationDisplayName ?? url.lastPathComponent)"
        } catch {
            backupError = "Failed to save bookmark: \(error.localizedDescription)"
        }
    }

    func startScan(rootURL: URL, container: ModelContainer) {
        guard !isAnyPipelineLocked else { return }
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
                if error == nil {
                    self.scheduleRootFolderMetricsRefresh(container: container)
                }
            }
            // Auto-trigger background enrichment pipeline
            if error == nil {
                await self.runEnrichmentPipeline(
                    container: container,
                    rootURL: rootURL,
                    source: .postICloudScan
                )
            }
        }
    }

    func startEnrich(rootURL: URL?, container: ModelContainer) {
        guard !isAnyPipelineLocked else { return }
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
        guard !isAnyPipelineLocked else { return }
        isScanningPhotos = true
        photoScanError = nil
        photoScanProgress = 0.0
        Task {
            let service = PhotoLibraryService(modelContainer: container)
            await MainActor.run { self.photoLibraryService = service }
            var scanSucceeded = false
            do {
                let result = try await service.scanPhotosLibrary()
                await MainActor.run {
                    self.isScanningPhotos = false
                    self.photoLibraryService = nil
                    print("Photos Library scan complete: \(result.photoCount) photos in \(result.albumCount) albums")
                    self.scheduleRootFolderMetricsRefresh(container: container)
                }
                scanSucceeded = true
            } catch {
                await MainActor.run {
                    self.isScanningPhotos = false
                    self.photoLibraryService = nil
                    self.photoScanError = error.localizedDescription
                }
            }
            // Auto-trigger background enrichment pipeline
            if scanSucceeded {
                await self.runEnrichmentPipeline(
                    container: container,
                    rootURL: nil,
                    source: .postPhotosLibraryScan
                )
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
                if error == nil {
                    self.scheduleRootFolderMetricsRefresh(container: container)
                }
            }
        }
    }

    func startRecalculatePhotosLibraryFileSizes(container: ModelContainer) {
        guard !isBusy else { return }
        isRecalculatingFileSizes = true
        fileSizeRecalcProgress = 0.0
        fileSizeRecalcError = nil
        fileSizeRecalcStatus = "Recalculating Photos file sizes..."

        Task {
            let service = IndexingService(modelContainer: container)
            let result = await service.recalculatePhotosLibraryFileSizes { progress in
                Task { @MainActor in
                    self.fileSizeRecalcProgress = progress
                }
            }

            await MainActor.run {
                self.isRecalculatingFileSizes = false
                if let error = result.error {
                    self.fileSizeRecalcError = error
                    self.fileSizeRecalcStatus = ""
                } else {
                    self.fileSizeRecalcStatus = "Updated \(result.updated) of \(result.total) Photos Library file sizes"
                }
            }
        }
    }

    func startBackup(destinationFolderURL: URL, container: ModelContainer) {
        guard !isBusy else { return }
        isBackingUp = true
        backupError = nil
        backupStatus = "Preparing backup..."
        saveBackupDestinationBookmark(for: destinationFolderURL)

        Task {
            let accessing = destinationFolderURL.startAccessingSecurityScopedResource()
            do {
                let backupService = BackupService(modelContainer: container)
                let backupFolderURL = try backupService.createBackupUsingLocalStaging(
                    in: destinationFolderURL,
                    progressHandler: { status in
                        Task { @MainActor in
                            self.backupStatus = status
                        }
                    }
                )
                BackupAutomationSettingsStore.lastBackupAt = Date()
                await MainActor.run {
                    self.isBackingUp = false
                    self.backupStatus = "Backup created: \(backupFolderURL.lastPathComponent)"
                }
            } catch {
                await MainActor.run {
                    self.isBackingUp = false
                    self.backupError = error.localizedDescription
                    self.backupStatus = ""
                }
            }
            if accessing { destinationFolderURL.stopAccessingSecurityScopedResource() }
        }
    }

    func startBackup(container: ModelContainer) {
        guard let destination = storedBackupDestinationURL else {
            backupError = "Set a backup destination first"
            return
        }
        startBackup(destinationFolderURL: destination, container: container)
    }

    func loadRestorePreview(backupFolderURL: URL, container: ModelContainer) throws -> BackupService.BackupPreview {
        let backupService = BackupService(modelContainer: container)
        return try backupService.loadBackupPreview(from: backupFolderURL)
    }

    func startRestore(backupFolderURL: URL, container: ModelContainer) {
        guard !isBusy else { return }
        isRestoring = true
        restoreError = nil
        restoreStatus = "Restoring backup..."

        Task {
            let accessing = backupFolderURL.startAccessingSecurityScopedResource()
            do {
                let backupService = BackupService(modelContainer: container)
                let safetySnapshotURL = try backupService.createSafetySnapshot()

                await MainActor.run {
                    self.restoreStatus = "Safety snapshot created: \(safetySnapshotURL.lastPathComponent). Restoring backup..."
                }

                try backupService.restoreBackup(from: backupFolderURL)

                let indexContext = ModelContext(container)
                await SearchIndexService.shared.buildIndex(modelContext: indexContext)

                await MainActor.run {
                    self.isRestoring = false
                    self.pendingSafetySnapshotPath = safetySnapshotURL.path
                    self.restoreStatus = "Restore complete. Verify data, then Accept Restore or Rollback."
                    self.scheduleRootFolderMetricsRefresh(container: container)
                }
            } catch {
                await MainActor.run {
                    self.isRestoring = false
                    self.restoreError = error.localizedDescription
                    self.restoreStatus = ""
                }
            }
            if accessing { backupFolderURL.stopAccessingSecurityScopedResource() }
        }
    }

    func acceptRestore(container: ModelContainer) {
        guard let snapshotPath = pendingSafetySnapshotPath else { return }
        do {
            let backupService = BackupService(modelContainer: container)
            try backupService.deleteSnapshot(at: URL(fileURLWithPath: snapshotPath))
            pendingSafetySnapshotPath = nil
            restoreError = nil
            restoreStatus = "Restore accepted. Safety snapshot deleted."
        } catch {
            restoreError = error.localizedDescription
        }
    }

    func rollbackRestore(container: ModelContainer) {
        guard let snapshotPath = pendingSafetySnapshotPath, !isBusy else { return }
        isRestoring = true
        restoreError = nil
        restoreStatus = "Rolling back to safety snapshot..."

        Task {
            do {
                let snapshotURL = URL(fileURLWithPath: snapshotPath)
                let backupService = BackupService(modelContainer: container)
                try backupService.restoreBackup(from: snapshotURL)

                let indexContext = ModelContext(container)
                await SearchIndexService.shared.buildIndex(modelContext: indexContext)

                try backupService.deleteSnapshot(at: snapshotURL)

                await MainActor.run {
                    self.pendingSafetySnapshotPath = nil
                    self.isRestoring = false
                    self.restoreStatus = "Rollback complete. Safety snapshot deleted."
                    self.scheduleRootFolderMetricsRefresh(container: container)
                }
            } catch {
                await MainActor.run {
                    self.isRestoring = false
                    self.restoreError = error.localizedDescription
                    self.restoreStatus = ""
                }
            }
        }
    }

    // MARK: - Background Enrichment Pipeline
    
    func runEnrichmentPipeline(container: ModelContainer, rootURL: URL?, source: EnrichmentTriggerSource) async {
        if isScanning {
            print("⏭️ Skipping enrichment pipeline while iCloud scan is running")
            return
        }
        if isScanningPhotos {
            print("⏭️ Skipping enrichment pipeline while photo scan is running")
            return
        }
        if isEnrichmentRunning {
            print("⏭️ Enrichment pipeline already running")
            return
        }
        let trigger = source.rawValue
        let stackPreview = Thread.callStackSymbols.prefix(8).joined(separator: "\n")
        print("🔄 Starting background enrichment pipeline (trigger=\(trigger))")
        print("🔎 Enrichment trigger call stack preview:\n\(stackPreview)")
        await MainActor.run {
            self.lastEnrichmentTrigger = trigger
        }

        // Phase 1: Build search index
        await MainActor.run {
            self.enrichmentPhase = .buildingSearchIndex
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = "Building search index..."
        }
        let indexContext = ModelContext(container)
        await SearchIndexService.shared.buildIndex(modelContext: indexContext)
        print("✅ Search index built")
        
        // Phase 2: Extract full metadata
        await MainActor.run {
            self.enrichmentPhase = .extractingMetadata
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = "Extracting photo metadata..."
        }
        let accessing = rootURL?.startAccessingSecurityScopedResource() ?? false
        let enrichService = IndexingService(modelContainer: container)
        let enrichError = await enrichService.enrichMetadata(rootURL: rootURL) { progress in
            Task { @MainActor in
                self.enrichmentProgress = progress
                self.enrichmentDetail = "Extracting metadata... \(Int(progress * 100))%"
            }
        }
        if accessing { rootURL?.stopAccessingSecurityScopedResource() }
        if let error = enrichError {
            print("⚠️ Metadata enrichment error: \(error)")
        } else {
            print("✅ Metadata enrichment complete")
        }
        
        // Rebuild search index after metadata enrichment (now has camera, keywords, etc.)
        await MainActor.run {
            self.enrichmentPhase = .buildingSearchIndex
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = "Updating search index with metadata..."
        }
        let reindexContext = ModelContext(container)
        await SearchIndexService.shared.buildIndex(modelContext: reindexContext)
        print("✅ Search index rebuilt with metadata")

        // Phase 3: Content hash backfill for exact duplicate detection
        await MainActor.run {
            self.enrichmentPhase = .hashing
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = "Computing content hashes..."
        }
        let hashError = await enrichService.backfillContentHashes(rootURL: rootURL) { progress in
            Task { @MainActor in
                self.enrichmentProgress = progress
                self.enrichmentDetail = "Computing content hashes... \(Int(progress * 100))%"
            }
        }
        if let error = hashError {
            print("⚠️ Content hash backfill error: \(error)")
        } else {
            print("✅ Content hash backfill complete")
        }
        
        // Phase 4: Geocoding
        await MainActor.run {
            self.enrichmentPhase = .geocoding
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = "Geocoding photo locations..."
        }
        await backfillPhotoLocations(container: container)
        let geocodeService = GeocodingService(modelContainer: container)
        let geocodeError = await geocodeService.geocodePhotos { progress, status in
            Task { @MainActor in
                self.enrichmentProgress = progress
                self.enrichmentDetail = status
            }
        }
        if let error = geocodeError {
            print("⚠️ Geocoding error: \(error)")
        } else {
            print("✅ Geocoding complete")
        }
        
        // Final search index rebuild (now has city/country from geocoding)
        await MainActor.run {
            self.enrichmentPhase = .buildingSearchIndex
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = "Finalizing search index..."
        }
        let finalContext = ModelContext(container)
        await SearchIndexService.shared.buildIndex(modelContext: finalContext)
        
        await MainActor.run {
            self.enrichmentPhase = .idle
            self.enrichmentProgress = 0.0
            self.enrichmentDetail = ""
            self.scheduleRootFolderMetricsRefresh(container: container)
        }
        print("🎉 Background enrichment pipeline complete")
    }

    func rootMetricsSummary(for source: FolderSource) -> String? {
        guard let metrics = rootFolderMetrics[source], metrics.totalPhotosRecursive > 0 else {
            return nil
        }

        let ratio = Double(metrics.duplicatePhotosRecursive) / Double(max(metrics.totalPhotosRecursive, 1))
        let percent = Int((ratio * 100).rounded())

        return "\(metrics.totalPhotosRecursive.formatted(.number)) photos • \(metrics.duplicatePhotosRecursive.formatted(.number)) dupes (\(percent)%) • \(metrics.uniquePhotosRecursive.formatted(.number)) unique • \(metrics.ungeotaggedPhotosRecursive.formatted(.number)) ungeotagged"
    }

    func scheduleRootFolderMetricsRefresh(container: ModelContainer) {
        rootMetricsRefreshTask?.cancel()
        rootMetricsRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshRootFolderMetrics(container: container)
        }
    }

    private func refreshRootFolderMetrics(container: ModelContainer) async {
        let context = ModelContext(container)

        do {
            let folders = try context.fetch(FetchDescriptor<Folder>())
            let photos = try context.fetch(FetchDescriptor<Photo>())

            let roots = folders.filter { $0.parentFolder == nil }
            let pathToPhoto: [String: Photo] = Dictionary(uniqueKeysWithValues: photos.map { ($0.filePath, $0) })

            let signatureCounts = buildGlobalSignatureCounts(from: photos)

            var computed: [FolderSource: RootFolderMetrics] = [:]
            let targetSources: [FolderSource] = [.iCloudDrive, .localPhotos, .virtual]

            for source in targetSources {
                let sourceRoots = roots.filter { $0.source == source }
                var rootPhotoPaths: Set<String> = []
                for root in sourceRoots {
                    collectPhotoPathsRecursive(folder: root, into: &rootPhotoPaths)
                }

                let total = rootPhotoPaths.count
                let duplicateCount = rootPhotoPaths.reduce(into: 0) { count, path in
                    guard let photo = pathToPhoto[path] else { return }
                    let signature = duplicateSignature(for: photo)
                    if (signatureCounts[signature] ?? 0) > 1 {
                        count += 1
                    }
                }
                let unique = max(0, total - duplicateCount)
                let ungeotagged = rootPhotoPaths.reduce(into: 0) { count, path in
                    guard let photo = pathToPhoto[path] else { return }
                    if photo.latitude == nil || photo.longitude == nil {
                        count += 1
                    }
                }

                computed[source] = RootFolderMetrics(
                    totalPhotosRecursive: total,
                    duplicatePhotosRecursive: duplicateCount,
                    uniquePhotosRecursive: unique,
                    ungeotaggedPhotosRecursive: ungeotagged,
                    updatedAt: Date()
                )
            }

            let computedSnapshot = computed
            await MainActor.run {
                self.rootFolderMetrics = computedSnapshot
                RootFolderMetricsStore.save(computedSnapshot)
            }
        } catch {
            print("Root folder metrics refresh failed: \(error)")
        }
    }

    private func collectPhotoPathsRecursive(folder: Folder, into paths: inout Set<String>) {
        for photo in folder.photos {
            paths.insert(photo.filePath)
        }
        for child in folder.childFolders {
            collectPhotoPathsRecursive(folder: child, into: &paths)
        }
    }

    private func buildGlobalSignatureCounts(from photos: [Photo]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for photo in photos {
            let signature = duplicateSignature(for: photo)
            counts[signature, default: 0] += 1
        }
        return counts
    }

    private func duplicateSignature(for photo: Photo) -> String {
        if let contentHash = photo.contentHash, !contentHash.isEmpty {
            return "hash:\(contentHash)"
        }

        let captureEpoch = Int(photo.captureDate?.timeIntervalSince1970 ?? 0)
        let width = photo.width ?? 0
        let height = photo.height ?? 0
        return "fallback:\(photo.fileSize)|\(width)x\(height)|\(captureEpoch)"
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
