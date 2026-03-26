import SwiftUI
import SwiftData
import MapKit
import Photos

// MARK: - Annotation model

final class PhotoAnnotation: NSObject, MKAnnotation {
    let photoFilePath: String
    let photoLocation: PhotoLocation
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(photoLocation: PhotoLocation) {
        self.photoFilePath = photoLocation.photoFilePath
        self.photoLocation = photoLocation
        self.coordinate = CLLocationCoordinate2D(
            latitude: photoLocation.latitude,
            longitude: photoLocation.longitude
        )
    }
}

struct BulkMapTagPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let photoFilePaths: Set<String>

    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var selectedTags: Set<Tag> = []
    @State private var searchText = ""
    @State private var showingAddTag = false
    @State private var showingApplyConfirmation = false

    private var filteredTags: [Tag] {
        if searchText.isEmpty {
            return allTags
        }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Tags") {
                    ForEach(filteredTags) { tag in
                        TagPickerRow(tag: tag, isSelected: selectedTags.contains(tag)) {
                            if selectedTags.contains(tag) {
                                selectedTags.remove(tag)
                            } else {
                                selectedTags.insert(tag)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tag Selected")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search tags...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        showingApplyConfirmation = true
                    }
                    .disabled(selectedTags.isEmpty || photoFilePaths.isEmpty)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddTag = true
                    } label: {
                        Label("New Tag", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddTag) {
                AddTagView()
            }
            .alert("Apply tags?", isPresented: $showingApplyConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Apply") {
                    applyTags()
                }
            } message: {
                Text("Apply \(selectedTags.count) tag(s) to \(photoFilePaths.count) selected photo(s)?")
            }
        }
    }

    private func applyTags() {
        guard !photoFilePaths.isEmpty, !selectedTags.isEmpty else { return }

        let photoDescriptor = FetchDescriptor<Photo>()
        let photos = (try? modelContext.fetch(photoDescriptor)) ?? []
        let targetPhotos = photos.filter { photoFilePaths.contains($0.filePath) }

        for photo in targetPhotos {
            let existingTagIDs = Set(photo.tags.map { ObjectIdentifier($0) })
            for tag in selectedTags where !existingTagIDs.contains(ObjectIdentifier(tag)) {
                let photoTag = PhotoTag(photo: photo, tag: tag)
                modelContext.insert(photoTag)
            }
        }

        try? modelContext.save()
        dismiss()
    }
}

// MARK: - UIViewRepresentable map with clustering

struct ClusteredMapView: UIViewRepresentable {
    struct SelectionBounds {
        let minLat: Double
        let maxLat: Double
        let minLon: Double
        let maxLon: Double
    }

    let annotations: [PhotoAnnotation]
    var initialRegion: MKCoordinateRegion?
    var isSelectionMode: Bool
    var selectedPhotoPaths: Set<String>
    var onSelectPhoto: (Photo) -> Void
    var onAreaSelectionChanged: (SelectionBounds?) -> Void
    var onCenterChanged: ((MKCoordinateRegion) -> Void)?
    var centerTrigger: Int
    weak var modelContext: ModelContext?

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true
        mapView.register(PhotoAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        // Use default cluster annotation view for better performance
        mapView.register(MKMarkerAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        
        // Set initial region if provided
        if let region = initialRegion {
            mapView.setRegion(region, animated: false)
        }

        context.coordinator.mapView = mapView
        let selectionPan = UIPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSelectionPan(_:))
        )
        selectionPan.maximumNumberOfTouches = 1
        selectionPan.delegate = context.coordinator
        mapView.addGestureRecognizer(selectionPan)
        context.coordinator.selectionPanGesture = selectionPan
        
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if let ctx = modelContext {
            context.coordinator.modelContext = ctx
        }
        context.coordinator.isSelectionMode = isSelectionMode
        context.coordinator.selectedPhotoPaths = selectedPhotoPaths
        context.coordinator.onAreaSelectionChanged = onAreaSelectionChanged

