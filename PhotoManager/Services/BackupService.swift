import Foundation
import SwiftData
import BackgroundTasks

struct BackupAutomationSettingsStore {
    enum Keys {
        static let destinationBookmark = "backupDestinationBookmark"
        static let automationEnabled = "backupAutomationEnabled"
        static let preferredHour = "backupPreferredHour"
        static let backupFrequency = "backupFrequency"
        static let lastBackupAt = "lastBackupAt"
        static let lastFullBackupAt = "lastFullBackupAt"
        static let incrementalBackupsSinceFull = "incrementalBackupsSinceFull"
    }

    enum BackupFrequency: String, CaseIterable {
        case manualOnly
        case daily
        case weekly

        var displayName: String {
            switch self {
            case .manualOnly:
                return "Manual Only"
            case .daily:
                return "Daily"
            case .weekly:
                return "Weekly"
            }
        }
    }

    static var automationEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.automationEnabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.automationEnabled) }
    }

    static var preferredHour: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: Keys.preferredHour)
            return (0..<24).contains(value) ? value : 2
        }
        set {
            let clamped = min(max(newValue, 0), 23)
            UserDefaults.standard.set(clamped, forKey: Keys.preferredHour)
        }
    }

    static var backupFrequency: BackupFrequency {
        get {
            let raw = UserDefaults.standard.string(forKey: Keys.backupFrequency) ?? BackupFrequency.manualOnly.rawValue
            return BackupFrequency(rawValue: raw) ?? .manualOnly
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Keys.backupFrequency) }
    }

    static var destinationBookmarkData: Data? {
        get { UserDefaults.standard.data(forKey: Keys.destinationBookmark) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Keys.destinationBookmark)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.destinationBookmark)
            }
        }
    }

    static var lastBackupAt: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastBackupAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastBackupAt) }
    }

    static var lastFullBackupAt: Date? {
        get { UserDefaults.standard.object(forKey: Keys.lastFullBackupAt) as? Date }
        set { UserDefaults.standard.set(newValue, forKey: Keys.lastFullBackupAt) }
    }

    static var incrementalBackupsSinceFull: Int {
        get { max(0, UserDefaults.standard.integer(forKey: Keys.incrementalBackupsSinceFull)) }
        set { UserDefaults.standard.set(max(0, newValue), forKey: Keys.incrementalBackupsSinceFull) }
    }

    static func resolveDestinationURL() -> URL? {
        guard let data = destinationBookmarkData else { return nil }
        var isStale = false
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        if isStale {
            destinationBookmarkData = nil
            return nil
        }
        return url
    }
}

enum BackupAutomationCoordinator {
    static let taskIdentifier = "com.75-c.photomanager.backup.processing"
    private static var modelContainerProvider: (() -> ModelContainer)?

