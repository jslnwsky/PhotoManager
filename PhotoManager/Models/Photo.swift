import Foundation
import SwiftData
import CoreLocation

@Model
final class Photo {
    var filePath: String
    var fileName: String
    var fileSize: Int64
    var captureDate: Date?
    var modificationDate: Date?
    var latitude: Double?
    var longitude: Double?
    var altitude: Double?
    var width: Int?
    var height: Int?
    var orientation: Int?
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var focalLength: Double?
    var aperture: Double?
    var shutterSpeed: Double?
    var iso: Int?
    var flash: Bool?
    var photoDescription: String?
    var keywords: [String]
    var originalMetadataJSON: String?
    var thumbnailData: Data?
    var hasFullMetadata: Bool
    var city: String?
    var country: String?
    var folders: [Folder]
    
    @Relationship(deleteRule: .cascade, inverse: \PhotoTag.photo)
    var photoTags: [PhotoTag]?
    
    init(
        filePath: String,
        fileName: String,
        fileSize: Int64,
        captureDate: Date? = nil,
        modificationDate: Date? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        altitude: Double? = nil,
        width: Int? = nil,
        height: Int? = nil,
        orientation: Int? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lensModel: String? = nil,
        focalLength: Double? = nil,
        aperture: Double? = nil,
        shutterSpeed: Double? = nil,
        iso: Int? = nil,
        flash: Bool? = nil,
        photoDescription: String? = nil,
        keywords: [String] = [],
        originalMetadataJSON: String? = nil,
        thumbnailData: Data? = nil,
        hasFullMetadata: Bool = false,
        city: String? = nil,
        country: String? = nil,
        folder: Folder? = nil
    ) {
        self.filePath = filePath
        self.fileName = fileName
        self.fileSize = fileSize
        self.captureDate = captureDate
        self.modificationDate = modificationDate
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.width = width
        self.height = height
        self.orientation = orientation
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lensModel = lensModel
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
        self.iso = iso
        self.flash = flash
        self.photoDescription = photoDescription
        self.keywords = keywords
        self.originalMetadataJSON = originalMetadataJSON
        self.thumbnailData = thumbnailData
        self.hasFullMetadata = hasFullMetadata
        self.city = city
        self.country = country
        self.folders = folder.map { [$0] } ?? []
    }
    
    var fileURL: URL? {
        guard !filePath.hasPrefix("photos://") else { return nil }
        return URL(fileURLWithPath: filePath)
    }
    
    var location: CLLocation? {
        guard let latitude = latitude, let longitude = longitude else {
            return nil
        }
        return CLLocation(latitude: latitude, longitude: longitude)
    }
    
    var primaryFolder: Folder? {
        folders.first
    }

    var tags: [Tag] {
        photoTags?.compactMap { $0.tag } ?? []
    }
}