        mapView.isScrollEnabled = !isSelectionMode
        mapView.isZoomEnabled = !isSelectionMode
        mapView.isRotateEnabled = !isSelectionMode
        mapView.isPitchEnabled = !isSelectionMode
        context.coordinator.selectionPanGesture?.isEnabled = isSelectionMode
        if !isSelectionMode {
            context.coordinator.clearSelectionOverlay()
        }

        let currentAnnotations = mapView.annotations.compactMap { $0 as? PhotoAnnotation }
        let currentIDs = Set(currentAnnotations.map(\.photoFilePath))
        let newIDs = Set(annotations.map(\.photoFilePath))

        let toRemove = currentAnnotations.filter { !newIDs.contains($0.photoFilePath) }
        if !toRemove.isEmpty {
            mapView.removeAnnotations(toRemove)
        }

        let toAdd = annotations.filter { !currentIDs.contains($0.photoFilePath) }
        if !toAdd.isEmpty {
            mapView.addAnnotations(toAdd)
        }

        context.coordinator.refreshAnnotationStyles(on: mapView)
        
        if context.coordinator.centerTrigger != centerTrigger {
            context.coordinator.centerTrigger = centerTrigger
            fitAll(mapView)
        }
    }

    private func fitAll(_ mapView: MKMapView) {
        guard !annotations.isEmpty else { return }
        mapView.showAnnotations(annotations, animated: true)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSelectPhoto: onSelectPhoto,
            onAreaSelectionChanged: onAreaSelectionChanged,
            onCenterChanged: onCenterChanged
        )
    }

    final class Coordinator: NSObject, MKMapViewDelegate, UIGestureRecognizerDelegate {
        var onSelectPhoto: (Photo) -> Void
        var onAreaSelectionChanged: (SelectionBounds?) -> Void
        var onCenterChanged: ((MKCoordinateRegion) -> Void)?
        var isSelectionMode = false
        var selectedPhotoPaths: Set<String> = []
        var centerTrigger = -1
        private var lastRegion: MKCoordinateRegion?
        private var pendingRegionWorkItem: DispatchWorkItem?
        weak var mapView: MKMapView?
        weak var selectionPanGesture: UIPanGestureRecognizer?
        private var selectionBoxView: UIView?
        private var selectionStartPoint: CGPoint?
        weak var modelContext: ModelContext?

        init(
            onSelectPhoto: @escaping (Photo) -> Void,
            onAreaSelectionChanged: @escaping (SelectionBounds?) -> Void,
            onCenterChanged: ((MKCoordinateRegion) -> Void)?
        ) {
            self.onSelectPhoto = onSelectPhoto
            self.onAreaSelectionChanged = onAreaSelectionChanged
            self.onCenterChanged = onCenterChanged
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)

            if isSelectionMode { return }

            if let photoAnnotation = view.annotation as? PhotoAnnotation {
                // Fetch Photo on-demand by filePath
                if let context = modelContext {
                    let filePath = photoAnnotation.photoFilePath
                    let descriptor = FetchDescriptor<Photo>(
                        predicate: #Predicate { $0.filePath == filePath }
                    )
                    if let photo = try? context.fetch(descriptor).first {
                        onSelectPhoto(photo)
                    }
                }
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                // Zoom into cluster
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            }
        }
        
        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            if isSelectionMode { return }
            let newRegion = mapView.region

            if let last = lastRegion, !isSignificantRegionChange(from: last, to: newRegion) {
                return
            }

            lastRegion = newRegion
            pendingRegionWorkItem?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                self?.onCenterChanged?(newRegion)
            }
            pendingRegionWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isSelectionMode
        }

        @objc func handleSelectionPan(_ gesture: UIPanGestureRecognizer) {
            guard isSelectionMode, let mapView else { return }
            let point = gesture.location(in: mapView)

            switch gesture.state {
            case .began:
                selectionStartPoint = point
                let box = UIView(frame: .zero)
                box.layer.borderWidth = 2
                box.layer.borderColor = UIColor.systemOrange.cgColor
                box.backgroundColor = UIColor.systemOrange.withAlphaComponent(0.12)
                mapView.addSubview(box)
                selectionBoxView = box
                onAreaSelectionChanged(nil)

            case .changed:
                guard let start = selectionStartPoint else { return }
                updateSelectionBox(from: start, to: point)

            case .ended:
                guard let start = selectionStartPoint else { return }
                updateSelectionBox(from: start, to: point)
                finalizeSelection(from: start, to: point, in: mapView)
                selectionStartPoint = nil

            case .cancelled, .failed:
                selectionStartPoint = nil
                clearSelectionOverlay()
                onAreaSelectionChanged(nil)

            default:
                break
            }
        }

        func clearSelectionOverlay() {
            selectionBoxView?.removeFromSuperview()
            selectionBoxView = nil
        }

        private func updateSelectionBox(from start: CGPoint, to current: CGPoint) {
            let rect = CGRect(
                x: min(start.x, current.x),
                y: min(start.y, current.y),
                width: abs(current.x - start.x),
                height: abs(current.y - start.y)
            )
            selectionBoxView?.frame = rect
        }

        private func finalizeSelection(from start: CGPoint, to end: CGPoint, in mapView: MKMapView) {
            let rect = CGRect(
                x: min(start.x, end.x),
                y: min(start.y, end.y),
                width: abs(end.x - start.x),
                height: abs(end.y - start.y)
            )
            guard rect.width >= 14, rect.height >= 14 else {
                onAreaSelectionChanged(nil)
                clearSelectionOverlay()
                return
            }

            let topLeft = CGPoint(x: rect.minX, y: rect.minY)
            let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
            let coordA = mapView.convert(topLeft, toCoordinateFrom: mapView)
            let coordB = mapView.convert(bottomRight, toCoordinateFrom: mapView)

            let bounds = SelectionBounds(
                minLat: min(coordA.latitude, coordB.latitude),
                maxLat: max(coordA.latitude, coordB.latitude),
                minLon: min(coordA.longitude, coordB.longitude),
                maxLon: max(coordA.longitude, coordB.longitude)
            )
            onAreaSelectionChanged(bounds)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation { return nil }

            if let photo = annotation as? PhotoAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier,
                    for: photo
                ) as? MKMarkerAnnotationView
                if let view {
                    configureMarker(view, for: photo)
                    return view
                }
            }

            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier,
                    for: cluster
                ) as? MKMarkerAnnotationView
                if let view {
                    configureMarker(view, for: cluster)
                    return view
                }
            }

            return nil
        }

        func refreshAnnotationStyles(on mapView: MKMapView) {
            for annotation in mapView.annotations where !(annotation is MKUserLocation) {
                if let markerView = mapView.view(for: annotation) as? MKMarkerAnnotationView {
                    configureMarker(markerView, for: annotation)
                }
            }
        }

        private func isSignificantRegionChange(from old: MKCoordinateRegion, to new: MKCoordinateRegion) -> Bool {
            let oldLat = max(old.span.latitudeDelta, 0.0001)
            let oldLon = max(old.span.longitudeDelta, 0.0001)
            let latZoomChange = abs(new.span.latitudeDelta - old.span.latitudeDelta) / oldLat
            let lonZoomChange = abs(new.span.longitudeDelta - old.span.longitudeDelta) / oldLon
            if latZoomChange > 0.08 || lonZoomChange > 0.08 {
                return true
            }

            let oldCenter = CLLocation(latitude: old.center.latitude, longitude: old.center.longitude)
            let newCenter = CLLocation(latitude: new.center.latitude, longitude: new.center.longitude)
            let movedMeters = oldCenter.distance(from: newCenter)
            let viewportMeters = max(new.span.latitudeDelta, new.span.longitudeDelta) * 111_000
            return movedMeters > (viewportMeters * 0.25)
        }

        private func configureMarker(_ view: MKMarkerAnnotationView, for annotation: MKAnnotation) {
            if let photo = annotation as? PhotoAnnotation {
                let selected = isSelectionMode && selectedPhotoPaths.contains(photo.photoFilePath)
                view.markerTintColor = selected ? .systemOrange : .systemBlue
                view.glyphImage = UIImage(systemName: selected ? "checkmark.circle.fill" : "camera.fill")
                return
            }

            if let cluster = annotation as? MKClusterAnnotation {
                let paths = Set(photoPaths(from: cluster))
                let selectedCount = selectedPhotoPaths.intersection(paths).count
                let hasSelection = isSelectionMode && selectedCount > 0
                view.markerTintColor = hasSelection ? .systemOrange : .systemBlue
                view.glyphTintColor = .white
                return
            }
        }

        private func photoPaths(from annotation: MKAnnotation) -> [String] {
            if let photo = annotation as? PhotoAnnotation {
                return [photo.photoFilePath]
            }

            if let cluster = annotation as? MKClusterAnnotation {
                return cluster.memberAnnotations.flatMap { photoPaths(from: $0) }
            }

            return []
        }
    }
}

