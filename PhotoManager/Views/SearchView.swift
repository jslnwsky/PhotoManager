import SwiftUI
import SwiftData

struct SearchView: View {
    @Query private var photos: [Photo]
    @Query(sort: \Tag.name) private var tags: [Tag]

    @State private var searchText = ""
    @State private var showingFilters = false
    @State private var filters = SearchFilters()

    var activeFilterCount: Int {
        var count = 0
        if filters.dateRange != .all { count += 1 }
        if !filters.selectedTags.isEmpty { count += 1 }
        if filters.source != .all { count += 1 }
        if !filters.cameraQuery.isEmpty { count += 1 }
        if !filters.locationQuery.isEmpty { count += 1 }
        return count
    }

    var searchResults: [Photo] {
        guard !searchText.isEmpty || activeFilterCount > 0 else { return [] }
        return photos.filter { matches($0) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if activeFilterCount > 0 {
                    ActiveFiltersBar(filters: $filters)
                }

                if searchText.isEmpty && activeFilterCount == 0 {
                    ContentUnavailableView(
                        "Search Photos",
                        systemImage: "magnifyingglass",
                        description: Text("Type a keyword or use filters to find photos")
                    )
                } else if searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "photo.on.rectangle",
                        description: Text("No photos match your search")
                    )
                } else {
                    ScrollView {
                        Text("\(searchResults.count) photos")
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
            .navigationTitle("Search")
            .searchable(text: $searchText, prompt: "Keyword, filename, description…")
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

    private func matches(_ photo: Photo) -> Bool {
        // Keyword search across multiple fields
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            let textMatch = photo.fileName.lowercased().contains(q)
                || photo.photoDescription?.lowercased().contains(q) == true
                || photo.keywords.contains(where: { $0.lowercased().contains(q) })
                || photo.cameraMake?.lowercased().contains(q) == true
                || photo.cameraModel?.lowercased().contains(q) == true
                || photo.city?.lowercased().contains(q) == true
                || photo.country?.lowercased().contains(q) == true
                || photo.tags.contains(where: { $0.name.lowercased().contains(q) })
            if !textMatch { return false }
        }

        // Date range filter
        if filters.dateRange != .all {
            guard let date = photo.captureDate, filters.dateRange.contains(date) else { return false }
        }

        // Location filter
        if !filters.locationQuery.isEmpty {
            let lq = filters.locationQuery.lowercased()
            let locationMatch = photo.city?.lowercased().contains(lq) == true
                || photo.country?.lowercased().contains(lq) == true
            if !locationMatch { return false }
        }

        // Camera filter
        if !filters.cameraQuery.isEmpty {
            let cq = filters.cameraQuery.lowercased()
            let cameraMatch = photo.cameraMake?.lowercased().contains(cq) == true
                || photo.cameraModel?.lowercased().contains(cq) == true
                || photo.lensModel?.lowercased().contains(cq) == true
            if !cameraMatch { return false }
        }

        // Source filter
        if filters.source != .all {
            let isPhotosLibrary = photo.filePath.hasPrefix("photos://asset/")
            if filters.source == .photosLibrary && !isPhotosLibrary { return false }
            if filters.source == .iCloudDrive && isPhotosLibrary { return false }
        }

        // Tag filter
        if !filters.selectedTags.isEmpty {
            let photoTags = Set(photo.tags)
            if photoTags.isDisjoint(with: filters.selectedTags) { return false }
        }

        return true
    }
}

// MARK: - Filters Model

struct SearchFilters {
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
