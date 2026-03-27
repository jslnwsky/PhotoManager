import Foundation
import SwiftData

// MARK: - Smart Folder Rule Structures

struct SmartFolderRule: Codable {
    var query: String = ""
    var locationQuery: String = ""
    var cameraQuery: String = ""
    var dateRange: SmartFolderDateRange = .all
    var sourceFilter: SourceFilter = .all
    var selectedTagNames: Set<String> = []
}

enum SmartFolderDateRange: Codable, CaseIterable {
    case all
    case today
    case thisWeek
    case thisMonth
    case thisYear
    
    var displayName: String {
        switch self {
        case .all: return "All Dates"
        case .today: return "Today"
        case .thisWeek: return "This Week"
        case .thisMonth: return "This Month"
        case .thisYear: return "This Year"
        }
    }
    
    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDate(date, inSameDayAs: now)
        case .thisWeek:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .thisMonth:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .thisYear:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
        }
    }
}

enum SourceFilter: Codable, CaseIterable {
    case all
    case iCloudDrive
    case iCloudPhotos
    case localPhotos
    
    var displayName: String {
        switch self {
        case .all: return "All Sources"
        case .iCloudDrive: return "iCloud Drive"
        case .iCloudPhotos: return "Photos Library"
        case .localPhotos: return "Local Photos"
        }
    }
}

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
    var rulePayload: String? // JSON string for virtual folder rules
    
    @Relationship(deleteRule: .cascade, inverse: \Folder.parentFolder)
    var childFolders: [Folder]
    
    @Relationship(deleteRule: .nullify, inverse: \Photo.folders)
    var photos: [Photo]
    
    init(name: String, path: String, sourceType: FolderSource, parentFolder: Folder? = nil, rulePayload: String? = nil) {
        self.name = name
        self.path = path
        self.sourceType = sourceType.rawValue
        self.createdDate = Date()
        self.parentFolder = parentFolder
        self.rulePayload = rulePayload
        self.childFolders = []
        self.photos = []
    }
    
    // Backward compatibility initializer
    convenience init(name: String, path: String, sourceType: FolderSource, parentFolder: Folder? = nil) {
        self.init(name: name, path: path, sourceType: sourceType, parentFolder: parentFolder, rulePayload: nil)
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
        // For smart folders, calculate based on rule evaluation
        if isVirtual, smartRule != nil {
            // Use a simple count approach to avoid main actor issues
            // This is a fallback - the count will be updated dynamically
            return 0
        }
        
        // For regular folders, count actual photos and child folder photos
        var count = photos.count
        
        for child in childFolders {
            count += child.photoCount
        }
        
        return count
    }
    
    // MARK: - Smart Folder Methods
    
    var isVirtual: Bool {
        return source == .virtual
    }
    
    var smartRule: SmartFolderRule? {
        guard let rulePayload = rulePayload,
              let data = rulePayload.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(SmartFolderRule.self, from: data)
    }
    
    func setSmartRule(_ rule: SmartFolderRule) {
        do {
            let data = try JSONEncoder().encode(rule)
            rulePayload = String(data: data, encoding: .utf8)
        } catch {
            print("Failed to encode smart folder rule: \(error)")
            rulePayload = nil
        }
    }
    
    func clearSmartRule() {
        rulePayload = nil
    }
}
