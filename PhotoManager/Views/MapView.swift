import SwiftUI
import SwiftData
import MapKit

struct MapView: View {
    @Query private var photos: [Photo]
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 50)
    )
    @State private var selectedPhoto: Photo?
    
    var photosWithLocation: [Photo] {
        photos.filter { $0.location != nil }
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Map(position: .constant(.automatic)) {
                    ForEach(photosWithLocation) { photo in
                        Annotation("", coordinate: photo.location!.coordinate) {
                            Button {
                                selectedPhoto = photo
                            } label: {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue)
                                        .frame(width: 32, height: 32)
                                    
                                    if let thumbnailData = photo.thumbnailData,
                                       let uiImage = UIImage(data: thumbnailData) {
                                        Image(uiImage: uiImage)
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .frame(width: 28, height: 28)
                                            .clipShape(Circle())
                                    } else {
                                        Image(systemName: "photo")
                                            .foregroundColor(.white)
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                    }
                }
                .mapStyle(.standard)
                .ignoresSafeArea()
                
                if let photo = selectedPhoto {
                    PhotoMapPreview(photo: photo, selectedPhoto: $selectedPhoto)
                        .padding()
                        .transition(.move(edge: .bottom))
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        centerMapOnPhotos()
                    } label: {
                        Label("Center", systemImage: "location.fill")
                    }
                }
            }
            .overlay {
                if photosWithLocation.isEmpty {
                    ContentUnavailableView(
                        "No Location Data",
                        systemImage: "map",
                        description: Text("No photos have location information")
                    )
                }
            }
            .onAppear {
                centerMapOnPhotos()
            }
        }
    }
    
    private func centerMapOnPhotos() {
        guard !photosWithLocation.isEmpty else { return }
        
        var minLat = 90.0
        var maxLat = -90.0
        var minLon = 180.0
        var maxLon = -180.0
        
        for photo in photosWithLocation {
            guard let location = photo.location else { continue }
            let coord = location.coordinate
            
            minLat = min(minLat, coord.latitude)
            maxLat = max(maxLat, coord.latitude)
            minLon = min(minLon, coord.longitude)
            maxLon = max(maxLon, coord.longitude)
        }
        
        let centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2
        let spanLat = (maxLat - minLat) * 1.5
        let spanLon = (maxLon - minLon) * 1.5
        
        region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: centerLat, longitude: centerLon),
            span: MKCoordinateSpan(latitudeDelta: max(spanLat, 0.1), longitudeDelta: max(spanLon, 0.1))
        )
    }
}

struct PhotoMapPreview: View {
    let photo: Photo
    @Binding var selectedPhoto: Photo?
    
    var body: some View {
        HStack(spacing: 12) {
            if let thumbnailData = photo.thumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 60, height: 60)
                    .cornerRadius(8)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(photo.fileName)
                    .font(.headline)
                    .lineLimit(1)
                
                if let date = photo.captureDate {
                    Text(formatDate(date))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            NavigationLink(destination: PhotoDetailView(photo: photo)) {
                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            
            Button {
                withAnimation {
                    selectedPhoto = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(12)
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    MapView()
        .modelContainer(for: [Photo.self], inMemory: true)
}
