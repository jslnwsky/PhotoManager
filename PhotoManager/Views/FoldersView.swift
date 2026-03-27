import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct FoldersView: View {
    private enum FolderPickerAction {
        case scan
        case backup
        case backupDestination
        case restore
    }

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.name) private var folders: [Folder]
    @Environment(FoldersViewModel.self) private var vm
    @State private var showingAddFolder = false
    @State private var showingFolderPicker = false
    @State private var activeFolderPicker: FolderPickerAction?
    @State private var pendingRestoreFolderURL: URL?
    @State private var pendingRestorePreview: BackupService.BackupPreview?
    @State private var showingRestoreConfirmation = false
    @State private var showingBackupAutomation = false

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
                if vm.isRecalculatingFileSizes {
                    ProgressSection(
                        value: vm.fileSizeRecalcProgress,
                        label: vm.fileSizeRecalcStatus.isEmpty ? "Recalculating Photos file sizes..." : "\(vm.fileSizeRecalcStatus) \(Int(vm.fileSizeRecalcProgress * 100))%"
                    )
                }
                if vm.isBackingUp {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(vm.backupStatus.isEmpty ? "Creating backup..." : vm.backupStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
                if vm.isRestoring {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(vm.restoreStatus.isEmpty ? "Restoring backup..." : vm.restoreStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Error sections
                ForEach([vm.scanError, vm.enrichError, vm.photoScanError, vm.geocodeError, vm.fileSizeRecalcError, vm.backupError, vm.restoreError].compactMap({ $0 }), id: \.self) { error in
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red).font(.caption)
                    }
                }

                if !vm.fileSizeRecalcStatus.isEmpty && !vm.isRecalculatingFileSizes {
                    Section {
                        Label(vm.fileSizeRecalcStatus, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                if !vm.backupStatus.isEmpty && !vm.isBackingUp {
                    Section {
                        Label(vm.backupStatus, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                if !vm.restoreStatus.isEmpty && !vm.isRestoring {
                    Section {
                        Label(vm.restoreStatus, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                if vm.hasPendingRestoreAcceptance {
                    Section("Restore Decision") {
                        Button {
                            vm.acceptRestore(container: modelContext.container)
                        } label: {
                            Label("Accept Restore", systemImage: "checkmark.seal")
                        }

                        Button(role: .destructive) {
                            vm.rollbackRestore(container: modelContext.container)
                        } label: {
                            Label("Rollback", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                
                if vm.isEnrichmentRunning {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(vm.enrichmentPhase.rawValue)
                                    .font(.caption)
                                    .fontWeight(.medium)
                                if vm.enrichmentProgress > 0 {
                                    ProgressView(value: vm.enrichmentProgress)
                                        .progressViewStyle(.linear)
                                }
                                if !vm.enrichmentDetail.isEmpty && vm.enrichmentDetail != vm.enrichmentPhase.rawValue {
                                    Text(vm.enrichmentDetail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // iCloud Drive - collapsible top-level group
                DisclosureGroup {
                    if vm.storedRootURL == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No iCloud Drive folder selected").foregroundStyle(.secondary)
                            Button("Select iCloud Drive Folder") {
                                activeFolderPicker = .scan
                                showingFolderPicker = true
                            }
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
                    VStack(alignment: .leading, spacing: 2) {
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

                        if let summary = vm.rootMetricsSummary(for: .iCloudDrive) {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 2) {
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

                        if let summary = vm.rootMetricsSummary(for: .localPhotos) {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                    VStack(alignment: .leading, spacing: 2) {
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

                        if let summary = vm.rootMetricsSummary(for: .virtual) {
                            Text(summary)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
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
                ToolbarItemGroup(placement: .navigationBarLeading) {
                    Button {
                        showingBackupAutomation = true
                    } label: {
                        Image(systemName: "externaldrive.badge.plus")
                    }
                    .disabled(vm.isBusy)

                    Button {
                        activeFolderPicker = .restore
                        showingFolderPicker = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise.circle")
                    }
                    .disabled(vm.isBusy)

                    Menu {
                        Button {
                            if let url = vm.storedRootURL { vm.startScan(rootURL: url, container: modelContext.container) }
                            else {
                                activeFolderPicker = .scan
                                showingFolderPicker = true
                            }
                        } label: {
                            Label("Scan iCloud Drive", systemImage: "arrow.clockwise")
                        }
                        .disabled(vm.isBusy)

                        Button { vm.startPhotoLibraryScan(container: modelContext.container) } label: {
                            Label("Scan Photos Library", systemImage: "photo.on.rectangle")
                        }
                        .disabled(vm.isBusy)

                        Button {
                            activeFolderPicker = .scan
                            showingFolderPicker = true
                        } label: {
                            Label("Change Folder", systemImage: "folder")
                        }
                        .disabled(vm.isBusy)

                        Button { vm.startEnrich(rootURL: vm.storedRootURL, container: modelContext.container) } label: {
                            Label("Fetch Full Metadata", systemImage: "arrow.down.circle")
                        }
                        .disabled(vm.isBusy)

                        Button { vm.startGeocoding(container: modelContext.container) } label: {
                            Label("Geocode Locations", systemImage: "mappin.and.ellipse")
                        }
                        .disabled(vm.isBusy)

                        Button { vm.startHashBackfill(container: modelContext.container) } label: {
                            Label("PhotoFP", systemImage: "fingerprint")
                        }
                        .disabled(vm.isBusy)

                        Button { vm.startRecalculatePhotosLibraryFileSizes(container: modelContext.container) } label: {
                            Label("Recalculate File Sizes", systemImage: "externaldrive.fill.badge.person.crop")
                        }
                        .disabled(vm.isBusy)

                        Divider()

                        Button {
                            if vm.hasStoredBackupDestination {
                                vm.startBackup(container: modelContext.container)
                            } else {
                                activeFolderPicker = .backup
                                showingFolderPicker = true
                            }
                        } label: {
                            Label("Backup Data", systemImage: "externaldrive.badge.plus")
                        }
                        .disabled(vm.isBusy)

                        Button(role: .destructive) {
                            activeFolderPicker = .restore
                            showingFolderPicker = true
                        } label: {
                            Label("Restore Backup", systemImage: "arrow.counterclockwise.circle")
                        }
                        .disabled(vm.isBusy)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingAddFolder) {
                AddVirtualFolderView()
            }
            .sheet(isPresented: $showingBackupAutomation) {
                BackupAutomationView()
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                showingFolderPicker = false
                guard let url = try? result.get().first else { return }
                let action = activeFolderPicker
                activeFolderPicker = nil

                switch action {
                case .scan:
                    let accessing = url.startAccessingSecurityScopedResource()
                    vm.saveBookmark(for: url)
                    vm.startScan(rootURL: url, container: modelContext.container)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                case .backup:
                    vm.startBackup(destinationFolderURL: url, container: modelContext.container)
                case .backupDestination:
                    let accessing = url.startAccessingSecurityScopedResource()
                    vm.saveBackupDestinationBookmark(for: url)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    if vm.backupAutomationEnabled {
                        BackupAutomationCoordinator.scheduleNextIfNeeded()
                    }
                case .restore:
                    let accessing = url.startAccessingSecurityScopedResource()
                    defer {
                        if accessing { url.stopAccessingSecurityScopedResource() }
                    }

                    do {
                        let preview = try vm.loadRestorePreview(backupFolderURL: url, container: modelContext.container)
                        pendingRestoreFolderURL = url
                        pendingRestorePreview = preview
                        showingRestoreConfirmation = true
                    } catch {
                        pendingRestoreFolderURL = nil
                        pendingRestorePreview = nil
                        vm.restoreError = error.localizedDescription
                    }
                case .none:
                    break
                }
            }
            .alert("Restore backup?", isPresented: $showingRestoreConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingRestoreFolderURL = nil
                    pendingRestorePreview = nil
                }
                Button("Restore", role: .destructive) {
                    guard let url = pendingRestoreFolderURL else { return }
                    vm.startRestore(backupFolderURL: url, container: modelContext.container)
                    pendingRestoreFolderURL = nil
                    pendingRestorePreview = nil
                }
            } message: {
                if let preview = pendingRestorePreview {
                    Text("Folder: \(preview.folderName)\nApp version: \(preview.appVersion)\n\nThis will fully replace all current app data.")
                } else {
                    Text("This will fully replace all current app data.")
                }
            }
            .task {
                vm.refreshBackupDestinationState()
                vm.scheduleRootFolderMetricsRefresh(container: modelContext.container)
            }
        }
    }
}

struct BackupAutomationView: View {
    private enum BackupPickerAction {
        case backup
        case backupDestination
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(FoldersViewModel.self) private var vm

    @State private var showingFolderPicker = false
    @State private var activeFolderPicker: BackupPickerAction?

    private var preferredHourLabel: String {
        String(format: "%02d:00", vm.preferredBackupHour)
    }

    var body: some View {
        NavigationStack {
            List {
                if vm.isBackingUp {
                    Section {
                        VStack(spacing: 8) {
                            ProgressView()
                            Text(vm.backupStatus.isEmpty ? "Creating backup..." : vm.backupStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Backup Automation") {
                    Toggle("Enable Scheduled Backups", isOn: Binding(
                        get: { vm.backupAutomationEnabled },
                        set: { newValue in
                            vm.backupAutomationEnabled = newValue
                            if newValue {
                                BackupAutomationCoordinator.scheduleNextIfNeeded()
                            } else {
                                BackupAutomationCoordinator.cancelScheduled()
                            }
                        }
                    ))

                    Picker("Frequency", selection: Binding(
                        get: { vm.backupFrequency },
                        set: { newValue in
                            vm.backupFrequency = newValue
                            if vm.backupAutomationEnabled {
                                BackupAutomationCoordinator.scheduleNextIfNeeded()
                            }
                        }
                    )) {
                        ForEach(BackupAutomationSettingsStore.BackupFrequency.allCases, id: \.rawValue) { frequency in
                            Text(frequency.displayName).tag(frequency)
                        }
                    }
                    .pickerStyle(.menu)

                    Stepper(value: Binding(
                        get: { vm.preferredBackupHour },
                        set: { newValue in
                            vm.preferredBackupHour = newValue
                            if vm.backupAutomationEnabled {
                                BackupAutomationCoordinator.scheduleNextIfNeeded()
                            }
                        }
                    ), in: 0...23) {
                        Text("Preferred Time: \(preferredHourLabel)")
                    }

                    Button(vm.hasStoredBackupDestination ? "Change Backup Destination" : "Set Backup Destination") {
                        activeFolderPicker = .backupDestination
                        showingFolderPicker = true
                    }
                    .disabled(vm.isBusy)

                    if let destinationName = vm.backupDestinationDisplayName {
                        Label("Destination: \(destinationName)", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        Label("No backup destination set", systemImage: "exclamationmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Button("Run Backup Now") {
                        if vm.hasStoredBackupDestination {
                            vm.startBackup(container: modelContext.container)
                        } else {
                            activeFolderPicker = .backup
                            showingFolderPicker = true
                        }
                    }
                    .disabled(vm.isBusy)
                }

                if !vm.backupStatus.isEmpty && !vm.isBackingUp {
                    Section {
                        Label(vm.backupStatus, systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                }

                if let backupError = vm.backupError {
                    Section {
                        Label(backupError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
                }
            }
            .navigationTitle("Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder],
                allowsMultipleSelection: false
            ) { result in
                showingFolderPicker = false
                guard let url = try? result.get().first else { return }
                let action = activeFolderPicker
                activeFolderPicker = nil

                switch action {
                case .backup:
                    vm.startBackup(destinationFolderURL: url, container: modelContext.container)
                case .backupDestination:
                    let accessing = url.startAccessingSecurityScopedResource()
                    vm.saveBackupDestinationBookmark(for: url)
                    if accessing { url.stopAccessingSecurityScopedResource() }
                    if vm.backupAutomationEnabled {
                        BackupAutomationCoordinator.scheduleNextIfNeeded()
                    }
                case .none:
                    break
                }
            }
            .task {
                vm.refreshBackupDestinationState()
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
