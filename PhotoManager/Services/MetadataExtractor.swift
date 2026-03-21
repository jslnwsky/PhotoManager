import Foundation
import UIKit
import ImageIO
import CoreLocation
import QuickLookThumbnailing

struct PhotoMetadata {
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
    var description: String?
    var keywords: [String]?
    var rawMetadata: [String: Any]
}

actor MetadataExtractor {
    private func isLocallyAvailable(_ url: URL) -> Bool {
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus {
            return status == .current
        }
        return true
    }

    func extractMetadata(from url: URL) async throws -> PhotoMetadata {
        guard isLocallyAvailable(url) else {
            throw MetadataError.cannotCreateImageSource
        }
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw MetadataError.cannotCreateImageSource
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw MetadataError.cannotReadProperties
        }
        
        var metadata = PhotoMetadata(rawMetadata: properties)
        
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int {
            metadata.width = width
        }
        
        if let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            metadata.height = height
        }
        
        if let orientation = properties[kCGImagePropertyOrientation as String] as? Int {
            metadata.orientation = orientation
        }
        
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            extractEXIFData(from: exif, into: &metadata)
        }
        
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            extractTIFFData(from: tiff, into: &metadata)
        }
        
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            extractGPSData(from: gps, into: &metadata)
        }
        
        if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            extractIPTCData(from: iptc, into: &metadata)
        }
        
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        if let modDate = fileAttributes[.modificationDate] as? Date {
            metadata.modificationDate = modDate
        }
        
        return metadata
    }
    
    func extractMetadataFromData(_ imageData: Data) async throws -> PhotoMetadata {
        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil) else {
            throw MetadataError.cannotCreateImageSource
        }
        
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any] else {
            throw MetadataError.cannotReadProperties
        }
        
        var metadata = PhotoMetadata(rawMetadata: properties)
        
        if let width = properties[kCGImagePropertyPixelWidth as String] as? Int {
            metadata.width = width
        }
        
        if let height = properties[kCGImagePropertyPixelHeight as String] as? Int {
            metadata.height = height
        }
        
        if let orientation = properties[kCGImagePropertyOrientation as String] as? Int {
            metadata.orientation = orientation
        }
        
        if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] {
            extractEXIFData(from: exif, into: &metadata)
        }
        
        if let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            extractTIFFData(from: tiff, into: &metadata)
        }
        
        if let gps = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any] {
            extractGPSData(from: gps, into: &metadata)
        }
        
        if let iptc = properties[kCGImagePropertyIPTCDictionary as String] as? [String: Any] {
            extractIPTCData(from: iptc, into: &metadata)
        }
        
        return metadata
    }
    
    private func extractEXIFData(from exif: [String: Any], into metadata: inout PhotoMetadata) {
        if let dateString = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String {
            metadata.captureDate = parseEXIFDate(dateString)
        }
        
        if let focalLength = exif[kCGImagePropertyExifFocalLength as String] as? Double {
            metadata.focalLength = focalLength
        }
        
        if let aperture = exif[kCGImagePropertyExifFNumber as String] as? Double {
            metadata.aperture = aperture
        }
        
        if let exposureTime = exif[kCGImagePropertyExifExposureTime as String] as? Double {
            metadata.shutterSpeed = exposureTime
        }
        
        if let iso = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Int],
           let isoValue = iso.first {
            metadata.iso = isoValue
        }
        
        if let flash = exif[kCGImagePropertyExifFlash as String] as? Int {
            metadata.flash = (flash & 0x1) != 0
        }
        
        if let lensModel = exif[kCGImagePropertyExifLensModel as String] as? String {
            metadata.lensModel = lensModel
        }
    }
    
    private func extractTIFFData(from tiff: [String: Any], into metadata: inout PhotoMetadata) {
        if let make = tiff[kCGImagePropertyTIFFMake as String] as? String {
            metadata.cameraMake = make.trimmingCharacters(in: .whitespaces)
        }
        
        if let model = tiff[kCGImagePropertyTIFFModel as String] as? String {
            metadata.cameraModel = model.trimmingCharacters(in: .whitespaces)
        }
        
        if let description = tiff[kCGImagePropertyTIFFImageDescription as String] as? String {
            metadata.description = description
        }
    }
    
    private func extractGPSData(from gps: [String: Any], into metadata: inout PhotoMetadata) {
        if let latitude = gps[kCGImagePropertyGPSLatitude as String] as? Double,
           let latitudeRef = gps[kCGImagePropertyGPSLatitudeRef as String] as? String {
            metadata.latitude = latitudeRef == "S" ? -latitude : latitude
        }
        
        if let longitude = gps[kCGImagePropertyGPSLongitude as String] as? Double,
           let longitudeRef = gps[kCGImagePropertyGPSLongitudeRef as String] as? String {
            metadata.longitude = longitudeRef == "W" ? -longitude : longitude
        }
        
        if let altitude = gps[kCGImagePropertyGPSAltitude as String] as? Double {
            metadata.altitude = altitude
        }
    }
    
    private func extractIPTCData(from iptc: [String: Any], into metadata: inout PhotoMetadata) {
        if let keywords = iptc[kCGImagePropertyIPTCKeywords as String] as? [String] {
            metadata.keywords = keywords
        }
        
        if let caption = iptc[kCGImagePropertyIPTCCaptionAbstract as String] as? String {
            if metadata.description == nil {
                metadata.description = caption
            }
        }
    }
    
    private func parseEXIFDate(_ dateString: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: dateString)
    }
    
    func generateThumbnail(from url: URL, maxSize: CGFloat = 200) async throws -> Data? {
        if isLocallyAvailable(url),
           let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
            ]
            if let thumbnail = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) {
                return opaqueJPEG(from: UIImage(cgImage: thumbnail))
            }
        }
        return await generateQLThumbnail(from: url, maxSize: maxSize)
    }

    func generateQLThumbnail(from url: URL, maxSize: CGFloat = 200) async -> Data? {
        let size = CGSize(width: maxSize, height: maxSize)
        let scale = await MainActor.run { UIScreen.main.scale }
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        return opaqueJPEG(from: rep.uiImage)
    }

    private func opaqueJPEG(from image: UIImage, quality: CGFloat = 0.7) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let opaque = renderer.image { _ in image.draw(at: .zero) }
        return opaque.jpegData(compressionQuality: quality)
    }
}

enum MetadataError: LocalizedError {
    case cannotCreateImageSource
    case cannotReadProperties
    
    var errorDescription: String? {
        switch self {
        case .cannotCreateImageSource:
            return "Cannot create image source from file"
        case .cannotReadProperties:
            return "Cannot read image properties"
        }
    }
}
