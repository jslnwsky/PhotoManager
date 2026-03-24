import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var vm = FoldersViewModel()

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
        .environment(vm)
    }
}

struct EnrichmentBannerView: View {
    @Environment(FoldersViewModel.self) private var vm
    
    var body: some View {
        if vm.isEnrichmentRunning {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.enrichmentPhase.rawValue)
                        .font(.caption)
                        .fontWeight(.medium)
                    if !vm.enrichmentDetail.isEmpty && vm.enrichmentDetail != vm.enrichmentPhase.rawValue {
                        Text(vm.enrichmentDetail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Spacer()
                
                if vm.enrichmentProgress > 0 {
                    Text("\(Int(vm.enrichmentProgress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Photo.self, PhotoThumbnail.self, Tag.self, Folder.self, PhotoTag.self], inMemory: true)
}
