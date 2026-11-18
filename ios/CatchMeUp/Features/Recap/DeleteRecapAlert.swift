import SwiftUI

extension View {
    /// Asks before deleting a recap. Deleting removes the audio file and
    /// tombstones the recap on every synced device, so there is no way back.
    func deleteRecapAlert(_ target: Binding<Recording?>,
                          onDelete: @escaping (Recording) -> Void) -> some View {
        alert("Delete this recap?",
              isPresented: Binding(
                get: { target.wrappedValue != nil },
                set: { if !$0 { target.wrappedValue = nil } }
              ),
              presenting: target.wrappedValue) { recording in
            Button("Delete", role: .destructive) {
                Haptics.warning()
                onDelete(recording)
                target.wrappedValue = nil
            }
            Button("Cancel", role: .cancel) { target.wrappedValue = nil }
        } message: { recording in
            Text("\"\(recording.displayTitle)\" will lose its notes, transcript, audio and study questions on this device and any others using the same iCloud account. This can't be undone.")
        }
    }
}
