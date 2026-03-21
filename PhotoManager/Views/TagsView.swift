import SwiftUI
import SwiftData

struct TagsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var tags: [Tag]
    @State private var showingAddTag = false
    @State private var selectedTag: Tag?
    @State private var searchText = ""
    
    var rootTags: [Tag] {
        tags.filter { $0.parentTag == nil }
    }
    
    var filteredTags: [Tag] {
        if searchText.isEmpty {
            return rootTags
        }
        return tags.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredTags) { tag in
                    NavigationLink(destination: TagDetailView(tag: tag)) {
                        TagRowView(tag: tag)
                    }
                }
                .onDelete(perform: deleteTags)
            }
            .navigationTitle("Tags")
            .searchable(text: $searchText, prompt: "Search tags")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddTag = true
                    } label: {
                        Label("Add Tag", systemImage: "tag.fill")
                    }
                }
            }
            .sheet(isPresented: $showingAddTag) {
                AddTagView()
            }
            .overlay {
                if tags.isEmpty {
                    ContentUnavailableView(
                        "No Tags",
                        systemImage: "tag",
                        description: Text("Create tags to organize your photos")
                    )
                }
            }
        }
    }
    
    private func deleteTags(at offsets: IndexSet) {
        for index in offsets {
            let tag = filteredTags[index]
            modelContext.delete(tag)
        }
        try? modelContext.save()
    }
}

struct TagRowView: View {
    let tag: Tag
    @State private var isExpanded = false
    
    var body: some View {
        if !tag.childTags.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                ForEach(tag.childTags.sorted(by: { $0.name < $1.name })) { child in
                    TagRowView(tag: child)
                }
            } label: {
                TagLabelContent(tag: tag)
            }
        } else {
            TagLabelContent(tag: tag)
        }
    }
}

struct TagLabelContent: View {
    let tag: Tag
    
    var body: some View {
        HStack {
            Circle()
                .fill(tag.color)
                .frame(width: 16, height: 16)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(tag.name)
                    .font(.body)
                
                Text("\(tag.photos.count) photos")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
    }
}

struct TagDetailView: View {
    let tag: Tag
    
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [
                GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 8)
            ], spacing: 8) {
                ForEach(tag.photos) { photo in
                    NavigationLink(destination: PhotoDetailView(photo: photo)) {
                        PhotoThumbnailView(photo: photo)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(tag.fullPath)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tag.photos.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo",
                    description: Text("No photos have this tag yet")
                )
            }
        }
    }
}

struct AddTagView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var tagName = ""
    @State private var selectedColor = Color.blue
    @State private var selectedParent: Tag?
    @Query(sort: \Tag.name) private var allTags: [Tag]
    
    let colorOptions: [Color] = [
        .blue, .red, .green, .orange, .purple, .pink,
        .yellow, .cyan, .mint, .indigo, .teal, .brown
    ]
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Tag Details") {
                    TextField("Tag Name", text: $tagName)
                }
                
                Section("Color") {
                    LazyVGrid(columns: [
                        GridItem(.adaptive(minimum: 44), spacing: 12)
                    ], spacing: 12) {
                        ForEach(colorOptions, id: \.self) { color in
                            Circle()
                                .fill(color)
                                .frame(width: 44, height: 44)
                                .overlay {
                                    if selectedColor == color {
                                        Circle()
                                            .stroke(Color.primary, lineWidth: 3)
                                    }
                                }
                                .onTapGesture {
                                    selectedColor = color
                                }
                        }
                    }
                    .padding(.vertical, 8)
                }
                
                Section("Parent Tag (Optional)") {
                    Picker("Parent", selection: $selectedParent) {
                        Text("None").tag(nil as Tag?)
                        ForEach(allTags) { tag in
                            Text(tag.fullPath).tag(tag as Tag?)
                        }
                    }
                }
            }
            .navigationTitle("New Tag")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        createTag()
                    }
                    .disabled(tagName.isEmpty)
                }
            }
        }
    }
    
    private func createTag() {
        let colorHex = selectedColor.toHex() ?? "#007AFF"
        
        let tag = Tag(
            name: tagName,
            colorHex: colorHex,
            parentTag: selectedParent
        )
        
        modelContext.insert(tag)
        try? modelContext.save()
        dismiss()
    }
}

#Preview {
    TagsView()
        .modelContainer(for: [Tag.self, Photo.self], inMemory: true)
}
