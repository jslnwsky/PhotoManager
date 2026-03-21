import Foundation
import SwiftData

@Model
final class PhotoTag {
    var photo: Photo?
    var tag: Tag?
    var createdDate: Date
    
    init(photo: Photo, tag: Tag) {
        self.photo = photo
        self.tag = tag
        self.createdDate = Date()
    }
}
