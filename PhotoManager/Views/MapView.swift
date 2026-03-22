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

// MARK: - UIViewRepresentable map with clustering

struct ClusteredMapView: UIViewRepresentable {
    let annotations: [PhotoAnnotation]
    var initialRegion: MKCoordinateRegion?
    var onSelectPhoto: (Photo) -> Void
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
        
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        if let ctx = modelContext {
            context.coordinator.modelContext = ctx
        }
        
        // Only update annotations if count changed (much more efficient)
        let currentCount = mapView.annotations.compactMap { $0 as? PhotoAnnotation }.count
        if currentCount != annotations.count {
            // Remove only PhotoAnnotations, keep user location
            let toRemove = mapView.annotations.compactMap { $0 as? PhotoAnnotation }
            mapView.removeAnnotations(toRemove)
            mapView.addAnnotations(annotations)
        }
        
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
        Coordinator(onSelectPhoto: onSelectPhoto, onCenterChanged: onCenterChanged) 
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectPhoto: (Photo) -> Void
        var onCenterChanged: ((MKCoordinateRegion) -> Void)?
        var centerTrigger = -1
        private var lastRegion: MKCoordinateRegion?
        weak var modelContext: ModelContext?

        init(onSelectPhoto: @escaping (Photo) -> Void, onCenterChanged: ((MKCoordinateRegion) -> Void)?) {
            self.onSelectPhoto = onSelectPhoto
            self.onCenterChanged = onCenterChanged
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)
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
            let newRegion = mapView.region
            
            // Only trigger if region changed significantly (>10% change in span)
            if let last = lastRegion {
                let latChange = abs(newRegion.span.latitudeDelta - last.span.latitudeDelta) / last.span.latitudeDelta
                let lonChange = abs(newRegion.span.longitudeDelta - last.span.longitudeDelta) / last.span.longitudeDelta
                guard latChange > 0.1 || lonChange > 0.1 else { return }
            }
            
            lastRegion = newRegion
            onCenterChanged?(newRegion)
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
    @State private var totalGeotaggedCount = 0
    @State private var visibleCount = 0
    @State private var currentRegion: MKCoordinateRegion?
    @State private var initialRegion: MKCoordinateRegion?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ClusteredMapView(
                    annotations: cachedAnnotations,
                    initialRegion: initialRegion,
                    onSelectPhoto: { photo in
                        withAnimation { selectedPhoto = photo }
                    },
                    onCenterChanged: { region in
                        currentRegion = region
                        Task { await loadPhotosInRegion(region) }
                    },
                    centerTrigger: centerTrigger,
                    modelContext: modelContext
                )
                .ignoresSafeArea()

                if let photo = selectedPhoto {
                    PhotoMapPreview(photo: photo, selectedPhoto: $selectedPhoto)
                        .padding()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
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
            // Load ALL PhotoLocation records - no thumbnails means low memory usage
            let allDescriptor = FetchDescriptor<PhotoLocation>()
            photoLocations = try modelContext.fetch(allDescriptor)
            totalGeotaggedCount = photoLocations.count
            
            // Set initial region to first photo location with 100km radius
            if let firstLocation = photoLocations.first {
                let center = CLLocationCoordinate2D(
                    latitude: firstLocation.latitude,
                    longitude: firstLocation.longitude
                )
                // 100km radius ≈ 0.9 degree span
                initialRegion = MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: 0.9, longitudeDelta: 0.9)
                )
            }
            
            // Create all annotations with simple pins (no thumbnails)
            rebuildAnnotations()
            
            print("MapView: Loaded all \(photoLocations.count) PhotoLocation records with simple pins")
        } catch {
            print("MapView initial load error: \(error)")
        }
    }
    
    @MainActor
    private func loadPhotosInRegion(_ region: MKCoordinateRegion) async {
        // MapKit handles viewport filtering automatically - no need to manually filter
        // Just update the visible count for display
        let latDelta = region.span.latitudeDelta
        let lonDelta = region.span.longitudeDelta
        let minLat = region.center.latitude - latDelta / 2
        let maxLat = region.center.latitude + latDelta / 2
        let minLon = region.center.longitude - lonDelta / 2
        let maxLon = region.center.longitude + lonDelta / 2
        
        let inViewport = photoLocations.filter { location in
            location.latitude >= minLat && location.latitude <= maxLat &&
            location.longitude >= minLon && location.longitude <= maxLon
        }
        
        visibleCount = inViewport.count
        print("MapView: \(inViewport.count) annotations in current viewport")
    }

    private func rebuildAnnotations() {
        cachedAnnotations = photoLocations.map { PhotoAnnotation(photoLocation: $0) }
    }
}

// MARK: - Preview card

struct PhotoMapPreview: View {
    let photo: Photo
    @Binding var selectedPhoto: Photo?
    @State private var liveImage: UIImage?
    @State private var requestID: PHImageRequestID?

    private var displayImage: UIImage? {
        if let d = photo.thumbnailData, let img = UIImage(data: d) { return img }
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
        guard photo.thumbnailData == nil, PhotoAssetHelper.isPhotosLibraryPhoto(photo) else { return }
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
