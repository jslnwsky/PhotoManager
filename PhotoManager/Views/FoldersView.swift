import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct FoldersView: View {
    enum FolderPickerAction {
        case scan
        case backup
        case backupDestination
        case restore
    }
    
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Folder.name) private var folders: [Folder]
    @Environment(FoldersViewModel.self) private var vm
    @StateObject private var searchService = SearchIndexService.shared
    @State private var showingAddFolder = false
    @State private var showingFolderPicker = false
    @State private var activeFolderPicker: FolderPickerAction?
    @State private var pendingRestoreFolderURL: URL?
    @State private var pendingRestorePreview: BackupService.BackupPreview?
    @State private var showingRestoreConfirmation = false
    @State private var showingBackupAutomation = false
    @State private var showingAddVirtualFolder = false
    @State private var showingToolsMenu = false
    
    // Confirmation dialog states
    @State private var showingScanConfirmation = false
    @State private var showingEnrichConfirmation = false
    @State private var showingPhotoScanConfirmation = false
    @State private var showingGeocodeConfirmation = false
    @State private var showingFileSizeRecalcConfirmation = false
    @State private var showingBackupConfirmation = false
    @State private var showingHashBackfillConfirmation = false
    
    // Pending operation parameters
    @State private var pendingScanURL: URL?
    @State private var pendingEnrichURL: URL?
    @State private var pendingBackupURL: URL?
    
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
                    ProgressSection(value: vm.scanProgress, label: "Scanning iCloud Drive… \(Int(vm.scanProgress * 100))%") {
                        vm.cancelScan()
                    }
                }
                if vm.isEnriching {
                    ProgressSection(value: vm.enrichProgress, label: "Fetching full metadata… \(Int(vm.enrichProgress * 100))%") {
                        vm.cancelEnrich()
                    }
                }
                if vm.isScanningPhotos {
                    Section { 
                        VStack(spacing: 8) { 
                            HStack {
                                ProgressView()
                                Button("Cancel") {
                                    vm.cancelPhotoScan()
                                }
                                .font(.caption)
                                .foregroundColor(.red)
                            }
                            Text("Scanning Photos Library…").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 4) 
                    }
                }
                if vm.isGeocoding {
                    ProgressSection(value: vm.geocodeProgress, label: vm.geocodeStatus.isEmpty ? "Geocoding locations…" : "Geocoding: \(vm.geocodeStatus)") {
                        vm.cancelGeocoding()
                    }
                }
                if vm.isRecalculatingFileSizes {
                    ProgressSection(
                        value: vm.fileSizeRecalcProgress,
                        label: vm.fileSizeRecalcStatus.isEmpty ? "Recalculating Photos file sizes..." : "\(vm.fileSizeRecalcStatus) \(Int(vm.fileSizeRecalcProgress * 100))%"
                    ) {
                        vm.cancelFileSizeRecalc()
                    }
                }
                if vm.isBackingUp {
                    Section {
                        VStack(spacing: 8) {
                            HStack {
                                ProgressView()
                                Button("Cancel") {
                                    vm.cancelBackup()
                                }
                                .font(.caption)
                                .foregroundColor(.red)
                            }
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
                            HStack {
                                ProgressView()
                                Button("Cancel") {
                                    vm.cancelRestore()
                                }
                                .font(.caption)
                                .foregroundColor(.red)
                            }
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
                        VStack(alignment: .leading, spacing: 6) {
                            Text("No virtual folders yet")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Button("Create Smart Folder") {
                                showingAddVirtualFolder = true
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(.vertical, 4)
                    } else {
                        ForEach(virtualFolders.sorted { $0.name < $1.name }) { folder in
                            FolderRowView(folder: folder)
                        }
                        
                        Button("Create Smart Folder") {
                            showingAddVirtualFolder = true
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
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
                        
                        Button {
                            showingToolsMenu = true
                        } label: {
                            Label("Tools", systemImage: "ellipsis.circle")
                        }
                    }
                }
                .sheet(isPresented: $showingAddFolder) {
                    AddFolderView()
                }
                .sheet(isPresented: $showingAddVirtualFolder) {
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
                        pendingScanURL = url
                        showingScanConfirmation = true
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
            .alert("Start iCloud Drive Scan?", isPresented: $showingScanConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingScanURL = nil
                }
                Button("Scan") {
                    guard let url = pendingScanURL else { return }
                    vm.startScan(rootURL: url, container: modelContext.container)
                    pendingScanURL = nil
                }
            } message: {
                Text("This will scan all files in your iCloud Drive folder and may take a long time for large libraries.")
            }
            .alert("Fetch Full Metadata?", isPresented: $showingEnrichConfirmation) {
                Button("Cancel", role: .cancel) {
                    pendingEnrichURL = nil
                }
                Button("Fetch") {
                    guard let url = pendingEnrichURL else { return }
                    vm.startEnrich(rootURL: url, container: modelContext.container)
                    pendingEnrichURL = nil
                }
            } message: {
                Text("This will download and analyze full metadata for all photos and may take considerable time.")
            }
            .alert("Scan Photos Library?", isPresented: $showingPhotoScanConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Scan") {
                    vm.startPhotoLibraryScan(container: modelContext.container)
                }
            } message: {
                Text("This will scan your entire Photos Library and may take a long time for large libraries.")
            }
            .alert("Start Geocoding?", isPresented: $showingGeocodeConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Geocode") {
                    vm.startGeocoding(container: modelContext.container)
                }
            } message: {
                Text("This will look up location names for all photos with GPS coordinates and may require network access.")
            }
            .alert("Recalculate File Sizes?", isPresented: $showingFileSizeRecalcConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Recalculate") {
                    vm.startRecalculatePhotosLibraryFileSizes(container: modelContext.container)
                }
            } message: {
                Text("This will recalculate file sizes for all Photos Library items and may take a long time.")
            }
            .alert("Create Backup?", isPresented: $showingBackupConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Backup") {
                    vm.startBackup(container: modelContext.container)
                }
            } message: {
                Text("This will create a complete backup of your photo data and may take considerable time.")
            }
            .alert("Generate Photo Hashes?", isPresented: $showingHashBackfillConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Generate") {
                    vm.startHashBackfill(container: modelContext.container)
                }
            } message: {
                Text("This will generate unique hashes for all photos to detect duplicates and may take a long time.")
            }
        }
        .overlay {
            // Full-screen overlay for search index rebuild
            if searchService.isRebuildingIndex {
                VStack(spacing: 20) {
                    Spacer()
                    
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                    
                    Text(searchService.rebuildMessage)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    
                    ProgressView(value: searchService.rebuildProgress)
                        .frame(width: 200)
                    
                    Text("\(Int(searchService.rebuildProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                }
                .padding()
                .background(Color(UIColor.systemBackground))
                .ignoresSafeArea()
            }
        }
        .task {
            // Check if search index needs rebuilding and show progress UI
            if searchService.searchIndex.isEmpty && !searchService.isRebuildingIndex {
                await searchService.rebuildIndexFromDatabase(modelContext: modelContext)
            }
        }
        .sheet(isPresented: $showingToolsMenu) {
            ToolsMenuView(
                vm: vm,
                searchService: searchService,
                modelContext: modelContext,
                showingScanConfirmation: $showingScanConfirmation,
                showingPhotoScanConfirmation: $showingPhotoScanConfirmation,
                showingEnrichConfirmation: $showingEnrichConfirmation,
                showingGeocodeConfirmation: $showingGeocodeConfirmation,
                showingFileSizeRecalcConfirmation: $showingFileSizeRecalcConfirmation,
                showingHashBackfillConfirmation: $showingHashBackfillConfirmation,
                showingBackupConfirmation: $showingBackupConfirmation,
                activeFolderPicker: $activeFolderPicker,
                showingFolderPicker: $showingFolderPicker,
                pendingScanURL: $pendingScanURL,
                pendingEnrichURL: $pendingEnrichURL
            )
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
    let onCancel: () -> Void
    
    var body: some View {
        Section {
            VStack(spacing: 8) {
                HStack {
                    ProgressView(value: value)
                    Button("Cancel") {
                        onCancel()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
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
    @State private var photoCount: Int = 0
    @State private var isLoadingCount = false
    
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
                            if isLoadingCount {
                                ProgressView()
                                    .scaleEffect(0.7)
                                Text("Loading...")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(photoCount) photos")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            if hasChildren {
                                Text("• \(folder.childFolders.count) subfolders")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .task {
                await loadPhotoCount()
            }
            .onReceive(NotificationCenter.default.publisher(for: .searchIndexDidChange)) { _ in
                if folder.isVirtual {
                    Task {
                        await loadPhotoCount()
                    }
                }
            }
        }
        
        @MainActor
        private func loadPhotoCount() async {
            if folder.isVirtual {
                if let rule = folder.smartRule {
                    isLoadingCount = true
                    let searchService = SearchIndexService.shared
                    let (_, totalCount) = searchService.evaluateSmartFolderRule(rule, maxResults: 0)
                    photoCount = totalCount
                    isLoadingCount = false
                } else {
                    photoCount = 0
                }
            } else {
                // For regular folders, use the model's photoCount
                photoCount = folder.photoCount
            }
        }
    }
}

struct FolderDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let folder: Folder
    @State private var photos: [Photo] = []
    @State private var isLoading = true
    @State private var totalCount = 0
    @State private var hasMorePhotos = true
    @State private var isLoadingMore = false
    
    private let batchSize = 200
    
    var body: some View {
        VStack {
            if isLoading {
                ProgressView("Loading photos...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if photos.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    
                    Text("No photos found")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    if folder.isVirtual, folder.smartRule != nil {
                        Text("Matching your smart folder criteria")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    if folder.isVirtual {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundColor(.blue)
                            Text("Smart Folder")
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                        .padding(.horizontal)
                        .padding(.top, 8)
                    }
                    
                    ScrollView {
                        LazyVGrid(columns: [
                            GridItem(.adaptive(minimum: 100))
                        ], spacing: 8) {
                            ForEach(photos) { photo in
                                NavigationLink(destination: PhotoDetailView(photo: photo)) {
                                    PhotoThumbnailView(photo: photo)
                                }
                                .onAppear {
                                    // Load more photos when reaching the end
                                    if photo.id == photos.last?.id && hasMorePhotos && !isLoadingMore {
                                        loadMorePhotos()
                                    }
                                }
                            }
                            
                            if isLoadingMore {
                                ProgressView()
                                    .frame(width: 50, height: 50)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadPhotos()
        }
        .onReceive(NotificationCenter.default.publisher(for: .searchIndexDidChange)) { _ in
            if folder.isVirtual {
                Task {
                    await loadPhotos()
                }
            }
        }
    }
    
    private func loadPhotos() async {
        isLoading = true
        photos = []
        hasMorePhotos = true
        
        if folder.isVirtual {
            if let rule = folder.smartRule {
                // Smart folder: evaluate rule dynamically
                let searchService = SearchIndexService.shared
                let (ids, total) = searchService.evaluateSmartFolderRule(rule, maxResults: batchSize)
                
                // Convert IDs to Photo objects
                await loadPhotosFromIds(ids)
                totalCount = total
                hasMorePhotos = photos.count < total
            } else {
                totalCount = 0
                hasMorePhotos = false
            }
        } else {
            // Regular folder: use existing photos relationship
            await MainActor.run {
                photos = Array(folder.photos.sorted { $0.captureDate ?? Date.distantPast > $1.captureDate ?? Date.distantPast }.prefix(batchSize))
                totalCount = folder.photos.count
                hasMorePhotos = photos.count < totalCount
            }
        }
        
        isLoading = false
    }
    
    private func loadMorePhotos() {
        guard !isLoadingMore && hasMorePhotos else { return }
        
        isLoadingMore = true
        
        Task {
            if folder.isVirtual, let rule = folder.smartRule {
                // Load next batch for smart folder
                let searchService = SearchIndexService.shared
                let (ids, _) = searchService.evaluateSmartFolderRule(rule, maxResults: photos.count + batchSize)
                
                // Get only the new photos (beyond current count)
                let newIds = Array(ids.dropFirst(photos.count))
                await loadPhotosFromIds(newIds)
                hasMorePhotos = photos.count < totalCount
            } else {
                // Load next batch for regular folder
                await MainActor.run {
                    let allPhotos = folder.photos.sorted { $0.captureDate ?? Date.distantPast > $1.captureDate ?? Date.distantPast }
                    let newPhotos = Array(allPhotos.dropFirst(photos.count).prefix(batchSize))
                    photos.append(contentsOf: newPhotos)
                    hasMorePhotos = photos.count < totalCount
                }
            }
            
            isLoadingMore = false
        }
    }
    
    @MainActor
    private func loadPhotosFromIds(_ ids: [PersistentIdentifier]) async {
        guard !ids.isEmpty else { return }
        
        let idSet = Set(ids)
        let descriptor = FetchDescriptor<Photo>(
            predicate: #Predicate { photo in
                idSet.contains(photo.persistentModelID)
            },
            sortBy: [SortDescriptor(\Photo.captureDate, order: .reverse)]
        )
        
        do {
            let newPhotos = try modelContext.fetch(descriptor)
            photos.append(contentsOf: newPhotos)
        } catch {
            print("Error fetching smart folder photos: \(error)")
        }
    }
}

struct AddFolderView: View {
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
    
    // MARK: - Add Smart Folder View
    
    struct AddVirtualFolderView: View {
        @Environment(\.modelContext) private var modelContext
        @Environment(\.dismiss) private var dismiss
        @State private var folderName = ""
        @State private var rule = SmartFolderRule()
        @State private var showingTagPicker = false
        @Query private var allTags: [Tag]
        
        var body: some View {
            NavigationView {
                Form {
                    Section("Folder Name") {
                        TextField("Enter folder name", text: $folderName)
                    }
                    
                    Section("Search Criteria") {
                        TextField("Search in filename, description, keywords", text: $rule.query)
                        TextField("Location (city, country)", text: $rule.locationQuery)
                        TextField("Camera (make, model)", text: $rule.cameraQuery)
                    }
                    
                    Section("Date Range") {
                        Picker("Date Range", selection: $rule.dateRange) {
                            ForEach(SmartFolderDateRange.allCases, id: \.self) { range in
                                Text(range.displayName).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Section("Source") {
                        Picker("Source Filter", selection: $rule.sourceFilter) {
                            ForEach(SourceFilter.allCases, id: \.self) { source in
                                Text(source.displayName).tag(source)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    
                    Section("Tags") {
                        if rule.selectedTagNames.isEmpty {
                            Text("No tags selected")
                                .foregroundColor(.secondary)
                        } else {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack {
                                    ForEach(Array(rule.selectedTagNames), id: \.self) { tagName in
                                        SmartFolderTagChip(tagName: tagName) {
                                            rule.selectedTagNames.remove(tagName)
                                        }
                                    }
                                }
                            }
                        }
                        
                        Button("Select Tags") {
                            showingTagPicker = true
                        }
                    }
                }
                .navigationTitle("Smart Folder")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            dismiss()
                        }
                    }
                    
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Create") {
                            createVirtualFolder()
                        }
                        .disabled(folderName.isEmpty)
                    }
                }
                .sheet(isPresented: $showingTagPicker) {
                    TagSelectionView(selectedTagNames: $rule.selectedTagNames, allTags: allTags)
                }
            }
        }
        
        private func createVirtualFolder() {
            let path = "/Virtual/\(folderName)"
            
            let folder = Folder(
                name: folderName,
                path: path,
                sourceType: .virtual,
                parentFolder: nil,
                rulePayload: nil // Will be set below
            )
            
            folder.setSmartRule(rule)
            
            modelContext.insert(folder)
            do {
                try modelContext.save()
            } catch {
                print("🔍 Failed to save smart folder: \(error)")
            }
            dismiss()
        }
    }
    
    // MARK: - Tag Selection View
    
    struct TagSelectionView: View {
        @Binding var selectedTagNames: Set<String>
        let allTags: [Tag]
        @Environment(\.dismiss) private var dismiss
        
        var body: some View {
            NavigationView {
                List {
                    ForEach(allTags) { tag in
                        HStack {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 12, height: 12)
                            
                            Text(tag.name)
                            
                            Spacer()
                            
                            if selectedTagNames.contains(tag.name) {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedTagNames.contains(tag.name) {
                                selectedTagNames.remove(tag.name)
                            } else {
                                selectedTagNames.insert(tag.name)
                            }
                        }
                    }
                }
                .navigationTitle("Select Tags")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Removable Tag Chip
    
    struct SmartFolderTagChip: View {
        let tagName: String
        let onRemove: () -> Void
        
        var body: some View {
            HStack(spacing: 4) {
                Text(tagName)
                    .font(.caption)
                
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.blue.opacity(0.1))
            .foregroundColor(.blue)
            .cornerRadius(12)
        }
    }

struct ToolsMenuView: View {
    let vm: FoldersViewModel
    let searchService: SearchIndexService
    let modelContext: ModelContext
    @Binding var showingScanConfirmation: Bool
    @Binding var showingPhotoScanConfirmation: Bool
    @Binding var showingEnrichConfirmation: Bool
    @Binding var showingGeocodeConfirmation: Bool
    @Binding var showingFileSizeRecalcConfirmation: Bool
    @Binding var showingHashBackfillConfirmation: Bool
    @Binding var showingBackupConfirmation: Bool
    @Binding var activeFolderPicker: FoldersView.FolderPickerAction?
    @Binding var showingFolderPicker: Bool
    @Binding var pendingScanURL: URL?
    @Binding var pendingEnrichURL: URL?
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List {
                Section("Scanning") {
                    Button("Scan iCloud Drive") {
                        if let url = vm.storedRootURL { 
                            pendingScanURL = url
                            showingScanConfirmation = true
                        } else {
                            activeFolderPicker = .scan
                            showingFolderPicker = true
                        }
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                    
                    Button("Scan Photos Library") {
                        showingPhotoScanConfirmation = true
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                    
                    Button("Change Folder") {
                        activeFolderPicker = .scan
                        showingFolderPicker = true
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                }
                
                Section("Metadata") {
                    Button("Fetch Full Metadata") {
                        if let url = vm.storedRootURL {
                            pendingEnrichURL = url
                            showingEnrichConfirmation = true
                        }
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                    
                    Button("Geocode Locations") {
                        showingGeocodeConfirmation = true
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                    
                    Button("Recalculate File Sizes") {
                        showingFileSizeRecalcConfirmation = true
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                    
                    Button("PhotoFP") {
                        showingHashBackfillConfirmation = true
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                }
                
                Section("Search") {
                    Button("Rebuild Search Index") {
                        Task {
                            await searchService.manualRebuildIndex(modelContext: modelContext)
                        }
                        dismiss()
                    }
                    .disabled(searchService.isRebuildingIndex)
                }
                
                Section("Backup") {
                    Button("Backup Data") {
                        if vm.hasStoredBackupDestination {
                            showingBackupConfirmation = true
                        } else {
                            activeFolderPicker = .backup
                            showingFolderPicker = true
                        }
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                    
                    Button("Restore Backup", role: .destructive) {
                        activeFolderPicker = .restore
                        showingFolderPicker = true
                        dismiss()
                    }
                    .disabled(vm.isBusy)
                }
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    FoldersView()
        .modelContainer(for: [Folder.self, Photo.self], inMemory: true)
}
