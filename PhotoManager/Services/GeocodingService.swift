import Foundation
import SwiftData
import CoreLocation

@ModelActor
actor GeocodingService {
    private let geocoder = CLGeocoder()

    // Bucket resolution: 2 decimal places ≈ 1.1km precision
    private func locationKey(_ lat: Double, _ lon: Double) -> String {
        String(format: "%.2f,%.2f", lat, lon)
    }

    func geocodePhotos(progressHandler: @escaping (Double, String) -> Void) async -> String? {
        do {
            let descriptor = FetchDescriptor<Photo>(predicate: #Predicate { photo in
                photo.latitude != nil && photo.city == nil
            })
            let pending = try modelContext.fetch(descriptor)
            guard !pending.isEmpty else { return nil }

            // Group photos by location bucket to minimise API calls
            var buckets: [String: [Photo]] = [:]
            for photo in pending {
                guard let lat = photo.latitude, let lon = photo.longitude else { continue }
                let key = locationKey(lat, lon)
                buckets[key, default: []].append(photo)
            }

            let totalBuckets = buckets.count
            let totalPhotos = pending.count
            print("🌍 Geocoding \(totalPhotos) photos via \(totalBuckets) unique locations...")

            var bucketsProcessed = 0
            var photosProcessed = 0

            for (_, group) in buckets {
                guard let representative = group.first,
                      let location = representative.location else { continue }

                let placeName = await reverseGeocodeWithRetry(location)

                for photo in group {
                    photo.city = placeName.city
                    photo.country = placeName.country
                    photosProcessed += 1
                }

                bucketsProcessed += 1
                let progress = Double(bucketsProcessed) / Double(totalBuckets)
                let label = placeName.city ?? placeName.country ?? "Unknown"
                progressHandler(progress, label)

                if bucketsProcessed % 50 == 0 {
                    try? modelContext.save()
                    print("  💾 Geocoded \(bucketsProcessed)/\(totalBuckets) locations (\(photosProcessed) photos)...")
                }

                // Stay well under the 50 req/60s hard limit
                try? await Task.sleep(nanoseconds: 1_300_000_000) // 1.3s between requests
            }

            try? modelContext.save()
            print("✅ Geocoding complete: \(totalBuckets) locations, \(photosProcessed) photos")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private func reverseGeocodeWithRetry(_ location: CLLocation) async -> (city: String?, country: String?) {
        var delay: UInt64 = 1_300_000_000 // 1.3s base
        for attempt in 0..<4 {
            do {
                let placemarks = try await geocoder.reverseGeocodeLocation(location)
                guard let placemark = placemarks.first else { return (nil, nil) }
                return (placemark.locality, placemark.country)
            } catch let error as NSError {
                // kCLErrorDomain code 2 = network error (often throttle); back off and retry
                let isThrottle = error.domain == kCLErrorDomain && error.code == CLError.network.rawValue
                if isThrottle && attempt < 3 {
                    let backoff = delay * UInt64(pow(2.0, Double(attempt)))
                    print("  ⏳ Geocoder throttled, waiting \(backoff / 1_000_000_000)s...")
                    try? await Task.sleep(nanoseconds: backoff)
                } else {
                    return (nil, nil)
                }
            }
        }
        return (nil, nil)
    }
}
