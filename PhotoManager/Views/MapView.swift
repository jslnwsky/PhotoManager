import SwiftUI
import SwiftData
import MapKit
import Photos

// MARK: - Annotation model

final class PhotoAnnotation: NSObject, MKAnnotation {
    let photo: Photo
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(photo: Photo) {
        self.photo = photo
        self.coordinate = photo.location!.coordinate
    }
}

// MARK: - UIViewRepresentable map with clustering

struct ClusteredMapView: UIViewRepresentable {
    let annotations: [PhotoAnnotation]
    var onSelectPhoto: (Photo) -> Void
    var onCenterChanged: ((MKCoordinateRegion) -> Void)?
    var centerTrigger: Int

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = false
        mapView.register(PhotoAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: MKMapViewDefaultAnnotationViewReuseIdentifier)
        mapView.register(ClusterAnnotationView.self,
                         forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        let existing = Set(mapView.annotations.compactMap { $0 as? PhotoAnnotation }.map { ObjectIdentifier($0) })
        let incoming = Set(annotations.map { ObjectIdentifier($0) })
        if existing != incoming {
            mapView.removeAnnotations(mapView.annotations)
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

    func makeCoordinator() -> Coordinator { Coordinator(onSelectPhoto: onSelectPhoto) }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelectPhoto: (Photo) -> Void
        var centerTrigger = -1

        init(onSelectPhoto: @escaping (Photo) -> Void) {
            self.onSelectPhoto = onSelectPhoto
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            mapView.deselectAnnotation(view.annotation, animated: false)
            if let photoAnnotation = view.annotation as? PhotoAnnotation {
                onSelectPhoto(photoAnnotation.photo)
            } else if let cluster = view.annotation as? MKClusterAnnotation {
                // Zoom into cluster
                mapView.showAnnotations(cluster.memberAnnotations, animated: true)
            }
        }
    }
}

// MARK: - Annotation views

final class PhotoAnnotationView: MKAnnotationView {
    static let clusterID = "photos"
    private let imageView = UIImageView()
    private var requestID: PHImageRequestID?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        clusteringIdentifier = PhotoAnnotationView.clusterID
        frame = CGRect(x: 0, y: 0, width: 36, height: 36)
        layer.cornerRadius = 18
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        layer.masksToBounds = true
        backgroundColor = .systemBlue
        imageView.frame = bounds
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { nil }

    override var annotation: MKAnnotation? {
        didSet { loadThumbnail() }
    }

    private func loadThumbnail() {
        if let id = requestID { PHImageManager.default().cancelImageRequest(id); requestID = nil }
        imageView.image = nil
        guard let photoAnnotation = annotation as? PhotoAnnotation else { return }
        let photo = photoAnnotation.photo

        if let data = photo.thumbnailData, let img = UIImage(data: data) {
            imageView.image = img; return
        }
        guard photo.filePath.hasPrefix("photos://asset/") else { return }
        let identifier = String(photo.filePath.dropFirst("photos://asset/".count))
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .fastFormat
        options.isNetworkAccessAllowed = false
        requestID = PHImageManager.default().requestImage(for: asset,
                                                          targetSize: CGSize(width: 72, height: 72),
                                                          contentMode: .aspectFill,
                                                          options: options) { [weak self] image, _ in
            DispatchQueue.main.async { self?.imageView.image = image }
        }
    }
}

final class ClusterAnnotationView: MKAnnotationView {
    private let label = UILabel()

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        layer.cornerRadius = 22
        layer.borderWidth = 2
        layer.borderColor = UIColor.white.cgColor
        backgroundColor = .systemBlue
        label.textColor = .white
        label.font = .boldSystemFont(ofSize: 14)
        label.textAlignment = .center
        label.frame = bounds
        addSubview(label)
    }

    required init?(coder: NSCoder) { nil }

    override var annotation: MKAnnotation? {
        didSet {
            guard let cluster = annotation as? MKClusterAnnotation else { return }
            label.text = cluster.memberAnnotations.count < 1000
                ? "\(cluster.memberAnnotations.count)"
                : "999+"
        }
    }
}

// MARK: - Main MapView

struct MapView: View {
    @Query private var photos: [Photo]
    @State private var selectedPhoto: Photo?
    @State private var centerTrigger = 0

    var annotations: [PhotoAnnotation] {
        photos.compactMap { $0.location != nil ? PhotoAnnotation(photo: $0) : nil }
    }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                ClusteredMapView(
                    annotations: annotations,
                    onSelectPhoto: { photo in
                        withAnimation { selectedPhoto = photo }
                    },
                    centerTrigger: centerTrigger
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
                if annotations.isEmpty {
                    ContentUnavailableView(
                        "No Location Data",
                        systemImage: "map",
                        description: Text("Scan photos and run Geocode Locations to populate the map")
                    )
                }
            }
        }
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
        guard photo.thumbnailData == nil, photo.filePath.hasPrefix("photos://asset/") else { return }
        let identifier = String(photo.filePath.dropFirst("photos://asset/".count))
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(for: asset,
                                                          targetSize: CGSize(width: 120, height: 120),
                                                          contentMode: .aspectFill,
                                                          options: options) { img, _ in
            if let img = img { DispatchQueue.main.async { liveImage = img } }
        }
    }

    private func cancelLoad() {
        if let id = requestID { PHImageManager.default().cancelImageRequest(id); requestID = nil }
    }
}

#Preview {
    MapView()
        .modelContainer(for: [Photo.self], inMemory: true)
}