    static func configure(modelContainerProvider: @escaping () -> ModelContainer) {
        self.modelContainerProvider = modelContainerProvider
    }

    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let processingTask = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handleProcessingTask(processingTask)
        }
    }

    static func scheduleNextIfNeeded(now: Date = Date()) {
        guard BackupAutomationSettingsStore.automationEnabled else { return }
        guard BackupAutomationSettingsStore.backupFrequency != .manualOnly else { return }

        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)

        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresExternalPower = true
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = nextPreferredDate(from: now)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("⚠️ Failed to schedule automated backup task: \(error)")
        }
    }

    static func cancelScheduled() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
    }

    static func runIfDueInForeground(modelContainer: ModelContainer, now: Date = Date()) async {
        guard shouldRunBackup(now: now) else { return }
        guard let destinationURL = BackupAutomationSettingsStore.resolveDestinationURL() else { return }

        let accessing = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { destinationURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let service = BackupService(modelContainer: modelContainer)
            _ = try service.createBackupUsingLocalStaging(in: destinationURL)
            BackupAutomationSettingsStore.lastBackupAt = now
            BackupAutomationSettingsStore.lastFullBackupAt = now
            BackupAutomationSettingsStore.incrementalBackupsSinceFull = 0
        } catch {
            print("⚠️ Automated foreground backup failed: \(error)")
        }
    }

    private static func handleProcessingTask(_ task: BGProcessingTask) {
        scheduleNextIfNeeded()

        let work = Task {
            let success = await performScheduledBackup(now: Date())
            task.setTaskCompleted(success: success)
        }

        task.expirationHandler = {
            work.cancel()
        }
    }

    private static func performScheduledBackup(now: Date) async -> Bool {
        guard shouldRunBackup(now: now) else { return true }
        guard let modelContainerProvider else { return false }
        guard let destinationURL = BackupAutomationSettingsStore.resolveDestinationURL() else { return false }

        let accessing = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { destinationURL.stopAccessingSecurityScopedResource() }
        }

        do {
            let service = BackupService(modelContainer: modelContainerProvider())
            _ = try service.createBackupUsingLocalStaging(in: destinationURL)
            BackupAutomationSettingsStore.lastBackupAt = now
            BackupAutomationSettingsStore.lastFullBackupAt = now
            BackupAutomationSettingsStore.incrementalBackupsSinceFull = 0
            return true
        } catch {
            print("⚠️ Automated scheduled backup failed: \(error)")
            return false
        }
    }

    private static func shouldRunBackup(now: Date) -> Bool {
        guard BackupAutomationSettingsStore.automationEnabled else { return false }
        guard BackupAutomationSettingsStore.backupFrequency != .manualOnly else { return false }

        let calendar = Calendar.current
        let preferredHour = BackupAutomationSettingsStore.preferredHour
        let currentHour = calendar.component(.hour, from: now)
        guard currentHour >= preferredHour else { return false }

        guard let lastBackupAt = BackupAutomationSettingsStore.lastBackupAt else { return true }

        switch BackupAutomationSettingsStore.backupFrequency {
        case .manualOnly:
            return false
        case .daily:
            return !calendar.isDate(lastBackupAt, inSameDayAs: now)
        case .weekly:
            guard let days = calendar.dateComponents([.day], from: lastBackupAt, to: now).day else { return true }
            return days >= 7
        }
    }

    private static func nextPreferredDate(from now: Date) -> Date {
        let calendar = Calendar.current
        let preferredHour = BackupAutomationSettingsStore.preferredHour
        let todayAtPreferred = calendar.date(bySettingHour: preferredHour, minute: 0, second: 0, of: now) ?? now
        if now < todayAtPreferred {
            return todayAtPreferred
        }
        return calendar.date(byAdding: .day, value: 1, to: todayAtPreferred) ?? now.addingTimeInterval(86_400)
    }
}

final class BackupService {
    typealias BackupProgressHandler = (String) -> Void