// MARK: - Annotation views

final class PhotoAnnotationView: MKMarkerAnnotationView {
    static let clusterID = "photos"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = PhotoAnnotationView.clusterID
        
        // Use built-in marker for maximum performance
        markerTintColor = .systemBlue
        glyphImage = UIImage(systemName: "camera.fill")
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Main MapView

struct MapView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var photoLocations: [PhotoLocation] = []
    @State private var selectedPhoto: Photo?
    @State private var centerTrigger = 0
    @State private var cachedAnnotations: [PhotoAnnotation] = []
    @State private var isLoading = false
    @State private var isViewportLoading = false
    @State private var totalGeotaggedCount = 0
    @State private var visibleCount = 0
    @State private var currentRegion: MKCoordinateRegion?
    @State private var initialRegion: MKCoordinateRegion?
    @State private var viewportAnnotationCache: [String: [PhotoAnnotation]] = [:]
    @State private var viewportCacheOrder: [String] = []
    @State private var viewportLoadTask: Task<Void, Never>?
    @State private var areaSelectionTask: Task<Void, Never>?
    @State private var isSelectionMode = false
    @State private var selectedPhotoPaths: Set<String> = []
    @State private var showingBulkTagPicker = false

    private let viewportCacheLimit = 24

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
            EnrichmentBannerView()
            ZStack(alignment: .bottom) {
                ClusteredMapView(
                    annotations: cachedAnnotations,
                    initialRegion: initialRegion,
                    isSelectionMode: isSelectionMode,
                    selectedPhotoPaths: selectedPhotoPaths,
                    onSelectPhoto: { photo in
                        guard !isSelectionMode else { return }
                        withAnimation { selectedPhoto = photo }
                    },
                    onAreaSelectionChanged: { bounds in
                        areaSelectionTask?.cancel()
                        areaSelectionTask = Task {
                            await loadSelectedPhotoPaths(in: bounds)
                        }
                    },
                    onCenterChanged: { region in
                        currentRegion = region
                        viewportLoadTask?.cancel()
                        viewportLoadTask = Task {
                            await loadPhotosInRegion(region)
                        }
                    },
                    centerTrigger: centerTrigger,
                    modelContext: modelContext
                )
                .ignoresSafeArea()

                if let photo = selectedPhoto, !isSelectionMode {
                    PhotoMapPreview(photo: photo, selectedPhoto: $selectedPhoto)
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            } // VStack
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isSelectionMode ? "Done" : "Select Area") {
                        isSelectionMode.toggle()
                        if !isSelectionMode {
                            selectedPhotoPaths.removeAll()
                        } else {
                            selectedPhoto = nil
                        }
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        centerTrigger += 1
                    } label: {
                        Label("Fit All", systemImage: "location.fill")
                    }
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading map...")
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                } else if cachedAnnotations.isEmpty {
                    ContentUnavailableView(
                        "No Location Data",
                        systemImage: "map",
                        description: Text("Scan photos and run Geocode Locations to populate the map")
                    )
                }
            }
            .safeAreaInset(edge: .top) {
                if totalGeotaggedCount > 0 {
                    HStack {
                        Image(systemName: "map.fill")
                        Text("\(visibleCount) visible • \(totalGeotaggedCount) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                    .background(.ultraThinMaterial)
                    .cornerRadius(8)
                    .padding(.horizontal)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelectionMode {
                    VStack(spacing: 8) {
                        Text("Drag on the map to select an area")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 12) {
                            Text("\(selectedPhotoPaths.count) selected")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Clear") {
                                selectedPhotoPaths.removeAll()
                            }
                            .disabled(selectedPhotoPaths.isEmpty)

                            Button {
                                showingBulkTagPicker = true
                            } label: {
                                Label("Tag Selected", systemImage: "tag.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(selectedPhotoPaths.isEmpty)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                }
            }
            .sheet(isPresented: $showingBulkTagPicker) {
                BulkMapTagPickerView(photoFilePaths: selectedPhotoPaths)
            }
            .task {
                await loadInitialData()
            }
        }
    }

    @MainActor
    private func loadInitialData() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            let countDescriptor = FetchDescriptor<PhotoLocation>()
            totalGeotaggedCount = try modelContext.fetchCount(countDescriptor)

            var initialDescriptor = FetchDescriptor<PhotoLocation>()
            initialDescriptor.fetchLimit = 500
            photoLocations = try modelContext.fetch(initialDescriptor)

            if let firstLocation = photoLocations.first {
                let center = CLLocationCoordinate2D(
                    latitude: firstLocation.latitude,
                    longitude: firstLocation.longitude
                )
                initialRegion = MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: 0.9, longitudeDelta: 0.9)
                )
            }

            rebuildAnnotations()
            visibleCount = cachedAnnotations.count

            if let region = initialRegion {
                let tier = zoomTier(for: region.span)
                let key = bucketKey(for: region, tier: tier)
                storeAnnotationsInCache(cachedAnnotations, for: key)
            }

            print("MapView: Loaded initial \(photoLocations.count) photos, total: \(totalGeotaggedCount)")
        } catch {
            print("MapView initial load error: \(error)")
        }
    }
    
    @MainActor
    private func loadPhotosInRegion(_ region: MKCoordinateRegion) async {
        if Task.isCancelled { return }
        guard !isViewportLoading else { return }
        isViewportLoading = true
        defer { isViewportLoading = false }

        let tier = zoomTier(for: region.span)
        let key = bucketKey(for: region, tier: tier)
        if let cached = viewportAnnotationCache[key] {
            cachedAnnotations = cached
            visibleCount = cached.count
            return
        }

        let latDelta = region.span.latitudeDelta
        let lonDelta = region.span.longitudeDelta
        let minLat = region.center.latitude - latDelta / 2
        let maxLat = region.center.latitude + latDelta / 2
        let minLon = region.center.longitude - lonDelta / 2
        let maxLon = region.center.longitude + lonDelta / 2

        var descriptor = FetchDescriptor<PhotoLocation>(
            predicate: #Predicate { location in
                location.latitude >= minLat && location.latitude <= maxLat &&
                location.longitude >= minLon && location.longitude <= maxLon
            }
        )
        descriptor.fetchLimit = tier.fetchLimit

        do {
            let inViewport = try modelContext.fetch(descriptor)
            photoLocations = inViewport
            let annotations = inViewport.map { PhotoAnnotation(photoLocation: $0) }
            cachedAnnotations = annotations
            visibleCount = annotations.count
            storeAnnotationsInCache(annotations, for: key)
        } catch {
            print("MapView viewport load error: \(error)")
        }
    }

    private struct ZoomTier {
        let bucketSize: Double
        let fetchLimit: Int
    }

    private func zoomTier(for span: MKCoordinateSpan) -> ZoomTier {
        let scale = max(span.latitudeDelta, span.longitudeDelta)
        if scale > 80 {
            return ZoomTier(bucketSize: 20, fetchLimit: 220)
        } else if scale > 30 {
            return ZoomTier(bucketSize: 10, fetchLimit: 450)
        } else if scale > 10 {
            return ZoomTier(bucketSize: 5, fetchLimit: 800)
        } else if scale > 3 {
            return ZoomTier(bucketSize: 2, fetchLimit: 1200)
        } else {
            return ZoomTier(bucketSize: 0.75, fetchLimit: 1700)
        }
    }

    private func bucketKey(for region: MKCoordinateRegion, tier: ZoomTier) -> String {
        let latBucket = Int((region.center.latitude / tier.bucketSize).rounded())
        let lonBucket = Int((region.center.longitude / tier.bucketSize).rounded())
        let scaleBucket = Int((max(region.span.latitudeDelta, region.span.longitudeDelta) / tier.bucketSize).rounded())
        return "\(latBucket):\(lonBucket):\(scaleBucket):\(tier.fetchLimit)"
    }

    private func storeAnnotationsInCache(_ annotations: [PhotoAnnotation], for key: String) {
        viewportAnnotationCache[key] = annotations
        viewportCacheOrder.removeAll { $0 == key }
        viewportCacheOrder.append(key)

        while viewportCacheOrder.count > viewportCacheLimit {
            let oldest = viewportCacheOrder.removeFirst()
            viewportAnnotationCache.removeValue(forKey: oldest)
        }
    }

    @MainActor
    private func loadSelectedPhotoPaths(in bounds: ClusteredMapView.SelectionBounds?) async {
        guard let bounds else {
            selectedPhotoPaths.removeAll()
            return
        }

        if Task.isCancelled { return }

        do {
            let minLat = bounds.minLat
            let maxLat = bounds.maxLat
            let minLon = bounds.minLon
            let maxLon = bounds.maxLon
            let descriptor = FetchDescriptor<PhotoLocation>(
                predicate: #Predicate { location in
                    location.latitude >= minLat && location.latitude <= maxLat &&
                    location.longitude >= minLon && location.longitude <= maxLon
                }
            )
            let locations = try modelContext.fetch(descriptor)
            selectedPhotoPaths = Set(locations.map(\.photoFilePath))
        } catch {
            print("MapView area selection error: \(error)")
        }
    }

    private func rebuildAnnotations() {
        cachedAnnotations = photoLocations.map { PhotoAnnotation(photoLocation: $0) }
    }
}

