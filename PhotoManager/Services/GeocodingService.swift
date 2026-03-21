import Foundation
import SwiftData
import CoreLocation

@ModelActor
actor GeocodingService {
    private let geocoder = CLGeocoder()

    func geocodePhotos(progressHandler: @escaping (Double, String) -> Void) async -> String? {
        do {
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { photo in
                photo.latitude != nil && photo.city == nil
            })
            let pending = try modelContext.fetch(descriptor)
            guard !pending.isEmpty else { return nil }

            let total = pending.count
            print("🌍 Geocoding \(total) photos with GPS coordinates...")

            for (index, photo) in pending.enumerated() {
                guard let location = photo.location else { continue }

                let placeName = await reverseGeocode(location)
                photo.city = placeName.city
                photo.country = placeName.country

                let progress = Double(index + 1) / Double(total)
                let label = placeName.city ?? placeName.country ?? "Unknown"
                progressHandler(progress, label)

                // Save periodically
                if (index + 1) % 50 == 0 {
                    try? modelContext.save()
                    print("  💾 Geocoded \(index + 1)/\(total)...")
                }

                // Rate limit: CLGeocoder allows ~50 requests/min
                try? await Task.sleep(nanoseconds: 80_000_000) // 80ms between requests
            }

            try? modelContext.save()
            print("✅ Geocoding complete: \(total) photos")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func reverseGeocode(_ location: CLLocation) async -> (city: String?, country: String?) {
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(location)
            guard let placemark = placemarks.first else { return (nil, nil) }
            return (placemark.locality, placemark.country)
        } catch {
            return (nil, nil)
        }
    }
}
