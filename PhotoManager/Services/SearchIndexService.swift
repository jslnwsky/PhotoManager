import Foundation
import SwiftData

/// Lightweight search index for fast photo searching without loading full Photo objects
@MainActor
class SearchIndexService: ObservableObject {
    static let shared = SearchIndexService()
    
    @Published private(set) var isIndexing = false
    @Published private(set) var indexProgress: Double = 0.0
    
    private var searchIndex: [PhotoSearchRecord] = []
    private var lastIndexUpdate: Date?
    
    private init() {} // Singleton
    
    struct PhotoSearchRecord: Identifiable {
        let id: PersistentIdentifier
        let fileName: String
        let description: String?
        let keywords: [String]
        let cameraMake: String?
        let cameraModel: String?
        let lensModel: String?
        let city: String?
        let country: String?
        let captureDate: Date?
        let filePath: String
        let tagNames: [String]
        
        // Pre-computed lowercase versions for fast searching
        let fileNameLower: String
        let descriptionLower: String?
        let cameraMakeLower: String?
        let cameraModelLower: String?
        let lensModelLower: String?
        let cityLower: String?
        let countryLower: String?
        let keywordsLower: [String]
        let tagNamesLower: [String]
        
        init(id: PersistentIdentifier, fileName: String, description: String?, keywords: [String],
             cameraMake: String?, cameraModel: String?, lensModel: String?,
             city: String?, country: String?, captureDate: Date?, filePath: String, tagNames: [String]) {
            self.id = id
            self.fileName = fileName
            self.description = description
            self.keywords = keywords
            self.cameraMake = cameraMake
            self.cameraModel = cameraModel
            self.lensModel = lensModel
            self.city = city
            self.country = country
            self.captureDate = captureDate
            self.filePath = filePath
            self.tagNames = tagNames
            
            // Pre-compute lowercase versions
            self.fileNameLower = fileName.lowercased()
            self.descriptionLower = description?.lowercased()
            self.cameraMakeLower = cameraMake?.lowercased()
            self.cameraModelLower = cameraModel?.lowercased()
            self.lensModelLower = lensModel?.lowercased()
            self.cityLower = city?.lowercased()
            self.countryLower = country?.lowercased()
            self.keywordsLower = keywords.map { $0.lowercased() }
            self.tagNamesLower = tagNames.map { $0.lowercased() }
        }
    }
    
    /// Build search index from all photos - call once on app start
    func buildIndex(modelContext: ModelContext) async {
        isIndexing = true
        indexProgress = 0.0
        
        let startTime = Date()
        print("🔍 Building search index...")
        
        do {
            // First, get total count
            let countDescriptor = FetchDescriptor<Photo>()
            let totalCount = try modelContext.fetchCount(countDescriptor)
            print("🔍 Total photos to index: \(totalCount)")
            
            var allRecords: [PhotoSearchRecord] = []
            allRecords.reserveCapacity(totalCount)
            
            let batchSize = 1000
            var processedCount = 0
            var lastFilePath: String? = nil
            
            // Process in batches using cursor-based pagination (much faster than offset)
            var shouldContinue = true
            while shouldContinue {
                autoreleasepool {
                    var descriptor: FetchDescriptor<Photo>
                    
                    if let lastPath = lastFilePath {
                        // Cursor-based: fetch photos with filePath > lastPath
                        descriptor = FetchDescriptor<Photo>(
                            predicate: #Predicate<Photo> { photo in
                                photo.filePath > lastPath
                            },
                            sortBy: [SortDescriptor(\Photo.filePath)]
                        )
                    } else {
                        // First batch: no filter
                        descriptor = FetchDescriptor<Photo>(
                            sortBy: [SortDescriptor(\Photo.filePath)]
                        )
                    }
                    
                    descriptor.fetchLimit = batchSize
                    descriptor.relationshipKeyPathsForPrefetching = [\.photoTags]
                    
                    do {
                        let batch = try modelContext.fetch(descriptor)
                        
                        if batch.isEmpty {
                            shouldContinue = false
                        } else {
                            for photo in batch {
                                let tagNames = photo.tags.map { $0.name }
                                
                                let record = PhotoSearchRecord(
                                    id: photo.persistentModelID,
                                    fileName: photo.fileName,
                                    description: photo.photoDescription,
                                    keywords: photo.keywords,
                                    cameraMake: photo.cameraMake,
                                    cameraModel: photo.cameraModel,
                                    lensModel: photo.lensModel,
                                    city: photo.city,
                                    country: photo.country,
                                    captureDate: photo.captureDate,
                                    filePath: photo.filePath,
                                    tagNames: tagNames
                                )
                                allRecords.append(record)
                            }
                            
                            processedCount += batch.count
                            lastFilePath = batch.last?.filePath
                            indexProgress = Double(processedCount) / Double(totalCount)
                            
                            print("🔍 Processed \(processedCount)/\(totalCount) photos (\(Int(indexProgress * 100))%)")
                        }
                    } catch {
                        print("❌ Error fetching batch: \(error)")
                        shouldContinue = false
                    }
                }
            }
            
            searchIndex = allRecords
            lastIndexUpdate = Date()
            indexProgress = 1.0
            
            print("🔍 Built index with \(allRecords.count) records in \(Date().timeIntervalSince(startTime))s")
        } catch {
            print("❌ Failed to build search index: \(error)")
        }
        
