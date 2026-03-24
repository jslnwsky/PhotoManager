import Foundation
import SwiftData

final class BackupService {
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

    func createBackup(in destinationFolderURL: URL) throws -> URL {
        let context = ModelContext(modelContainer)

        let photos = try context.fetch(FetchDescriptor<Photo>())
        let folders = try context.fetch(FetchDescriptor<Folder>())
        let tags = try context.fetch(FetchDescriptor<Tag>())
        let photoTags = try context.fetch(FetchDescriptor<PhotoTag>())
        let locations = try context.fetch(FetchDescriptor<PhotoLocation>())
        let thumbnails = try context.fetch(FetchDescriptor<PhotoThumbnail>())

        let backupFolderURL = try createBackupFolder(in: destinationFolderURL)
        let thumbnailsFolderURL = backupFolderURL.appendingPathComponent("thumbnails", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbnailsFolderURL, withIntermediateDirectories: true)

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

        var thumbnailRecords: [PhotoThumbnailRecord] = []
        thumbnailRecords.reserveCapacity(thumbnails.count)

        for (index, thumbnail) in thumbnails.enumerated() {
            let fileName = "thumb_\(index).bin"
            let fileURL = thumbnailsFolderURL.appendingPathComponent(fileName)
            try thumbnail.imageData.write(to: fileURL, options: .atomic)
            thumbnailRecords.append(PhotoThumbnailRecord(photoFilePath: thumbnail.photoFilePath, fileName: fileName))
        }

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

        try writeJSON(manifest, to: backupFolderURL.appendingPathComponent("manifest.json"))
        try writeJSON(photoRecords, to: backupFolderURL.appendingPathComponent("photos.json"))
        try writeJSON(folderRecords, to: backupFolderURL.appendingPathComponent("folders.json"))
        try writeJSON(tagRecords, to: backupFolderURL.appendingPathComponent("tags.json"))
        try writeJSON(photoTagRecords, to: backupFolderURL.appendingPathComponent("photo_tags.json"))
        try writeJSON(locationRecords, to: backupFolderURL.appendingPathComponent("photo_locations.json"))
        try writeJSON(thumbnailRecords, to: backupFolderURL.appendingPathComponent("photo_thumbnails.json"))
        try writeJSON(appStateRecord, to: backupFolderURL.appendingPathComponent("app_state.json"))

        return backupFolderURL
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

        var thumbnailDataByPhotoPath: [String: Data] = [:]
        thumbnailDataByPhotoPath.reserveCapacity(thumbnailRecords.count)
        for thumbnailRecord in thumbnailRecords {
            let fileURL = backupFolderURL
                .appendingPathComponent("thumbnails", isDirectory: true)
                .appendingPathComponent(thumbnailRecord.fileName)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw BackupError.missingFile("thumbnails/\(thumbnailRecord.fileName)")
            }
            thumbnailDataByPhotoPath[thumbnailRecord.photoFilePath] = try Data(contentsOf: fileURL)
        }

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
            let thumbnailContext = ModelContext(modelContainer)
            for record in thumbnailRecords[index..<endIndex] {
                guard let imageData = thumbnailDataByPhotoPath[record.photoFilePath] else {
                    throw BackupError.invalidBackup("Missing thumbnail data for \(record.photoFilePath)")
                }
                let thumbnail = PhotoThumbnail(photoFilePath: record.photoFilePath, imageData: imageData)
                thumbnailContext.insert(thumbnail)
            }
            try thumbnailContext.save()
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
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let folderName = "PhotoMgrBackup_\(timestamp)"
        let backupFolderURL = destinationFolderURL.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: backupFolderURL, withIntermediateDirectories: true)
        return backupFolderURL
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
