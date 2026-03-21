import Foundation
import SwiftData
import SwiftUI

@Model
final class Tag {
    var name: String
    var colorHex: String
    var createdDate: Date
    var parentTag: Tag?
    
    @Relationship(deleteRule: .cascade, inverse: \Tag.parentTag)
    var childTags: [Tag]
    
    @Relationship(deleteRule: .cascade, inverse: \PhotoTag.tag)
    var photoTags: [PhotoTag]?
    
    init(name: String, colorHex: String = "#007AFF", parentTag: Tag? = nil) {
        self.name = name
        self.colorHex = colorHex
        self.createdDate = Date()
        self.parentTag = parentTag
        self.childTags = []
    }
    
    var color: Color {
        Color(hex: colorHex) ?? .blue
    }
    
    var photos: [Photo] {
        photoTags?.compactMap { $0.photo } ?? []
    }
    
    var fullPath: String {
        var path = [name]
        var current = parentTag
        
        while let parent = current {
            path.insert(parent.name, at: 0)
            current = parent.parentTag
        }
        
        return path.joined(separator: " > ")
    }
    
    var level: Int {
        var count = 0
        var current = parentTag
        
        while current != nil {
            count += 1
            current = current?.parentTag
        }
        
        return count
    }
}

extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        
        var rgb: UInt64 = 0
        
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else {
            return nil
        }
        
        let r = Double((rgb & 0xFF0000) >> 16) / 255.0
        let g = Double((rgb & 0x00FF00) >> 8) / 255.0
        let b = Double(rgb & 0x0000FF) / 255.0
        
        self.init(red: r, green: g, blue: b)
    }
    
    func toHex() -> String? {
        guard let components = UIColor(self).cgColor.components, components.count >= 3 else {
            return nil
        }
        
        let r = Int(components[0] * 255.0)
        let g = Int(components[1] * 255.0)
        let b = Int(components[2] * 255.0)
        
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
