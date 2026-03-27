import SwiftUI
import SwiftData

struct TagPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let photo: Photo
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var searchText = ""
    @State private var selectedTags: Set<Tag> = []
    @State private var showingAddTag = false
    
    var filteredTags: [Tag] {
        if searchText.isEmpty {
            return allTags
        }
        return allTags.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var suggestedTags: [Tag] {
        var suggestions: [Tag] = []
        
        if !photo.keywords.isEmpty {
            for keyword in photo.keywords {
                if let matchingTag = allTags.first(where: { $0.name.lowercased() == keyword.lowercased() }) {
                    if !selectedTags.contains(matchingTag) {
                        suggestions.append(matchingTag)
                    }
                }
            }
        }
        
        return suggestions
    }
    
    var body: some View {
        NavigationStack {
            List {
                if !suggestedTags.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestedTags) { tag in
                            TagPickerRow(tag: tag, isSelected: selectedTags.contains(tag)) {
                                toggleTag(tag)
                            }
                        }
                    }
                }
                
                Section("All Tags") {
                    ForEach(filteredTags) { tag in
                        TagPickerRow(tag: tag, isSelected: selectedTags.contains(tag)) {
                            toggleTag(tag)
                        }
                    }
                }
            }
            .navigationTitle("Add Tags")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search tags...")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        saveTags()
                    }
                }
                
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddTag = true
                    } label: {
                        Label("New Tag", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddTag) {
                AddTagView()
            }
            .onAppear {
                selectedTags = Set(photo.tags)
            }
        }
    }
    
    private func toggleTag(_ tag: Tag) {
        if selectedTags.contains(tag) {
            selectedTags.remove(tag)
        } else {
            selectedTags.insert(tag)
        }
    }
    
    private func saveTags() {
        let currentTags = Set(photo.tags)
        let tagsToAdd = selectedTags.subtracting(currentTags)
        let tagsToRemove = currentTags.subtracting(selectedTags)
        
        for tag in tagsToAdd {
            let photoTag = PhotoTag(photo: photo, tag: tag)
            modelContext.insert(photoTag)
        }
        
        if let photoTags = photo.photoTags {
            for photoTag in photoTags {
                if let tag = photoTag.tag, tagsToRemove.contains(tag) {
                    modelContext.delete(photoTag)
                }
            }
        }
        
        do {
            try modelContext.save()
            SearchIndexService.shared.upsertPhoto(photo)
            dismiss()
        } catch {
            print("Failed to save tags: \(error)")
        }
    }
}

struct TagPickerRow: View {
    let tag: Tag
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack {
                Circle()
                    .fill(tag.color)
                    .frame(width: 16, height: 16)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(tag.name)
                        .foregroundColor(.primary)
                    
                    if tag.level > 0 {
                        Text(tag.fullPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.blue)
                }
            }
        }
    }
}

#Preview {
    TagPickerView(photo: Photo(
        filePath: "/test.jpg",
        fileName: "test.jpg",
        fileSize: 1024000
    ))
    .modelContainer(for: [Photo.self, Tag.self, PhotoTag.self], inMemory: true)
}