        isIndexing = false
    }
    
    /// Search the index and return matching photo IDs
    func search(
        query: String,
        locationQuery: String,
        cameraQuery: String,
        dateRange: DateRange,
        source: SearchFilters.SourceFilter,
        selectedTagNames: Set<String>,
        maxResults: Int = 200
    ) -> (ids: [PersistentIdentifier], totalCount: Int) {
        let startTime = Date()
        
        let queryLower = query.lowercased()
        let locationLower = locationQuery.lowercased()
        let cameraLower = cameraQuery.lowercased()
        
        var matchingIDs: [PersistentIdentifier] = []
        var totalCount = 0
        
        for record in searchIndex {
            // Keyword search
            if !query.isEmpty {
                let textMatch = record.fileNameLower.contains(queryLower)
                    || record.descriptionLower?.contains(queryLower) == true
                    || record.keywordsLower.contains(where: { $0.contains(queryLower) })
                    || record.cameraMakeLower?.contains(queryLower) == true
                    || record.cameraModelLower?.contains(queryLower) == true
                    || record.cityLower?.contains(queryLower) == true
                    || record.countryLower?.contains(queryLower) == true
                    || record.tagNamesLower.contains(where: { $0.contains(queryLower) })
                if !textMatch { continue }
            }
            
            // Date range filter
            if dateRange != .all {
                guard let date = record.captureDate, dateRange.contains(date) else { continue }
            }
            
            // Location filter
            if !locationQuery.isEmpty {
                let locationMatch = record.cityLower?.contains(locationLower) == true
                    || record.countryLower?.contains(locationLower) == true
                if !locationMatch { continue }
            }
            
            // Camera filter
            if !cameraQuery.isEmpty {
                let cameraMatch = record.cameraMakeLower?.contains(cameraLower) == true
                    || record.cameraModelLower?.contains(cameraLower) == true
                    || record.lensModelLower?.contains(cameraLower) == true
                if !cameraMatch { continue }
            }
            
            // Source filter
            if source != .all {
                let isPhotosLibrary = record.filePath.contains("photos://")
                if source == .photosLibrary && !isPhotosLibrary { continue }
                if source == .iCloudDrive && isPhotosLibrary { continue }
            }
            
            // Tag filter
            if !selectedTagNames.isEmpty {
                let hasMatchingTag = record.tagNames.contains(where: { selectedTagNames.contains($0) })
                if !hasMatchingTag { continue }
            }
            
            // Match found
            totalCount += 1
            if matchingIDs.count < maxResults {
                matchingIDs.append(record.id)
            }
        }
        
        print("🔍 Index search found \(totalCount) matches in \(Date().timeIntervalSince(startTime))s")
        
        return (matchingIDs, totalCount)
    }
    
    /// Set the search index from external source (e.g., IndexingService during scan)
    func setIndex(_ records: [PhotoSearchRecord]) {
        searchIndex = records
        lastIndexUpdate = Date()
        print("🔍 Search index set with \(records.count) records")
    }
    
    /// Check if index needs rebuilding
    func needsRebuild(photoCount: Int) -> Bool {
        guard let lastUpdate = lastIndexUpdate else { return true }
        
        // Rebuild if index is empty or photo count changed significantly
        if searchIndex.isEmpty || abs(searchIndex.count - photoCount) > 100 {
            return true
        }
        
        // Rebuild if index is older than 1 hour
        return Date().timeIntervalSince(lastUpdate) > 3600
    }
    
    /// Check if index is ready
    var isIndexReady: Bool {
        !searchIndex.isEmpty
    }
}
