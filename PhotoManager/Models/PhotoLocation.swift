import Foundation
import SwiftData

@Model
final class PhotoLocation {
    @Attribute(.unique) var photoFilePath: String
    var latitude: Double
    var longitude: Double
    var captureDate: Date?
    
    init(photoFilePath: String, latitude: Double, longitude: Double, captureDate: Date? = nil) {
        self.photoFilePath = photoFilePath
        self.latitude = latitude
        self.longitude = longitude
        self.captureDate = captureDate
    }
}
