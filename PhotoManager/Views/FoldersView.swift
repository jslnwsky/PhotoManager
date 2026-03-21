import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import Photos



struct FoldersView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.name) private var folders: [Folder]
    @State private var showingAddFolder = false
    @State private var showingFolderPicker = false
    @State private var isScanning = false
    @State private var scanProgress: Double = 0.0
    @State private var scanError: String? = nil
    @State private var isEnriching = false
    @State private var enrichProgress: Double = 0.0
    @State private var enrichError: String? = nil
    @State private var isScanningPhotos = false
    @State private var photoScanProgress: Double = 0.0
    @State private var photoScanError: String? = nil
    @State private var photoLibraryService: PhotoLibraryService? = nil

    var iCloudFolders: [Folder] {
        folders.filter { $0.parentFolder == nil && $0.source == .iCloudDrive }
    }

    var photoLibraryFolders: [Folder] {
        folders.filter { $0.parentFolder != nil && $0.source == .localPhotos }
    }

    var virtualFolders: [Folder] {
        folders.filter { $0.parentFolder == nil && $0.source == .virtual }
    }

    var storedRootURL: URL? {
        guard let data = UserDefaults.standard.data(forKey: "rootFolderBookmark") else { return nil }
        var isStale = false
        let url = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &isStale)
        if isStale { UserDefaults.standard.removeObject(forKey: "rootFolderBookmark") }
        return isStale ? nil : url
    }

    var body: some View {
        NavigationStack {
            List {
                if isScanning {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView(value: scanProgress)
                            Text("Scanning iCloud Drive… \(Int(scanProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if isEnriching {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView(value: enrichProgress)
                            Text("Fetching full metadata… \(Int(enrichProgress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if isScanningPhotos {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text("Scanning Photos Library…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                if let error = scanError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let error = enrichError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                if let error = photoScanError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }

                Section("iCloud Drive") {
                    if storedRootURL == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No iCloud Drive folder selected")
                                .foregroundStyle(.secondary)
                            Button("Select iCloud Drive Folder") {
                                showingFolderPicker = true
                            }
                        }
                        .padding(.vertical, 4)
                    } else if iCloudFolders.isEmpty && !isScanning {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No folders indexed yet")
                                .foregroundStyle(.secondary)
                            Button("Scan Now") {
                                if let url = storedRootURL { startScan(rootURL: url) }
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(iCloudFolders.sorted { $0.name < $1.name }) { folder in
                            FolderRowView(folder: folder)
                        }
                    }
                }

                Section("Photos Library") {
                    if photoLibraryFolders.isEmpty && !isScanningPhotos {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No albums indexed yet")
                                .foregroundStyle(.secondary)
                            Button("Scan Photos Library") {
                                startPhotoLibraryScan()
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(photoLibraryFolders.sorted { $0.name < $1.name }) { folder in
                            FolderRowView(folder: folder)
                        }
                    }
                }

                Section("Virtual Folders") {
                    ForEach(virtualFolders.sorted { $0.name < $1.name }) { folder in
                        FolderRowView(folder: folder)
                    }
                }
            }
            .navigationTitle("Folders")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddFolder = true
                    } label: {
                        Label("Add Folder", systemImage: "folder.badge.plus")
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    if !isScanning && !isEnriching && !isScanningPhotos {
                        Menu {
                            Button {
                                if let url = storedRootURL { startScan(rootURL: url) }
                                else { showingFolderPicker = true }
                            } label: {
                                Label("Scan iCloud Drive", systemImage: "arrow.clockwise")
                            }
                            Button {
                                startPhotoLibraryScan()
                            } label: {
                                Label("Scan Photos Library", systemImage: "photo.on.rectangle")
                            }
                            Button {
                                showingFolderPicker = true
                            } label: {
                                Label("Change Folder", systemImage: "folder")
                            }
                            Button {
                                startEnrich()
                            } label: {
                                Label("Fetch Full Metadata", systemImage: "arrow.down.circle")
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
                if let bookmark = try? url.bookmarkData(
                    options: .minimalBookmark,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                ) {
                    UserDefaults.standard.set(bookmark, forKey: "rootFolderBookmark")
                }
                startScan(rootURL: url)
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    private func startEnrich(rootURL: URL? = nil) {
        isEnriching = true
        enrichError = nil
        enrichProgress = 0.0
        Task {
            let accessing = rootURL?.startAccessingSecurityScopedResource() ?? false
            let service = IndexingService(modelContainer: modelContext.container)
            let error = await service.enrichMetadata(rootURL: rootURL) { progress in
                Task { @MainActor in
                    enrichProgress = progress
                }
            }
            if accessing { rootURL?.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                isEnriching = false
                enrichError = error
            }
        }
    }

    private func startScan(rootURL: URL) {
        isScanning = true
        scanError = nil
        scanProgress = 0.0
        Task {
            let accessing = rootURL.startAccessingSecurityScopedResource()
            let service = IndexingService(modelContainer: modelContext.container)
            let error = await service.startIndexing(rootURL: rootURL) { progress in
                Task { @MainActor in
                    scanProgress = progress
                }
            }
            if accessing { rootURL.stopAccessingSecurityScopedResource() }
            await MainActor.run {
                isScanning = false
                scanError = error
            }
        }
    }
    
    private func startPhotoLibraryScan() {
        isScanningPhotos = true
        photoScanError = nil
        photoScanProgress = 0.0
        Task {
            let service = PhotoLibraryService(modelContainer: modelContext.container)
            photoLibraryService = service // Retain service to prevent deallocation
            do {
                let result = try await service.scanPhotosLibrary()
                await MainActor.run {
                    isScanningPhotos = false
                    photoLibraryService = nil // Release after completion
                    print("Photos Library scan complete: \(result.photoCount) photos in \(result.albumCount) albums")
                }
            } catch {
                await MainActor.run {
                    isScanningPhotos = false
                    photoLibraryService = nil // Release on error
                    photoScanError = error.localizedDescription
                }
            }
        }
    }
}

struct FolderRowView: View {
    let folder: Folder
    
    private var iconName: String {
        switch folder.source {
        case .iCloudDrive:
            return "folder.fill"
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
                    Text("\(folder.photoCount) photos")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }
}

struct FolderDetailView: View {
    let folder: Folder
    @Query private var allPhotos: [Photo]
    
    var folderPhotos: [Photo] {
        allPhotos.filter { $0.folder === folder }
    }
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 8)
            ], spacing: 8) {
                ForEach(folderPhotos) { photo in
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
