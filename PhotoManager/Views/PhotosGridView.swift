import SwiftUI
import SwiftData

struct PhotosGridView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Photo.captureDate, order: .reverse) private var photos: [Photo]
    @State private var searchText = ""
    @State private var selectedDateRange: DateRange = .all
    @State private var selectedTags: Set<Tag> = []
    @State private var showingFilters = false
    
    var filteredPhotos: [Photo] {
        var result = photos
        
        if !searchText.isEmpty {
            result = result.filter { photo in
                photo.fileName.localizedCaseInsensitiveContains(searchText) ||
                photo.photoDescription?.localizedCaseInsensitiveContains(searchText) == true ||
                photo.keywords.contains(where: { $0.localizedCaseInsensitiveContains(searchText) })
            }
        }
        
        if selectedDateRange != .all {
            result = result.filter { photo in
                guard let date = photo.captureDate else { return false }
                return selectedDateRange.contains(date)
            }
        }
        
        if !selectedTags.isEmpty {
            result = result.filter { photo in
                let photoTags = Set(photo.tags)
                return !photoTags.isDisjoint(with: selectedTags)
            }
        }
        
        return result
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [
                    GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 8)
                ], spacing: 8) {
                    ForEach(filteredPhotos) { photo in
                        NavigationLink(destination: PhotoDetailView(photo: photo)) {
                            PhotoThumbnailView(photo: photo)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Photos")
            .searchable(text: $searchText, prompt: "Search photos")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingFilters = true
                    } label: {
                        Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                    }
                }
            }
            .sheet(isPresented: $showingFilters) {
                FilterView(
                    selectedDateRange: $selectedDateRange,
                    selectedTags: $selectedTags
                )
            }
            .overlay {
                if filteredPhotos.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo.on.rectangle",
                        description: Text(photos.isEmpty ? "No photos indexed yet" : "No photos match your filters")
                    )
                }
            }
        }
    }
}

struct PhotoThumbnailView: View {
    let photo: Photo
    
    private var borderColor: Color {
        if photo.hasFullMetadata {
            if !photo.keywords.isEmpty || !photo.tags.isEmpty {
                return .green
            } else {
                return .yellow
            }
        } else {
            return .orange
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let thumbnailData = photo.thumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 150, height: 150)
                    .clipped()
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor, lineWidth: 3)
                    )
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .frame(width: 150, height: 150)
                    .cornerRadius(8)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundColor(.gray)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(borderColor, lineWidth: 3)
                    )
            }
            
            if !photo.tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(photo.tags.prefix(3)) { tag in
                        Circle()
                            .fill(tag.color)
                            .frame(width: 8, height: 8)
                    }
                }
                .padding(6)
                .background(.ultraThinMaterial)
                .cornerRadius(6)
                .padding(6)
            }
        }
    }
}

struct FilterView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedDateRange: DateRange
    @Binding var selectedTags: Set<Tag>
    @Query(sort: \Tag.name) private var allTags: [Tag]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Date Range") {
                    Picker("Range", selection: $selectedDateRange) {
                        ForEach(DateRange.allCases) { range in
                            Text(range.displayName).tag(range)
                        }
                    }
                }
                
                Section("Tags") {
                    ForEach(allTags) { tag in
                        Button {
                            if selectedTags.contains(tag) {
                                selectedTags.remove(tag)
                            } else {
                                selectedTags.insert(tag)
                            }
                        } label: {
                            HStack {
                                Circle()
                                    .fill(tag.color)
                                    .frame(width: 12, height: 12)
                                
                                Text(tag.fullPath)
                                    .foregroundColor(.primary)
                                
                                Spacer()
                                
                                if selectedTags.contains(tag) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
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
                    Button("Done") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .cancellationAction) {
                    Button("Reset") {
                        selectedDateRange = .all
                        selectedTags.removeAll()
                    }
                }
            }
        }
    }
}

enum DateRange: String, CaseIterable, Identifiable {
    case all = "All"
    case today = "Today"
    case week = "This Week"
    case month = "This Month"
    case year = "This Year"
    
    var id: String { rawValue }
    
    var displayName: String { rawValue }
    
    func contains(_ date: Date) -> Bool {
        let calendar = Calendar.current
        let now = Date()
        
        switch self {
        case .all:
            return true
        case .today:
            return calendar.isDateInToday(date)
        case .week:
            return calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear)
        case .month:
            return calendar.isDate(date, equalTo: now, toGranularity: .month)
        case .year:
            return calendar.isDate(date, equalTo: now, toGranularity: .year)
        }
    }
}

#Preview {
    PhotosGridView()
        .modelContainer(for: [Photo.self, Tag.self], inMemory: true)
}
