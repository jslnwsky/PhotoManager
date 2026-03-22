import Foundation
import SwiftData

enum FolderSource: String, Codable {
    case iCloudDrive
    case iCloudPhotos
    case localPhotos
    case virtual
}

@Model
final class Folder {
    var name: String
    var path: String
    var sourceType: String
    var createdDate: Date
    var parentFolder: Folder?
    
    @Relationship(deleteRule: .cascade, inverse: \Folder.parentFolder)
    var childFolders: [Folder]
    
    @Relationship(deleteRule: .nullify, inverse: \Photo.folders)
    var photos: [Photo]
    
    init(name: String, path: String, sourceType: FolderSource, parentFolder: Folder? = nil) {
        self.name = name
        self.path = path
        self.sourceType = sourceType.rawValue
        self.createdDate = Date()
        self.parentFolder = parentFolder
        self.childFolders = []
        self.photos = []
    }
    
    var source: FolderSource {
        FolderSource(rawValue: sourceType) ?? .virtual
    }
    
    var fullPath: String {
        var pathComponents = [name]
        var current = parentFolder
        
        while let parent = current {
            pathComponents.insert(parent.name, at: 0)
            current = parent.parentFolder
        }
        
        return pathComponents.joined(separator: "/")
    }
    
    var level: Int {
        var count = 0
        var current = parentFolder
        
        while current != nil {
            count += 1
            current = current?.parentFolder
        }
        
        return count
    }
    
    var photoCount: Int {
        var count = photos.count
        
        for child in childFolders {
            count += child.photoCount
        }
        
        return count
    }
}
