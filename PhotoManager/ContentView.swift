import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FoldersView()
                .tabItem {
                    Label("Folders", systemImage: "folder.fill")
                }
                .tag(0)

            PhotosGridView()
                .tabItem {
                    Label("Photos", systemImage: "photo.on.rectangle")
                }
                .tag(1)

            MapView()
                .tabItem {
                    Label("Map", systemImage: "map.fill")
                }
                .tag(2)

            TagsView()
                .tabItem {
                    Label("Tags", systemImage: "tag.fill")
                }
                .tag(3)

            SearchView()
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }
                .tag(4)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Photo.self, Tag.self, Folder.self, PhotoTag.self], inMemory: true)
}
