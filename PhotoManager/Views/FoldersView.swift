import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct FoldersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.name) private var folders: [Folder]
    @State private var vm = FoldersViewModel()
    @State private var showingAddFolder = false
    @State private var showingFolderPicker = false

    var iCloudFolders: [Folder] {
        folders.filter { $0.parentFolder == nil && $0.source == .iCloudDrive }
    }

    var photoLibraryRootFolders: [Folder] {
        // Get top-level Photos Library folders (albums that are direct children of root)
        folders.filter { $0.parentFolder != nil && $0.parentFolder?.parentFolder == nil && $0.source == .localPhotos }
    }

    var virtualFolders: [Folder] {
        folders.filter { $0.parentFolder == nil && $0.source == .virtual }
    }

    var body: some View {
        NavigationStack {
            List {
                // Progress sections
                if vm.isScanning {
                    ProgressSection(value: vm.scanProgress, label: "Scanning iCloud Drive… \(Int(vm.scanProgress * 100))%")
                }
                if vm.isEnriching {
                    ProgressSection(value: vm.enrichProgress, label: "Fetching full metadata… \(Int(vm.enrichProgress * 100))%")
                }
                if vm.isScanningPhotos {
                    Section { VStack(spacing: 8) { ProgressView(); Text("Scanning Photos Library…").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 4) }
                }
                if vm.isGeocoding {
                    ProgressSection(value: vm.geocodeProgress, label: vm.geocodeStatus.isEmpty ? "Geocoding locations…" : "Geocoding: \(vm.geocodeStatus)")
                }

                // Error sections
                ForEach([vm.scanError, vm.enrichError, vm.photoScanError, vm.geocodeError].compactMap({ $0 }), id: \.self) { error in
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.caption)
                    }
                }

                // iCloud Drive - collapsible top-level group
                DisclosureGroup {
                    if vm.storedRootURL == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No iCloud Drive folder selected").foregroundStyle(.secondary)
                            Button("Select iCloud Drive Folder") { showingFolderPicker = true }
                        }
                        .padding(.vertical, 4)
                    } else if iCloudFolders.isEmpty && !vm.isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No folders indexed yet").foregroundStyle(.secondary)
                            Button("Scan Now") {
                                if let url = vm.storedRootURL { vm.startScan(rootURL: url, container: modelContext.container) }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(iCloudFolders.sorted { $0.name < $1.name }) { folder in
                            HierarchicalFolderRow(folder: folder)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "icloud.fill")
                            .foregroundColor(.blue)
                        Text("iCloud Drive")
                            .font(.headline)
                        Spacer()
                        if !iCloudFolders.isEmpty {
                            Text("\(iCloudFolders.count) folders")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Photos Library - collapsible top-level group
                DisclosureGroup {
                    if photoLibraryRootFolders.isEmpty && !vm.isScanningPhotos {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No albums indexed yet").foregroundStyle(.secondary)
                            Button("Scan Photos Library") { vm.startPhotoLibraryScan(container: modelContext.container) }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(photoLibraryRootFolders.sorted { $0.name < $1.name }) { folder in
                            HierarchicalFolderRow(folder: folder)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "photo.on.rectangle")
                            .foregroundColor(.green)
                        Text("Photos Library")
                            .font(.headline)
                        Spacer()
                        if !photoLibraryRootFolders.isEmpty {
                            Text("\(photoLibraryRootFolders.count) albums")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                // Virtual Folders - collapsible top-level group
                DisclosureGroup {
                    if virtualFolders.isEmpty {
                        Text("No virtual folders yet")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(virtualFolders.sorted { $0.name < $1.name }) { folder in
                            FolderRowView(folder: folder)
                        }
                    }
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.person.crop")
                            .foregroundColor(.purple)
                        Text("Virtual Folders")
                            .font(.headline)
                        Spacer()
                        if !virtualFolders.isEmpty {
                            Text("\(virtualFolders.count) folders")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAddFolder = true } label: {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if !vm.isBusy {
                        Menu {
                            Button {
                                if let url = vm.storedRootURL { vm.startScan(rootURL: url, container: modelContext.container) }
                                else { showingFolderPicker = true }
                            } label: {
                                Label("Scan iCloud Drive", systemImage: "arrow.clockwise")
                            }
                            Button { vm.startPhotoLibraryScan(container: modelContext.container) } label: {
                                Label("Scan Photos Library", systemImage: "photo.on.rectangle")
                            }
                            Button { showingFolderPicker = true } label: {
                                Label("Change Folder", systemImage: "folder")
                            }
                            Button { vm.startEnrich(rootURL: vm.storedRootURL, container: modelContext.container) } label: {
                                Label("Fetch Full Metadata", systemImage: "arrow.down.circle")
                            }
                            Button { vm.startGeocoding(container: modelContext.container) } label: {
                                Label("Geocode Locations", systemImage: "mappin.and.ellipse")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingAddFolder) {
                AddVirtualFolderView()
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                guard let url = try? result.get().first else { return }
                let accessing = url.startAccessingSecurityScopedResource()
                vm.saveBookmark(for: url)
                vm.startScan(rootURL: url, container: modelContext.container)
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
        }
    }
}

private struct ProgressSection: View {
    let value: Double
    let label: String
    var body: some View {
        Section {
            VStack(spacing: 8) {
                ProgressView(value: value)
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

struct HierarchicalFolderRow: View {
    let folder: Folder
    @State private var isExpanded = false
    
    var body: some View {
        if folder.childFolders.isEmpty {
            FolderRowView(folder: folder)
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(folder.childFolders.sorted { $0.name < $1.name }) { child in
                    HierarchicalFolderRow(folder: child)
                }
            } label: {
                FolderRowView(folder: folder)
            }
        }
    }
}

struct FolderRowView: View {
    let folder: Folder
    
    private var hasChildren: Bool {
        !folder.childFolders.isEmpty
    }
    
    private var iconName: String {
        switch folder.source {
        case .iCloudDrive:
            return hasChildren ? "folder.fill.badge.gearshape" : "folder.fill"
        case .localPhotos:
            return "photo.on.rectangle"
        case .virtual:
            return "folder.badge.person.crop"
        case .iCloudPhotos:
            return "icloud.and.arrow.down"
        }
    }
    
    private var iconColor: Color {
        switch folder.source {
        case .iCloudDrive:
            return .blue
        case .localPhotos:
            return .green
        case .virtual:
            return .purple
        case .iCloudPhotos:
            return .cyan
        }
    }

    var body: some View {
        NavigationLink(destination: FolderDetailView(folder: folder)) {
            HStack {
                Image(systemName: iconName)
                    .foregroundColor(iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.body)
                    
                    HStack(spacing: 4) {
                        Text("\(folder.photoCount) photos")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        if hasChildren {
                            Text("• \(folder.childFolders.count) subfolders")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
    }
}

struct FolderDetailView: View {
    let folder: Folder
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 8)
            ], spacing: 8) {
                ForEach(folder.photos) { photo in
                    NavigationLink(destination: PhotoDetailView(photo: photo)) {
                        PhotoThumbnailView(photo: photo)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AddVirtualFolderView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var folderName = ""
    @State private var selectedParent: Folder?
    @Query(filter: #Predicate<Folder> { $0.sourceType == "virtual" })
    private var virtualFolders: [Folder]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Folder Details") {
                    TextField("Folder Name", text: $folderName)
                }
                
                Section("Parent Folder (Optional)") {
                    Picker("Parent", selection: $selectedParent) {
                        Text("None").tag(nil as Folder?)
                        ForEach(virtualFolders) { folder in
                            Text(folder.fullPath).tag(folder as Folder?)
                        }
                    }
                }
            }
            .navigationTitle("New Virtual Folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createFolder()
                    }
                    .disabled(folderName.isEmpty)
                }
            }
        }
    }
    
    private func createFolder() {
        let path = selectedParent != nil ? "\(selectedParent!.path)/\(folderName)" : folderName
        
        let folder = Folder(
            name: folderName,
            path: path,
            sourceType: .virtual,
            parentFolder: selectedParent
        )
        
        modelContext.insert(folder)
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    FoldersView()
        .modelContainer(for: [Folder.self, Photo.self], inMemory: true)
}
