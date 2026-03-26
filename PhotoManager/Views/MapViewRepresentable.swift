import SwiftUI
import MapKit
import CoreLocation

// MARK: - Annotation Classes

class PhotoAnnotation: NSObject, MKAnnotation {
    let photoFilePath: String
    let photoFileName: String
    let coordinate: CLLocationCoordinate2D
    let captureDate: Date?
    let city: String?
    let country: String?
    
    init(photo: Photo) {
        self.photoFilePath = photo.filePath
        self.photoFileName = photo.fileName
        self.coordinate = photo.location!.coordinate
        self.captureDate = photo.captureDate
        self.city = photo.city
        self.country = photo.country
        super.init()
    }
    
    var title: String? {
        return photoFileName
    }
    
    var subtitle: String? {
        if let city = city, let country = country {
            return "\(city), \(country)"
        } else if let country = country {
            return country
        }
        return nil
    }
}

class PhotoClusterAnnotation: NSObject, MKClusterAnnotation {
    var memberAnnotations: [MKAnnotation]
    var coordinate: CLLocationCoordinate2D
    
    init(memberAnnotations: [MKAnnotation], coordinate: CLLocationCoordinate2D) {
        self.memberAnnotations = memberAnnotations
        self.coordinate = coordinate
        super.init()
    }
    
    var title: String? {
        return "\(memberAnnotations.count) photos"
    }
    
    var subtitle: String? {
        return nil
    }
}

// MARK: - Custom Annotation View

class PhotoAnnotationView: MKMarkerAnnotationView {
    static let reuseIdentifier = "PhotoAnnotationView"
    static let clusterReuseIdentifier = "PhotoClusterAnnotationView"
    
    private var thumbnailImageView: UIImageView?
    
    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setupView()
    }
    
    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setupView()
    }
    
    private func setupView() {
        markerTintColor = .red
        glyphTintColor = .white
        clusteringIdentifier = "photos"
        displayPriority = .defaultHigh
        collisionMode = .circle
    }
    
    override func prepareForDisplay() {
        super.prepareForDisplay()
        
        if let clusterAnnotation = annotation as? PhotoClusterAnnotation {
            // Cluster styling
            markerTintColor = .systemBlue
            glyphText = "\(clusterAnnotation.memberAnnotations.count)"
            canShowCallout = false
        } else if let photoAnnotation = annotation as? PhotoAnnotation {
            // Single photo styling
            markerTintColor = .red
            glyphText = nil
            canShowCallout = true
            
            // Load thumbnail asynchronously
            loadThumbnail(for: photoAnnotation)
        }
    }
    
    private func loadThumbnail(for annotation: PhotoAnnotation) {
        // Try to load from PhotoThumbnail model
        Task { @MainActor in
            if let thumbnail = await fetchThumbnail(for: annotation.photoFilePath) {
                let imageView = UIImageView(image: UIImage(data: thumbnail))
                imageView.frame = CGRect(x: 0, y: 0, width: 40, height: 40)
                imageView.contentMode = .scaleAspectFill
                imageView.clipsToBounds = true
                imageView.layer.cornerRadius = 4
                self.detailCalloutAccessoryView = imageView
            }
        }
    }
    
    private func fetchThumbnail(for filePath: String) async -> Data? {
        // Access the ModelContainer through the main actor
        // This is a simplified version - in practice you'd want to pass the ModelContext
        return nil
    }
}

// MARK: - UIViewRepresentable Wrapper

struct MapViewRepresentable: UIViewRepresentable {
    let photos: [Photo]
    let initialRegion: MKCoordinateRegion?
    var onAnnotationTapped: ((Photo) -> Void)?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.register(PhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoAnnotationView.reuseIdentifier)
        mapView.register(PhotoAnnotationView.self, forAnnotationViewWithReuseIdentifier: PhotoAnnotationView.clusterReuseIdentifier)
        
        // Enable clustering
        mapView.showsUserLocation = false
        
        // Add annotations
        addAnnotations(to: mapView)
        
        // Set initial region
        if let region = initialRegion {
            mapView.setRegion(region, animated: false)
        } else if let firstPhoto = photos.first, let location = firstPhoto.location {
            let region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )
            mapView.setRegion(region, animated: false)
        }
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Only update if photos changed significantly
        let currentAnnotations = uiView.annotations.compactMap { $0 as? PhotoAnnotation }
        let currentPaths = Set(currentAnnotations.map { $0.photoFilePath })
        let newPaths = Set(photos.compactMap { $0.location != nil ? $0.filePath : nil })
        
        if currentPaths != newPaths {
            uiView.removeAnnotations(uiView.annotations)
            addAnnotations(to: uiView)
        }
    }
    
    private func addAnnotations(to mapView: MKMapView) {
        let annotations = photos.compactMap { photo -> PhotoAnnotation? in
            guard photo.location != nil else { return nil }
            return PhotoAnnotation(photo: photo)
        }
        mapView.addAnnotations(annotations)
        
        // If we have multiple photos, fit the map to show all
        if annotations.count > 1 {
            mapView.showAnnotations(annotations, animated: false)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewRepresentable
        
        init(_ parent: MapViewRepresentable) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }
            
            if let cluster = annotation as? MKClusterAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: PhotoAnnotationView.clusterReuseIdentifier,
                    for: cluster
                ) as! PhotoAnnotationView
                return view
            }
            
            let view = mapView.dequeueReusableAnnotationView(
                withIdentifier: PhotoAnnotationView.reuseIdentifier,
                for: annotation
            ) as! PhotoAnnotationView
            view.clusteringIdentifier = "photos"
            return view
        }
        
        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let photoAnnotation = view.annotation as? PhotoAnnotation {
                if let photo = parent.photos.first(where: { $0.filePath == photoAnnotation.photoFilePath }) {
                    parent.onAnnotationTapped?(photo)
                }
            }
        }
    }
}

// MARK: - Single Photo Map View

struct SinglePhotoMapView: UIViewRepresentable {
    let photo: Photo
    var onTap: (() -> Void)?
    
    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        
        // Configure map appearance
        mapView.mapType = .standard
        mapView.showsUserLocation = false
        
        // Add annotation for this photo
        if let location = photo.location {
            let annotation = PhotoAnnotation(photo: photo)
            mapView.addAnnotation(annotation)
            
            // Set region centered on photo
            let region = MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
            )
            mapView.setRegion(region, animated: false)
        }
        
        // Add tap gesture recognizer
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapGesture)
        
        return mapView
    }
    
    func updateUIView(_ uiView: MKMapView, context: Context) {
        // Update region if needed
        if let location = photo.location {
            let currentCenter = uiView.centerCoordinate
            let newCenter = location.coordinate
            
            // Only update if significantly different (more than 100 meters)
            let currentLoc = CLLocation(latitude: currentCenter.latitude, longitude: currentCenter.longitude)
            let newLoc = CLLocation(latitude: newCenter.latitude, longitude: newCenter.longitude)
            
            if currentLoc.distance(from: newLoc) > 100 {
                let region = MKCoordinateRegion(
                    center: newCenter,
                    span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
                )
                uiView.setRegion(region, animated: true)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: SinglePhotoMapView
        
        init(_ parent: SinglePhotoMapView) {
            self.parent = parent
        }
        
        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                return nil
            }
            
            let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "photo")
            view.markerTintColor = .red
            view.glyphTintColor = .white
            view.canShowCallout = true
            
            return view
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            parent.onTap?()
        }
    }
}
