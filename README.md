# PhotoManager - iOS Photo Management App

A powerful iOS photo manager built with SwiftUI, SwiftData, and iCloud Drive integration that allows you to organize, tag, and browse your photos with advanced metadata viewing capabilities.

## Features

### Phase 1 (Implemented)
- ✅ **iCloud Drive Integration** - Discovers and indexes photos from iCloud Drive
- ✅ **Comprehensive Metadata Extraction** - Extracts EXIF, GPS, IPTC, and TIFF metadata
- ✅ **SwiftData Models** - Photo, Tag, Folder, and PhotoTag junction tables
- ✅ **Hierarchical Tag System** - Unlimited nesting with color coding
- ✅ **Virtual Folders** - Create custom folder structures in addition to iCloud Drive folders
- ✅ **Photo Grid View** - Filterable grid with date range and tag filters
- ✅ **Folder Tree View** - Browse photos by iCloud Drive folder structure
- ✅ **Map View** - View photos by location with interactive map
- ✅ **Search** - Multi-criteria search across filename, description, camera, tags, and location
- ✅ **Photo Detail View** - Comprehensive metadata display with tag management
- ✅ **Initial Indexing** - Background indexing with progress UI
- ✅ **Thumbnail Caching** - Fast photo browsing with cached thumbnails

## Architecture

### Models (SwiftData)
- **Photo** - Stores photo metadata, file references, and relationships
- **Tag** - Hierarchical tag system with color coding
- **Folder** - Supports iCloud Drive, iCloud Photos, and virtual folders
- **PhotoTag** - Junction table for many-to-many photo-tag relationships

### Services
- **iCloudDriveService** - Discovers photos and folder structure from iCloud Drive
- **MetadataExtractor** - Extracts comprehensive metadata from image files
- **IndexingService** - Coordinates initial photo indexing with progress tracking

### Views
- **FoldersView** - Hierarchical folder browser with iCloud Drive and virtual folders
- **PhotosGridView** - Grid view with filtering and search
- **PhotoDetailView** - Detailed photo view with all metadata
- **TagsView** - Tag management with hierarchical display
- **MapView** - Location-based photo browsing
- **SearchView** - Advanced search with multiple criteria
- **IndexingProgressView** - Shows indexing progress on first launch

## Setup Instructions

### Prerequisites
- Xcode 15.0 or later
- iOS 17.0 or later
- iCloud account with iCloud Drive enabled

### Configuration

1. **Open the project in Xcode**
   ```bash
   open PhotoManager.xcodeproj
   ```

2. **Configure iCloud**
   - Select the PhotoManager target
   - Go to "Signing & Capabilities"
   - Add your Apple Developer Team
   - Ensure iCloud capability is enabled
   - Verify the iCloud container identifier matches: `iCloud.com.photomanager.app`
   - Or update it to your own container identifier in:
     - `PhotoManager.entitlements`
     - Project capabilities

3. **Update Bundle Identifier** (if needed)
   - Change `com.photomanager.app` to your own bundle identifier
   - Update in both the project settings and `Info.plist`

4. **Build and Run**
   - Select your target device or simulator
   - Build and run (⌘R)

### First Launch

On first launch, the app will:
1. Request iCloud Drive access
2. Scan your iCloud Drive for photos
3. Extract metadata from each photo
4. Generate thumbnails
5. Build folder structure

This process may take 30-60 minutes for tens of thousands of photos.

## Usage

### Browsing Photos

**Folders Tab**
- Browse photos by iCloud Drive folder structure
- Create virtual folders for custom organization
- View photo count per folder

**Photos Tab**
- View all photos in a grid
- Filter by date range (Today, This Week, This Month, This Year)
- Filter by tags
- Search by filename, description, or keywords

**Map Tab**
- View photos plotted on a map by GPS coordinates
- Tap markers to preview photos
- Navigate to photo details

**Tags Tab**
- View all tags with hierarchical structure
- See photo count per tag
- Browse photos by tag

**Search Tab**
- Search across all metadata
- Filter by search type (All, File Name, Description, Location, Camera, Tags)

### Managing Tags

**Creating Tags**
1. Go to Tags tab
2. Tap "+" button
3. Enter tag name
4. Choose color
5. Optionally select parent tag for hierarchy
6. Tap "Create"

**Adding Tags to Photos**
1. Open photo detail view
2. Tap "Add Tag" in Tags section
3. Select tags from list
4. Tap "Done"

**Tag Autocomplete**
- When adding tags, the app suggests tags based on existing photo keywords

### Creating Virtual Folders

1. Go to Folders tab
2. Tap "+" button
3. Enter folder name
4. Optionally select parent folder
5. Tap "Create"

Note: Virtual folders don't move photos, they're organizational structures stored in the app.

## Metadata Extracted

- **Basic**: Filename, file size, dimensions, orientation
- **Dates**: Capture date, modification date
- **Location**: GPS coordinates, altitude
- **Camera**: Make, model, lens model
- **Settings**: Focal length, aperture, shutter speed, ISO, flash
- **Descriptive**: Description, keywords
- **Raw**: Complete EXIF/IPTC data stored as JSON

## Supported Image Formats

- JPEG (.jpg, .jpeg)
- PNG (.png)
- HEIC/HEIF (.heic, .heif)
- GIF (.gif)
- BMP (.bmp)
- TIFF (.tiff, .tif)
- RAW formats (.raw, .cr2, .nef, .arw, .dng)

## Technical Details

### Data Storage
- SwiftData for metadata and relationships
- Photos remain in iCloud Drive (not duplicated)
- Thumbnails cached in app storage
- Metadata stored locally for fast access

### Performance
- Lazy loading for large photo collections
- Thumbnail generation and caching
- Background indexing
- Efficient SwiftData queries with predicates

### Privacy
- Photos never leave your device
- All processing happens locally
- iCloud Drive access only for your photos
- No external services or analytics

## Future Enhancements (Phase 2 & 3)

- [ ] iCloud Photos (PhotoKit) integration
- [ ] Bulk operations (multi-select, batch tagging)
- [ ] Photo editing capabilities
- [ ] Smart albums and saved searches
- [ ] Duplicate detection
- [ ] Face detection and recognition
- [ ] Auto-tagging based on metadata
- [ ] Export and sharing options
- [ ] Reverse geocoding (coordinates to place names)
- [ ] Timeline view
- [ ] Memory/story generation

## Troubleshooting

**iCloud Drive not available**
- Ensure iCloud Drive is enabled in Settings > [Your Name] > iCloud
- Check that you're signed in with your Apple ID
- Verify iCloud Drive has available storage

**Photos not appearing**
- Check that photos are in iCloud Drive Documents folder
- Ensure photos are downloaded (not cloud-only)
- Verify supported file formats

**Indexing stuck**
- Force quit and restart the app
- Check iCloud Drive connectivity
- Ensure sufficient device storage for thumbnails

**Performance issues**
- Reduce number of photos being indexed at once
- Clear app cache and re-index
- Ensure device has sufficient memory

## License

This project is created for personal use. Modify as needed for your requirements.

## Support

For issues or questions, refer to the code documentation or modify the source code to suit your needs.
