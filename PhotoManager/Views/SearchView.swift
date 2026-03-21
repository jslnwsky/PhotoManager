import SwiftUI
import SwiftData

struct SearchView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var photos: [Photo]
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var searchText = ""
    @State private var selectedSearchType: SearchType = .all
    @State private var searchResults: [Photo] = []
    
    enum SearchType: String, CaseIterable {
        case all = "All"
        case fileName = "File Name"
        case description = "Description"
        case location = "Location"
        case camera = "Camera"
        case tags = "Tags"
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Search Type", selection: $selectedSearchType) {
                    ForEach(SearchType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                if searchText.isEmpty {
                    ContentUnavailableView(
                        "Search Photos",
                        systemImage: "magnifyingglass",
                        description: Text("Enter search terms to find photos")
                    )
                } else if searchResults.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "photo.on.rectangle",
                        description: Text("No photos match your search")
                    )
                } else {
                    ScrollView {
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
            .searchable(text: $searchText, prompt: "Search photos...")
            .onChange(of: searchText) { _, newValue in
                performSearch(query: newValue)
            }
            .onChange(of: selectedSearchType) { _, _ in
                performSearch(query: searchText)
            }
        }
    }
    
    private func performSearch(query: String) {
        guard !query.isEmpty else {
            searchResults = []
            return
        }
        
        let lowercaseQuery = query.lowercased()
        
        searchResults = photos.filter { photo in
            switch selectedSearchType {
            case .all:
                return matchesAll(photo: photo, query: lowercaseQuery)
            case .fileName:
                return photo.fileName.lowercased().contains(lowercaseQuery)
            case .description:
                return photo.photoDescription?.lowercased().contains(lowercaseQuery) == true
            case .location:
                return matchesLocation(photo: photo, query: lowercaseQuery)
            case .camera:
                return matchesCamera(photo: photo, query: lowercaseQuery)
            case .tags:
                return matchesTags(photo: photo, query: lowercaseQuery)
            }
        }
    }
    
    private func matchesAll(photo: Photo, query: String) -> Bool {
        if photo.fileName.lowercased().contains(query) {
            return true
        }
        
        if photo.photoDescription?.lowercased().contains(query) == true {
            return true
        }
        
        if photo.keywords.contains(where: { $0.lowercased().contains(query) }) {
            return true
        }
        
        if matchesCamera(photo: photo, query: query) {
            return true
        }
        
        if matchesTags(photo: photo, query: query) {
            return true
        }
        
        return false
    }
    
    private func matchesLocation(photo: Photo, query: String) -> Bool {
        guard photo.location != nil else { return false }
        return true
    }
    
    private func matchesCamera(photo: Photo, query: String) -> Bool {
        if photo.cameraMake?.lowercased().contains(query) == true {
            return true
        }
        
        if photo.cameraModel?.lowercased().contains(query) == true {
            return true
        }
        
        if photo.lensModel?.lowercased().contains(query) == true {
            return true
        }
        
        return false
    }
    
    private func matchesTags(photo: Photo, query: String) -> Bool {
        return photo.tags.contains { tag in
            tag.name.lowercased().contains(query)
        }
    }
}

#Preview {
    SearchView()
        .modelContainer(for: [Photo.self, Tag.self], inMemory: true)
}
