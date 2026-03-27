import Foundation
import SwiftData
import SwiftUI

/// Notification posted when search index is rebuilt
extension Notification.Name {
    static let searchIndexDidRebuild = Notification.Name("searchIndexDidRebuild")
}

/// Lightweight search index for fast photo searching without loading full Photo objects
@MainActor
final class SearchIndexService: ObservableObject {
    static let shared = SearchIndexService()
    
    @Published var searchIndex: [PhotoSearchRecord] = []
    @Published var isIndexing = false
    @Published var indexProgress: Double = 0.0
    @Published var lastIndexUpdate: Date?
    @Published var isRebuildingIndex = false
    @Published var rebuildProgress: Double = 0.0
    @Published var rebuildMessage: String = ""
    
    private var rebuildTask: Task<Void, Never>?
    
    private init() {
        // Don't auto-rebuild on initialization - let the UI handle it
        // This ensures proper progress feedback for users
    }
    
    /// Check if index needs rebuilding and do it if necessary
    private func checkAndRebuildIndexIfNeeded() async {
        // Small delay to allow app to initialize
        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        
        if searchIndex.isEmpty {
            print("🔍 Search index empty on startup, rebuilding from database...")
            // Don't auto-rebuild here - let the UI handle it with proper progress
            // This prevents background rebuild without user feedback
        } else {
            print("🔍 Search index found with \(searchIndex.count) records")
        }
    }
    
    /// Rebuild search index from database
    func rebuildIndexFromDatabase(modelContext: ModelContext? = nil) async {
        guard !isRebuildingIndex else { return }
        
        await MainActor.run {
            isRebuildingIndex = true
            rebuildProgress = 0.0
            rebuildMessage = "Building search index..."
        }
        
        let startTime = Date()
        
        if let context = modelContext {
            // Use provided model context
            await buildIndexWithProgress(modelContext: context)
        } else {
            // Try to get model context from app - this is a limitation
            // For now, we'll need the caller to provide the context
            print("🔍 No model context provided for rebuild")
            await MainActor.run {
                isRebuildingIndex = false
                rebuildMessage = "Model context required"
            }
            return
        }
        
        await MainActor.run {
            isRebuildingIndex = false
            rebuildProgress = 1.0
            rebuildMessage = "Search index ready"
            
            let duration = Date().timeIntervalSince(startTime)
            print("🔍 Search index rebuilt with \(searchIndex.count) records in \(duration)s")
            
            // Post notification to update smart folder counts
            NotificationCenter.default.post(name: .searchIndexDidRebuild, object: nil)
        }
    }
    
    /// Build index with progress tracking for rebuild
    private func buildIndexWithProgress(modelContext: ModelContext) async {
        // Monitor the existing buildIndex progress
        let progressTask = Task {
            while isIndexing {
                await MainActor.run {
                    rebuildProgress = indexProgress
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            }
        }
        
        // Start the actual index building
        await buildIndex(modelContext: modelContext)
        
        // Cancel progress monitoring
        progressTask.cancel()
    }
    
    /// Manual rebuild trigger with model context
    func manualRebuildIndex(modelContext: ModelContext) async {
        searchIndex = [] // Clear existing index
        await rebuildIndexFromDatabase(modelContext: modelContext)
    }
    
    struct PhotoSearchRecord: Identifiable, Equatable {
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
            var offset = 0
            
            while offset < totalCount {
                autoreleasepool {
                    var descriptor = FetchDescriptor<Photo>(
                        sortBy: [SortDescriptor(\Photo.captureDate, order: .reverse), SortDescriptor(\Photo.filePath)]
                    )
                    descriptor.fetchLimit = batchSize
                    descriptor.fetchOffset = offset
                    descriptor.relationshipKeyPathsForPrefetching = [\.photoTags]
                    
                    do {
                        let batch = try modelContext.fetch(descriptor)
                        
                        if batch.isEmpty {
                            return
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
                            
                            offset += batch.count
                            indexProgress = Double(offset) / Double(totalCount)
                            
                            print("🔍 Processed \(offset)/\(totalCount) photos (\(Int(indexProgress * 100))%)")
                        }
                    } catch {
                        print("❌ Error fetching batch: \(error)")
                        return
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
    
    /// Evaluate a smart folder rule and return matching photo IDs
    func evaluateSmartFolderRule(_ rule: SmartFolderRule, maxResults: Int = 200) -> (ids: [PersistentIdentifier], totalCount: Int) {
        return search(
            query: rule.query,
            locationQuery: rule.locationQuery,
            cameraQuery: rule.cameraQuery,
            dateRange: convertDateRange(rule.dateRange),
            source: convertSourceFilter(rule.sourceFilter),
            selectedTagNames: rule.selectedTagNames,
            maxResults: maxResults
        )
    }
    
    private func convertDateRange(_ range: SmartFolderDateRange) -> DateRange {
        switch range {
        case .all: return .all
        case .today: return .today
        case .thisWeek: return .week
        case .thisMonth: return .month
        case .thisYear: return .year
        }
    }
    
    private func convertSourceFilter(_ filter: SourceFilter) -> SearchFilters.SourceFilter {
        switch filter {
        case .all: return .all
        case .iCloudDrive: return .iCloudDrive
        case .iCloudPhotos: return .photosLibrary
        case .localPhotos: return .all // Fallback for now
        }
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