// MARK: - Preview card

struct PhotoMapPreview: View {
    @Environment(\.modelContext) private var modelContext
    let photo: Photo
    @Binding var selectedPhoto: Photo?
    @State private var liveImage: UIImage?
    @State private var cachedImage: UIImage?
    @State private var requestID: PHImageRequestID?

    private var displayImage: UIImage? {
        if let img = cachedImage { return img }
        return liveImage
    }

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let img = displayImage {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.gray.opacity(0.3).overlay(Image(systemName: "photo").foregroundColor(.gray))
                }
            }
            .frame(width: 60, height: 60)
            .cornerRadius(8)
            .onAppear { loadThumbnailIfNeeded() }
            .onDisappear { cancelLoad() }

            VStack(alignment: .leading, spacing: 4) {
                Text(photo.fileName).font(.headline).lineLimit(1)
                if let city = photo.city, let country = photo.country {
                    Text("\(city), \(country)").font(.caption).foregroundStyle(.secondary)
                } else if let country = photo.country {
                    Text(country).font(.caption).foregroundStyle(.secondary)
                } else if let date = photo.captureDate {
                    Text(date.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Spacer()

            NavigationLink(destination: PhotoDetailView(photo: photo)) {
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }

            Button {
                withAnimation { selectedPhoto = nil }
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }

    private func loadThumbnailIfNeeded() {
        let filePath = photo.filePath
        let desc = FetchDescriptor<PhotoThumbnail>(predicate: #Predicate { $0.photoFilePath == filePath })
        if let thumb = try? modelContext.fetch(desc).first {
            cachedImage = UIImage(data: thumb.imageData)
            if cachedImage != nil { return }
        }
        guard PhotoAssetHelper.isPhotosLibraryPhoto(photo) else { return }
        requestID = PhotoAssetHelper.requestThumbnail(
            for: photo, size: CGSize(width: 120, height: 120)
        ) { img in
            if let img { DispatchQueue.main.async { liveImage = img } }
        }
    }

    private func cancelLoad() {
        PhotoAssetHelper.cancelRequest(requestID); requestID = nil
    }
}

#Preview {
    MapView()
        .modelContainer(for: [Photo.self], inMemory: true)
}
