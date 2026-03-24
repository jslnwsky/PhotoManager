import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var tags: [Tag]
    
    @ObservedObject private var searchIndex = SearchIndexService.shared

    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showingFilters = false
    @State private var filters = SearchFilters()
    @State private var searchResults: [Photo] = []
    @State private var totalMatchCount: Int = 0
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?

    private static let maxResults = 200

    var activeFilterCount: Int {
        var count = 0
        if filters.dateRange != .all { count += 1 }
        if !filters.selectedTags.isEmpty { count += 1 }
        if filters.source != .all { count += 1 }
        if !filters.cameraQuery.isEmpty { count += 1 }
        if !filters.locationQuery.isEmpty { count += 1 }
        return count
    }

    var isResultsTruncated: Bool {
        totalMatchCount > Self.maxResults
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                EnrichmentBannerView()
                
                if activeFilterCount > 0 {
                    ActiveFiltersBar(filters: $filters)
                }

                if searchIndex.isIndexing {
                    VStack(spacing: 16) {
                        ProgressView(value: searchIndex.indexProgress)
                            .progressViewStyle(.linear)
                            .frame(maxWidth: 200)
                        Text("Building search index...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        Text("\(Int(searchIndex.indexProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !searchIndex.isIndexReady {
                    ContentUnavailableView(
                        "Search Index Not Ready",
                        systemImage: "magnifyingglass.circle",
                        description: Text("Search index will be built during the next photo scan")
                    )
                } else if debouncedSearchText.isEmpty && activeFilterCount == 0 {
                    ContentUnavailableView(
                        "Search Photos",
                        systemImage: "magnifyingglass",
                        description: Text("Type a keyword or use filters to find photos")
                    )
                } else if isSearching {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Searching \(debouncedSearchText.isEmpty ? "photos" : "\"\(debouncedSearchText)\"")...")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "photo.on.rectangle",
                        description: Text("No photos match your search")
                    )
                } else {
                    ScrollView {
                        Text(isResultsTruncated ? "Showing first \(Self.maxResults) of \(totalMatchCount) photos" : "\(searchResults.count) photos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 8)
                        ], spacing: 8) {
                            ForEach(searchResults) { photo in
                                NavigationLink(destination: PhotoDetailView(photo: photo)) {
                                    PhotoThumbnailView(photo: photo)
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .task {
                // Auto-rebuild index from existing photos if not ready
                if !searchIndex.isIndexReady && !searchIndex.isIndexing {
                    await searchIndex.buildIndex(modelContext: modelContext)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: "Keyword, filename, description…")
            .onChange(of: searchText) { _, newValue in
                // Debounce: update debouncedSearchText after 500ms of no typing
                let captured = newValue
                Task {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if searchText == captured { 
                        debouncedSearchText = captured
                        performSearch()
                    }
                }
            }
            .onChange(of: filters) { _, _ in
                performSearch()
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filters", systemImage: activeFilterCount > 0
                              ? "line.3.horizontal.decrease.circle.fill"
                              : "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                SearchFiltersView(filters: $filters, tags: tags)
            }
        }
    }

    private func performSearch() {
        // Cancel any existing search
        searchTask?.cancel()
        
        guard !debouncedSearchText.isEmpty || activeFilterCount > 0 else {
            searchResults = []
            totalMatchCount = 0
            isSearching = false
            return
        }
        
        isSearching = true
        
        // Capture current filter state
        let currentFilters = filters
        let currentSearchText = debouncedSearchText
        
        searchTask = Task {
            let startTime = Date()
            
            // Search the index (fast - milliseconds)
            let (matchingIDs, totalMatches) = searchIndex.search(
                query: currentSearchText,
                locationQuery: currentFilters.locationQuery,
                cameraQuery: currentFilters.cameraQuery,
                dateRange: currentFilters.dateRange,
                source: currentFilters.source,
                selectedTagNames: Set(currentFilters.selectedTags.map { $0.name }),
                maxResults: Self.maxResults
            )
            
            // Check if task was cancelled
            guard !Task.isCancelled else {
                await MainActor.run {
                    isSearching = false
                }
                return
            }
            
            // Fetch only the matching photos by ID (fast - only fetches what we need)
            let fetchStart = Date()
            var results: [Photo] = []
            
            for id in matchingIDs {
                if let photo = modelContext.model(for: id) as? Photo {
                    results.append(photo)
                }
            }
            
            print("📊 Fetched \(results.count) matching photos in \(Date().timeIntervalSince(fetchStart))s")
            print("📊 Total search time: \(Date().timeIntervalSince(startTime))s")
            
            // Update UI on main thread
            await MainActor.run {
                searchResults = results
                totalMatchCount = totalMatches
                isSearching = false
            }
        }
    }
    
}

// MARK: - Filters Model

struct SearchFilters: Equatable {
    var dateRange: DateRange = .all
    var locationQuery: String = ""
    var cameraQuery: String = ""
    var source: SourceFilter = .all
    var selectedTags: Set<Tag> = []

    enum SourceFilter: String, CaseIterable, Identifiable {
        case all = "All Sources"
        case iCloudDrive = "iCloud Drive"
        case photosLibrary = "Photos Library"
        var id: String { rawValue }
    }
}

// MARK: - Active Filters Bar

struct ActiveFiltersBar: View {
    @Binding var filters: SearchFilters

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if filters.dateRange != .all {
                    FilterChip(label: filters.dateRange.displayName) {
                        filters.dateRange = .all
                    }
                }
                if !filters.locationQuery.isEmpty {
                    FilterChip(label: "📍 \(filters.locationQuery)") {
                        filters.locationQuery = ""
                    }
                }
                if !filters.cameraQuery.isEmpty {
                    FilterChip(label: "📷 \(filters.cameraQuery)") {
                        filters.cameraQuery = ""
                    }
                }
                if filters.source != .all {
                    FilterChip(label: filters.source.rawValue) {
                        filters.source = .all
                    }
                }
                ForEach(Array(filters.selectedTags), id: \.self) { tag in
                    FilterChip(label: tag.name, color: tag.color) {
                        filters.selectedTags.remove(tag)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .background(Color(.secondarySystemBackground))
    }
}

struct FilterChip: View {
    let label: String
    var color: Color = .blue
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button { onRemove() } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.15))
        .foregroundStyle(color)
        .clipShape(Capsule())
    }
}

// MARK: - Filters Sheet

struct SearchFiltersView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var filters: SearchFilters
    let tags: [Tag]

    var body: some View {
        NavigationStack {
            Form {
                Section("Date") {
                    Picker("Date Range", selection: $filters.dateRange) {
                        ForEach(DateRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Location") {
                    TextField("City or country…", text: $filters.locationQuery)
                        .autocorrectionDisabled()
                }

                Section("Camera") {
                    TextField("Make, model or lens…", text: $filters.cameraQuery)
                        .autocorrectionDisabled()
                }

                Section("Source") {
                    Picker("Source", selection: $filters.source) {
                        ForEach(SearchFilters.SourceFilter.allCases) { s in
                            Text(s.rawValue).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Tags") {
                    ForEach(tags) { tag in
                        Button {
                            if filters.selectedTags.contains(tag) {
                                filters.selectedTags.remove(tag)
                            } else {
                                filters.selectedTags.insert(tag)
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 10, height: 10)
                                Text(tag.fullPath)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if filters.selectedTags.contains(tag) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Filters")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        filters = SearchFilters()
                    }
                }
            }
        }
    }
}

#Preview {
    SearchView()
        .modelContainer(for: [Photo.self, Tag.self], inMemory: true)
}
