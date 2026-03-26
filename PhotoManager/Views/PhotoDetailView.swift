import SwiftUI
import SwiftData
import MapKit
import Photos

struct PhotoDetailView: View {
    @Environment(\.modelContext) private var modelContext
    let photo: Photo
    @State private var showingTagPicker = false
    @State private var image: UIImage?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(12)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 300)
                }
                
                VStack(alignment: .leading, spacing: 16) {
                    TagSection(photo: photo, showingTagPicker: $showingTagPicker)
                    
                    MetadataSection(photo: photo)
                    
                    if photo.location != nil {
                        LocationSection(photo: photo)
                    }
                    
                    CameraSection(photo: photo)
                    
                    FileInfoSection(photo: photo)
                }
                .padding()
            }
        }
        .navigationTitle(photo.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTagPicker) {
            TagPickerView(photo: photo)
        }
        .task {
            loadFullImage()
        }
    }
    
    private func loadFullImage() {
        Task {
            if PhotoAssetHelper.isPhotosLibraryPhoto(photo) {
                if let img = await PhotoAssetHelper.requestFullImage(for: photo) {
                    await MainActor.run { self.image = img }
                }
            } else {
                if let url = photo.fileURL,
                   let data = try? Data(contentsOf: url),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run { self.image = uiImage }
                }
            }
        }
    }
}

struct TagSection: View {
    let photo: Photo
    @Binding var showingTagPicker: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    showingTagPicker = true
                } label: {
                    Label("Add Tag", systemImage: "plus.circle.fill")
                        .font(.subheadline)
                }
            }
            
            if photo.tags.isEmpty {
                Text("No tags")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                FlowLayout(spacing: 8) {
                    ForEach(photo.tags) { tag in
                        TagChip(tag: tag)
                    }
                }
            }
        }
    }
}

struct TagChip: View {
    let tag: Tag
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(tag.color)
                .frame(width: 8, height: 8)
            
            Text(tag.name)
                .font(.caption)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tag.color.opacity(0.2))
        .cornerRadius(12)
    }
}

struct MetadataSection: View {
    let photo: Photo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Metadata")
                .font(.headline)
            
            if let captureDate = photo.captureDate {
                MetadataRow(label: "Captured", value: formatDate(captureDate))
            }
            
            if let description = photo.photoDescription {
                MetadataRow(label: "Description", value: description)
            }
            
            if !photo.keywords.isEmpty {
                MetadataRow(label: "Keywords", value: photo.keywords.joined(separator: ", "))
            }
            
            if let width = photo.width, let height = photo.height {
                MetadataRow(label: "Dimensions", value: "\(width) × \(height)")
            }
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct LocationSection: View {
    let photo: Photo
    @State private var position: MapCameraPosition
    
    init(photo: Photo) {
        self.photo = photo
        
        if let location = photo.location {
            _position = State(initialValue: .region(MKCoordinateRegion(
                center: location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.1, longitudeDelta: 0.1)
            )))
        } else {
            _position = State(initialValue: .automatic)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location")
                .font(.headline)
            
            if let location = photo.location {
                Map(position: $position) {
                    Marker("Photo Location", coordinate: location.coordinate)
                        .tint(.red)
                }
                .mapStyle(.standard)
                .mapControls {
                    MapPitchToggle()
                }
                .frame(height: 200)
                .cornerRadius(12)
                
                if let city = photo.city, let country = photo.country {
                    MetadataRow(label: "Location", value: "\(city), \(country)")
                } else if let country = photo.country {
                    MetadataRow(label: "Location", value: country)
                }
                
                MetadataRow(label: "Coordinates", value: String(format: "%.6f, %.6f", location.coordinate.latitude, location.coordinate.longitude))
                
                if let altitude = photo.altitude {
                    MetadataRow(label: "Altitude", value: String(format: "%.1f m", altitude))
                }
            }
        }
    }
}

struct CameraSection: View {
    let photo: Photo
    
    var body: some View {
        if photo.cameraMake != nil || photo.cameraModel != nil || photo.lensModel != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Camera")
                    .font(.headline)
                
                if let make = photo.cameraMake, let model = photo.cameraModel {
                    MetadataRow(label: "Camera", value: "\(make) \(model)")
                } else if let model = photo.cameraModel {
                    MetadataRow(label: "Camera", value: model)
                }
                
                if let lens = photo.lensModel {
                    MetadataRow(label: "Lens", value: lens)
                }
                
                if let focal = photo.focalLength {
                    MetadataRow(label: "Focal Length", value: "\(Int(focal))mm")
                }
                
                if let aperture = photo.aperture {
                    MetadataRow(label: "Aperture", value: "f/\(String(format: "%.1f", aperture))")
                }
                
                if let shutter = photo.shutterSpeed {
                    MetadataRow(label: "Shutter Speed", value: formatShutterSpeed(shutter))
                }
                
                if let iso = photo.iso {
                    MetadataRow(label: "ISO", value: "\(iso)")
                }
            }
        }
    }
    
    private func formatShutterSpeed(_ speed: Double) -> String {
        if speed < 1 {
            return "1/\(Int(1/speed))"
        } else {
            return "\(String(format: "%.1f", speed))s"
        }
    }
}

struct FileInfoSection: View {
    let photo: Photo
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("File Info")
                .font(.headline)
            
            MetadataRow(label: "File Name", value: photo.fileName)
            MetadataRow(label: "Size", value: formatFileSize(photo.fileSize))
            
            if !photo.folders.isEmpty {
                MetadataRow(label: photo.folders.count == 1 ? "Folder" : "Folders",
                            value: photo.folders.map(\.name).joined(separator: ", "))
            }
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct MetadataRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .leading)
            
            Text(value)
                .font(.subheadline)
        }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(in: proposal.replacingUnspecifiedDimensions().width, subviews: subviews, spacing: spacing)
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.positions[index].x, y: bounds.minY + result.positions[index].y), proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var positions: [CGPoint] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var x: CGFloat = 0
            var y: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if x + size.width > maxWidth && x > 0 {
                    x = 0
                    y += lineHeight + spacing
                    lineHeight = 0
                }
                
                positions.append(CGPoint(x: x, y: y))
                lineHeight = max(lineHeight, size.height)
                x += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: y + lineHeight)
        }
    }
}

#Preview {
    NavigationStack {
        PhotoDetailView(photo: Photo(
            filePath: "/test.jpg",
            fileName: "test.jpg",
            fileSize: 1024000
        ))
    }
    .modelContainer(for: [Photo.self, Tag.self], inMemory: true)
}
