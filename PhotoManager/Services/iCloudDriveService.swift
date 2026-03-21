import Foundation
import UIKit

actor iCloudDriveService {
    private let fileManager = FileManager.default
    private let supportedImageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "gif", "bmp", "tiff", "tif", "raw", "cr2", "nef", "arw", "dng"]

    func discoverPhotos(in rootURL: URL, progressHandler: @escaping (Int, Int) -> Void) async throws -> [(url: URL, folderPath: String)] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            throw iCloudError.rootNotFound
        }

        let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
            options: [.skipsHiddenFiles]
        )

        guard let enumerator = enumerator else {
            throw iCloudError.enumerationFailed
        }

        var allURLs: [(URL, String)] = []

        while let fileURL = enumerator.nextObject() as? URL {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else { continue }

            let fileExtension = fileURL.pathExtension.lowercased()
            if supportedImageExtensions.contains(fileExtension) {
                let relativePath = fileURL.path.replacingOccurrences(of: rootURL.path + "/", with: "")
                let folderPath = (relativePath as NSString).deletingLastPathComponent
                allURLs.append((fileURL, folderPath))
            }
        }

        let totalFiles = allURLs.count
        var processedFiles = 0
        var photoFiles: [(url: URL, folderPath: String)] = []

        for (url, folderPath) in allURLs {
            photoFiles.append((url: url, folderPath: folderPath))
            processedFiles += 1
            if processedFiles % 10 == 0 || processedFiles == totalFiles {
                progressHandler(processedFiles, totalFiles)
            }
        }

        return photoFiles
    }
    
    private func downloadIfNeeded(url: URL) async throws {
        var isDownloaded = false
        
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus {
            isDownloaded = (status == .current)
        }
        
        if !isDownloaded {
            try fileManager.startDownloadingUbiquitousItem(at: url)
            
            var attempts = 0
            while attempts < 30 {
                try await Task.sleep(nanoseconds: 500_000_000)
                
                if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                   let status = values.ubiquitousItemDownloadingStatus,
                   status == .current {
                    break
                }
                
                attempts += 1
            }
        }
    }
    
    func getFolderStructure(in rootURL: URL) async throws -> [FolderNode] {
        return try await buildFolderTree(at: rootURL, relativePath: "")
    }
    
    private func buildFolderTree(at url: URL, relativePath: String) async throws -> [FolderNode] {
        var folders: [FolderNode] = []
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return folders
        }
        
        for itemURL in contents {
            guard let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                  let isDirectory = resourceValues.isDirectory,
                  isDirectory else {
                continue
            }
            
            let folderName = itemURL.lastPathComponent
            let newRelativePath = relativePath.isEmpty ? folderName : "\(relativePath)/\(folderName)"
            
            let children = try await buildFolderTree(at: itemURL, relativePath: newRelativePath)
            
            let node = FolderNode(
                name: folderName,
                path: newRelativePath,
                children: children
            )
            
            folders.append(node)
        }
        
        return folders.sorted { $0.name < $1.name }
    }
}

struct FolderNode {
    let name: String
    let path: String
    let children: [FolderNode]
}

enum iCloudError: LocalizedError {
    case rootNotFound
    case enumerationFailed

    var errorDescription: String? {
        switch self {
        case .rootNotFound:
            return "Selected folder could not be found. Please select it again."
        case .enumerationFailed:
            return "Failed to enumerate folder contents."
        }
    }
}