    private let modelContainer: ModelContainer
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    enum BackupError: LocalizedError {
        case invalidBackup(String)
        case missingFile(String)
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .invalidBackup(let message):
                return "Invalid backup: \(message)"
            case .missingFile(let name):
                return "Missing required backup file: \(name)"
            case .unsupportedVersion(let version):
                return "Unsupported backup version: \(version)"
            }
        }
    }

    struct BackupManifest: Codable {
        let formatVersion: Int
        let createdAt: Date
        let appVersion: String
        let counts: BackupCounts
    }

    struct BackupCounts: Codable {
        let photos: Int
        let folders: Int
        let tags: Int
        let photoTags: Int
        let photoLocations: Int
        let photoThumbnails: Int
    }

    struct PhotoRecord: Codable {
        let filePath: String
        let fileName: String
        let fileSize: Int64
        let captureDate: Date?
        let modificationDate: Date?
        let latitude: Double?
        let longitude: Double?
        let altitude: Double?
        let width: Int?
        let height: Int?
        let orientation: Int?
        let cameraMake: String?
        let cameraModel: String?
        let lensModel: String?
        let focalLength: Double?
        let aperture: Double?
        let shutterSpeed: Double?
        let iso: Int?
        let flash: Bool?
        let photoDescription: String?
        let keywords: [String]
        let originalMetadataJSON: String?
        let hasFullMetadata: Bool
        let contentHash: String?
        let hashAlgorithm: String?
        let hashComputedAt: Date?
        let city: String?
        let country: String?
        let folderPaths: [String]
    }

    struct FolderRecord: Codable {
        let path: String
        let name: String
        let sourceType: String
        let createdDate: Date
        let parentPath: String?
    }

    struct TagRecord: Codable {
        let id: String
        let name: String
        let colorHex: String
        let createdDate: Date
        let parentID: String?
    }

    struct PhotoTagRecord: Codable {
        let photoFilePath: String
        let tagID: String
        let createdDate: Date
    }

    struct PhotoLocationRecord: Codable {
        let photoFilePath: String
        let latitude: Double
        let longitude: Double
        let captureDate: Date?
    }

    struct PhotoThumbnailRecord: Codable {
        let photoFilePath: String
        let fileName: String
    }

    struct AppStateRecord: Codable {
        let rootFolderBookmark: Data?
    }

    struct BackupPreview {
        let folderName: String
        let appVersion: String
        let createdAt: Date
        let counts: BackupCounts
    }

    func createBackup(in destinationFolderURL: URL, progressHandler: BackupProgressHandler? = nil) throws -> URL {
        progressHandler?("Reading database records...")
        let context = ModelContext(modelContainer)

        let photos = try context.fetch(FetchDescriptor<Photo>())
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let photoTags = try context.fetch(FetchDescriptor<PhotoTag>())
        let locations = try context.fetch(FetchDescriptor<PhotoLocation>())

        let backupFolderURL = try createBackupFolder(in: destinationFolderURL)
        let thumbnailsFolderURL = backupFolderURL.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnailsFolderURL, withIntermediateDirectories: true)
        progressHandler?("Writing backup files...")

        let folderRecords = folders
            .map { folder in
                FolderRecord(
                    path: folder.path,
                    name: folder.name,
                    sourceType: folder.sourceType,
                    createdDate: folder.createdDate,
                    parentPath: folder.parentFolder?.path
                )
            }
            .sorted { $0.path < $1.path }

        let tagIDsByObjectIdentifier = Dictionary(uniqueKeysWithValues: tags.enumerated().map { index, tag in
            (ObjectIdentifier(tag), "tag-\(index)")
        })

        let tagRecords = tags.enumerated().map { index, tag in
            TagRecord(
                id: "tag-\(index)",
                name: tag.name,
                colorHex: tag.colorHex,
                createdDate: tag.createdDate,
                parentID: tag.parentTag.flatMap { tagIDsByObjectIdentifier[ObjectIdentifier($0)] }
            )
        }

        let photoRecords = photos
            .map { photo in
                PhotoRecord(
                    filePath: photo.filePath,
                    fileName: photo.fileName,
                    fileSize: photo.fileSize,
                    captureDate: photo.captureDate,
                    modificationDate: photo.modificationDate,
                    latitude: photo.latitude,
                    longitude: photo.longitude,
                    altitude: photo.altitude,
                    width: photo.width,
                    height: photo.height,
                    orientation: photo.orientation,
                    cameraMake: photo.cameraMake,
                    cameraModel: photo.cameraModel,
                    lensModel: photo.lensModel,
                    focalLength: photo.focalLength,
                    aperture: photo.aperture,
                    shutterSpeed: photo.shutterSpeed,
                    iso: photo.iso,
                    flash: photo.flash,
                    photoDescription: photo.photoDescription,
                    keywords: photo.keywords,
                    originalMetadataJSON: photo.originalMetadataJSON,
                    hasFullMetadata: photo.hasFullMetadata,
                    contentHash: photo.contentHash,
                    hashAlgorithm: photo.hashAlgorithm,
                    hashComputedAt: photo.hashComputedAt,
                    city: photo.city,
                    country: photo.country,
                    folderPaths: photo.folders.map { $0.path }.sorted()
                )
            }
            .sorted { $0.filePath < $1.filePath }

        let photoTagRecords = photoTags.compactMap { photoTag -> PhotoTagRecord? in
            guard let photo = photoTag.photo,
                  let tag = photoTag.tag,
                  let tagID = tagIDsByObjectIdentifier[ObjectIdentifier(tag)] else {
                return nil
            }
            return PhotoTagRecord(photoFilePath: photo.filePath, tagID: tagID, createdDate: photoTag.createdDate)
        }

        let locationRecords = locations
            .map { location in
                PhotoLocationRecord(
                    photoFilePath: location.photoFilePath,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    captureDate: location.captureDate
                )
            }
            .sorted { $0.photoFilePath < $1.photoFilePath }

        let thumbnailRecords = try writeThumbnailsAndBuildRecords(
            in: thumbnailsFolderURL,
            context: context,
            progressHandler: progressHandler
        )

        let appStateRecord = AppStateRecord(
            rootFolderBookmark: UserDefaults.standard.data(forKey: "rootFolderBookmark")
        )

        let manifest = BackupManifest(
            formatVersion: 1,
            createdAt: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            counts: BackupCounts(
                photos: photoRecords.count,
                folders: folderRecords.count,
                tags: tagRecords.count,
                photoTags: photoTagRecords.count,
                photoLocations: locationRecords.count,
                photoThumbnails: thumbnailRecords.count
            )
        )

        progressHandler?("Writing JSON files...")
        try writeJSON(manifest, to: backupFolderURL.appendingPathComponent("manifest.json"))
        try writeJSON(photoRecords, to: backupFolderURL.appendingPathComponent("photos.json"))
        try writeJSON(folderRecords, to: backupFolderURL.appendingPathComponent("folders.json"))
        try writeJSON(tagRecords, to: backupFolderURL.appendingPathComponent("tags.json"))
        try writeJSON(photoTagRecords, to: backupFolderURL.appendingPathComponent("photo_tags.json"))
        try writeJSON(locationRecords, to: backupFolderURL.appendingPathComponent("photo_locations.json"))
        try writeJSON(thumbnailRecords, to: backupFolderURL.appendingPathComponent("photo_thumbnails.json"))
        try writeJSON(appStateRecord, to: backupFolderURL.appendingPathComponent("app_state.json"))
        progressHandler?("Backup files written")

        return backupFolderURL
    }

    func createBackupUsingLocalStaging(in destinationFolderURL: URL, progressHandler: BackupProgressHandler? = nil) throws -> URL {
        progressHandler?("Preparing local staging...")
        let stagingRootURL = try createBackupStagingRoot()
        defer {
            try? FileManager.default.removeItem(at: stagingRootURL)
        }

        let localBackupURL = try createBackup(
            in: stagingRootURL,
            progressHandler: { status in
                progressHandler?("Local build: \(status)")
            }
        )

        let destinationBackupURL = destinationFolderURL.appendingPathComponent(localBackupURL.lastPathComponent, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationBackupURL.path) {
            try FileManager.default.removeItem(at: destinationBackupURL)
        }

        progressHandler?("Copying backup to destination...")
        do {
            try copyBackupFolder(from: localBackupURL, to: destinationBackupURL, progressHandler: progressHandler)
            progressHandler?("Backup copy complete")
        } catch {
            progressHandler?("Copy failed: \(error.localizedDescription)")
            throw error
        }

        return destinationBackupURL
    }

    private func copyBackupFolder(from sourceURL: URL, to destinationURL: URL, progressHandler: BackupProgressHandler?) throws {
        let fileManager = FileManager.default
        
        // Create destination root
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        // Get contents of source
        let contents = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
        let total = contents.count
        var copied = 0
        
        for item in contents {
            let itemName = item.lastPathComponent
            let destItem = destinationURL.appendingPathComponent(itemName)
            
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory)
            
            if isDirectory.boolValue {
                // Recursively copy subdirectories (like thumbnails)
                try copyDirectoryRecursive(from: item, to: destItem, progressHandler: { msg in
                    progressHandler?("Copying \(itemName): \(msg)")
                })
            } else {
                // Copy file directly
                try fileManager.copyItem(at: item, to: destItem)
            }
            
            copied += 1
            if copied.isMultiple(of: 10) || copied == total {
                progressHandler?("Copied \(copied)/\(total) items")
            }
        }
    }
    
    private func copyDirectoryRecursive(from sourceURL: URL, to destinationURL: URL, progressHandler: BackupProgressHandler?) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        
        let contents = try fileManager.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)
        for item in contents {
            let itemName = item.lastPathComponent
            let destItem = destinationURL.appendingPathComponent(itemName)
            try fileManager.copyItem(at: item, to: destItem)
        }
        progressHandler?("\(contents.count) files")
    }

    func createSafetySnapshot() throws -> URL {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BackupError.invalidBackup("Unable to locate application support directory")
        }

        let snapshotsRootURL = appSupportURL.appendingPathComponent("RestoreSafetySnapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotsRootURL, withIntermediateDirectories: true)
        return try createBackup(in: snapshotsRootURL)
    }

    func deleteSnapshot(at snapshotURL: URL) throws {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return }
        try FileManager.default.removeItem(at: snapshotURL)
    }

    func loadBackupPreview(from backupFolderURL: URL) throws -> BackupPreview {
        let manifestURL = backupFolderURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BackupError.missingFile("manifest.json")
        }

        let manifest: BackupManifest = try readJSON(from: manifestURL)
        guard manifest.formatVersion == 1 else {
            throw BackupError.unsupportedVersion(manifest.formatVersion)
        }

        return BackupPreview(
            folderName: backupFolderURL.lastPathComponent,
            appVersion: manifest.appVersion,
            createdAt: manifest.createdAt,
            counts: manifest.counts
        )
    }

    func restoreBackup(from backupFolderURL: URL) throws {
        let manifestURL = backupFolderURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BackupError.missingFile("manifest.json")
        }

        let manifest: BackupManifest = try readJSON(from: manifestURL)
        guard manifest.formatVersion == 1 else {
            throw BackupError.unsupportedVersion(manifest.formatVersion)
        }

        let photoRecords: [PhotoRecord] = try readRequiredJSONFile("photos.json", in: backupFolderURL)
        let folderRecords: [FolderRecord] = try readRequiredJSONFile("folders.json", in: backupFolderURL)
        let tagRecords: [TagRecord] = try readRequiredJSONFile("tags.json", in: backupFolderURL)
        let photoTagRecords: [PhotoTagRecord] = try readRequiredJSONFile("photo_tags.json", in: backupFolderURL)
        let locationRecords: [PhotoLocationRecord] = try readRequiredJSONFile("photo_locations.json", in: backupFolderURL)
        let thumbnailRecords: [PhotoThumbnailRecord] = try readRequiredJSONFile("photo_thumbnails.json", in: backupFolderURL)
        let appStateRecord: AppStateRecord = try readRequiredJSONFile("app_state.json", in: backupFolderURL)

        try validateCounts(
            manifest: manifest,
            photoRecords: photoRecords,
            folderRecords: folderRecords,
            tagRecords: tagRecords,
            photoTagRecords: photoTagRecords,
            locationRecords: locationRecords,
            thumbnailRecords: thumbnailRecords
        )

        let context = ModelContext(modelContainer)
        try clearExistingData(in: context)

        var folderByPath: [String: Folder] = [:]
        folderByPath.reserveCapacity(folderRecords.count)
        for record in folderRecords {
            guard let source = FolderSource(rawValue: record.sourceType) else {
                throw BackupError.invalidBackup("Unknown folder source type: \(record.sourceType)")
            }
            let folder = Folder(name: record.name, path: record.path, sourceType: source)
            folder.createdDate = record.createdDate
            context.insert(folder)
            folderByPath[record.path] = folder
        }

        for record in folderRecords {
            guard let parentPath = record.parentPath else { continue }
            guard let folder = folderByPath[record.path], let parent = folderByPath[parentPath] else {
                throw BackupError.invalidBackup("Folder parent relationship not resolvable for \(record.path)")
            }
            folder.parentFolder = parent
        }

        var tagByID: [String: Tag] = [:]
        tagByID.reserveCapacity(tagRecords.count)
        for record in tagRecords {
            let tag = Tag(name: record.name, colorHex: record.colorHex)
            tag.createdDate = record.createdDate
            context.insert(tag)
            tagByID[record.id] = tag
        }

        for record in tagRecords {
            guard let parentID = record.parentID else { continue }
            guard let tag = tagByID[record.id], let parent = tagByID[parentID] else {
                throw BackupError.invalidBackup("Tag parent relationship not resolvable for \(record.id)")
            }
            tag.parentTag = parent
        }

        var photoByPath: [String: Photo] = [:]
        photoByPath.reserveCapacity(photoRecords.count)
        for record in photoRecords {
            let photo = Photo(
                filePath: record.filePath,
                fileName: record.fileName,
                fileSize: record.fileSize,
                captureDate: record.captureDate,
                modificationDate: record.modificationDate,
                latitude: record.latitude,
                longitude: record.longitude,
                altitude: record.altitude,
                width: record.width,
                height: record.height,
                orientation: record.orientation,
                cameraMake: record.cameraMake,
                cameraModel: record.cameraModel,
                lensModel: record.lensModel,
                focalLength: record.focalLength,
                aperture: record.aperture,
                shutterSpeed: record.shutterSpeed,
                iso: record.iso,
                flash: record.flash,
                photoDescription: record.photoDescription,
                keywords: record.keywords,
                originalMetadataJSON: record.originalMetadataJSON,
                hasFullMetadata: record.hasFullMetadata,
                contentHash: record.contentHash,
                hashAlgorithm: record.hashAlgorithm,
                hashComputedAt: record.hashComputedAt,
                city: record.city,
                country: record.country,
                folder: nil
            )
            photo.folders = record.folderPaths.compactMap { folderByPath[$0] }
            context.insert(photo)
            photoByPath[record.filePath] = photo
        }

        for record in photoTagRecords {
            guard let photo = photoByPath[record.photoFilePath], let tag = tagByID[record.tagID] else {
                throw BackupError.invalidBackup("PhotoTag relationship not resolvable for photo=\(record.photoFilePath), tag=\(record.tagID)")
            }
            let photoTag = PhotoTag(photo: photo, tag: tag)
            photoTag.createdDate = record.createdDate
            context.insert(photoTag)
        }

        for record in locationRecords {
            let location = PhotoLocation(
                photoFilePath: record.photoFilePath,
                latitude: record.latitude,
                longitude: record.longitude,
                captureDate: record.captureDate
            )
            context.insert(location)
        }

        try context.save()

        let thumbnailChunkSize = 200
        var index = 0
        while index < thumbnailRecords.count {
            let endIndex = min(index + thumbnailChunkSize, thumbnailRecords.count)
            try autoreleasepool {
                let thumbnailContext = ModelContext(modelContainer)
                for record in thumbnailRecords[index..<endIndex] {
                    let fileURL = backupFolderURL
                        .appendingPathComponent("thumbnails", isDirectory: true)
                        .appendingPathComponent(record.fileName)
                    guard FileManager.default.fileExists(atPath: fileURL.path) else {
                        throw BackupError.missingFile("thumbnails/\(record.fileName)")
                    }
                    let imageData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                    let thumbnail = PhotoThumbnail(photoFilePath: record.photoFilePath, imageData: imageData)
                    thumbnailContext.insert(thumbnail)
                }
                try thumbnailContext.save()
            }
            index = endIndex
        }

        if let bookmarkData = appStateRecord.rootFolderBookmark {
            UserDefaults.standard.set(bookmarkData, forKey: "rootFolderBookmark")
        } else {
            UserDefaults.standard.removeObject(forKey: "rootFolderBookmark")
        }
    }

    private func clearExistingData(in context: ModelContext) throws {
        for model in try context.fetch(FetchDescriptor<PhotoTag>()) {
            context.delete(model)
        }
        for model in try context.fetch(FetchDescriptor<PhotoLocation>()) {
            context.delete(model)
        }
        for model in try context.fetch(FetchDescriptor<PhotoThumbnail>()) {
            context.delete(model)
        }
        for model in try context.fetch(FetchDescriptor<Photo>()) {
            context.delete(model)
        }
        for model in try context.fetch(FetchDescriptor<Tag>()) {
            context.delete(model)
        }
        for model in try context.fetch(FetchDescriptor<Folder>()) {
            context.delete(model)
        }
        try context.save()
    }

    private func createBackupFolder(in destinationFolderURL: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HH-mm"
        let timestamp = formatter.string(from: Date())
        let folderName = "\(timestamp)_PhotoMgrBackup"
        let backupFolderURL = destinationFolderURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolderURL, withIntermediateDirectories: true)
        return backupFolderURL
    }

    private func createBackupStagingRoot() throws -> URL {
        guard let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BackupError.invalidBackup("Unable to locate application support directory")
        }

        let stagingRootURL = appSupportURL
            .appendingPathComponent("BackupStaging", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRootURL, withIntermediateDirectories: true)
        return stagingRootURL
    }

    private func writeThumbnailsAndBuildRecords(
        in thumbnailsFolderURL: URL,
        context: ModelContext,
        progressHandler: BackupProgressHandler?
    ) throws -> [PhotoThumbnailRecord] {
        let fetchChunkSize = 200
        var fetchOffset = 0
        var fileIndex = 0
        var records: [PhotoThumbnailRecord] = []

        progressHandler?("Writing thumbnail files...")

        while true {
            var descriptor = FetchDescriptor<PhotoThumbnail>(
                sortBy: [SortDescriptor(\PhotoThumbnail.photoFilePath)]
            )
            descriptor.fetchOffset = fetchOffset
            descriptor.fetchLimit = fetchChunkSize

            let batch = try context.fetch(descriptor)
            if batch.isEmpty {
                break
            }

            try autoreleasepool {
                records.reserveCapacity(records.count + batch.count)
                for thumbnail in batch {
                    let fileName = "thumb_\(fileIndex).bin"
                    let fileURL = thumbnailsFolderURL.appendingPathComponent(fileName)
                    try thumbnail.imageData.write(to: fileURL, options: .atomic)
                    records.append(PhotoThumbnailRecord(photoFilePath: thumbnail.photoFilePath, fileName: fileName))
                    fileIndex += 1
                    if fileIndex.isMultiple(of: 500) {
                        progressHandler?("Writing thumbnail files... \(fileIndex) written")
                    }
                }
            }

            fetchOffset += batch.count
        }

        progressHandler?("Thumbnail files complete: \(fileIndex)")

        return records
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: .atomic)
    }

    private func readJSON<T: Decodable>(from url: URL) throws -> T {
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    private func readRequiredJSONFile<T: Decodable>(_ name: String, in backupFolderURL: URL) throws -> T {
        let url = backupFolderURL.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.missingFile(name)
        }
        return try readJSON(from: url)
    }

    private func validateCounts(
        manifest: BackupManifest,
        photoRecords: [PhotoRecord],
        folderRecords: [FolderRecord],
        tagRecords: [TagRecord],
        photoTagRecords: [PhotoTagRecord],
        locationRecords: [PhotoLocationRecord],
        thumbnailRecords: [PhotoThumbnailRecord]
    ) throws {
        guard manifest.counts.photos == photoRecords.count else {
            throw BackupError.invalidBackup("Photo count mismatch")
        }
        guard manifest.counts.folders == folderRecords.count else {
            throw BackupError.invalidBackup("Folder count mismatch")
        }
        guard manifest.counts.tags == tagRecords.count else {
            throw BackupError.invalidBackup("Tag count mismatch")
        }
        guard manifest.counts.photoTags == photoTagRecords.count else {
            throw BackupError.invalidBackup("PhotoTag count mismatch")
        }
        guard manifest.counts.photoLocations == locationRecords.count else {
            throw BackupError.invalidBackup("PhotoLocation count mismatch")
        }
        guard manifest.counts.photoThumbnails == thumbnailRecords.count else {
            throw BackupError.invalidBackup("PhotoThumbnail count mismatch")
        }
    }
}
