import SwiftUI

struct IndexingProgressView: View {
    @Binding var progress: Double
    
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
            
            VStack(spacing: 20) {
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .frame(width: 250)
                    .tint(.blue)
                
                Text("Indexing Photos...")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("\(Int(progress * 100))%")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(30)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

#Preview {
    IndexingProgressView(progress: .constant(0.5))
}
