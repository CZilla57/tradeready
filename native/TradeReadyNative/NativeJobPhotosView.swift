import PhotosUI
import SwiftUI
import UIKit

/// Job-photo UI. Metadata and mutations remain owned by AppStore; this view
/// only reads local bytes and hands imported bytes to the Batch 1 APIs.
struct NativeJobPhotosView: View {
    @EnvironmentObject private var store: AppStore
    let jobID: String
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showingCamera = false
    @State private var selectedPhotoID: String?
    @State private var deletePhotoID: String?
    @State private var showingDeleteConfirmation = false
    @State private var errors: [String: String] = [:]
    @State private var importError: String?
    @State private var isTransferring = false
    @State private var refreshID = UUID()

    private var photos: [Canonical.JobPhoto] { store.jobPhotos(for: jobID) }

    var body: some View {
        Section("Photos") {
            if photos.isEmpty {
                ContentUnavailableView("No job photos", systemImage: "photo.on.rectangle", description: Text("Add progress photos from the camera or photo library."))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(photos, id: \.id) { photo in
                            PhotoThumbnail(photo: photo, bytes: store.jobPhotoBytes(photoID: photo.id), error: errors[photo.id]) {
                                selectedPhotoID = photo.id
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .id(refreshID)
                ForEach(photos, id: \.id) { photo in
                    HStack {
                        Label(
                            store.isJobPhotoCustomerVisible(photoID: photo.id) ? "Visible to customer" : "Private",
                            systemImage: store.isJobPhotoCustomerVisible(photoID: photo.id) ? "eye" : "eye.slash"
                        )
                        .font(.subheadline)
                        Spacer()
                        Toggle("", isOn: visibilityBinding(for: photo))
                            .labelsHidden()
                            .accessibilityLabel("Customer visibility")
                        Button(role: .destructive) {
                            deletePhotoID = photo.id
                            showingDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash").nativeDestructiveText()
                        }
                        .accessibilityLabel("Delete photo")
                    }
                    if let error = errors[photo.id] {
                        Text(error).font(.caption).foregroundStyle(Color.tradeDangerText)
                    }
                }
            }
            HStack {
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 10, matching: .images) {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                }
                .onChange(of: pickerItems) { _, items in importLibraryItems(items) }
                Button { showingCamera = true } label: { Label("Camera", systemImage: "camera") }
                    .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
                if photos.contains(where: { store.jobPhotoBytes(photoID: $0.id) == nil }) {
                    Button {
                        isTransferring = true
                        Task {
                            _ = await store.performJobPhotoTransfer()
                            isTransferring = false
                            refreshID = UUID()
                        }
                    } label: {
                        Label(isTransferring ? "Waiting…" : "Retry", systemImage: "arrow.clockwise")
                    }
                    .disabled(isTransferring)
                }
            }
            .buttonStyle(.borderless)
            if let importError {
                Text(importError).font(.caption).foregroundStyle(Color.tradeDangerText)
            }
        }
        .sheet(isPresented: selectedPhotoIsPresented) {
            if let photo = photos.first(where: { $0.id == selectedPhotoID }) {
                NativeJobPhotoViewer(photo: photo, bytes: store.jobPhotoBytes(photoID: photo.id))
            }
        }
        .sheet(isPresented: $showingCamera) {
            NativeJobCamera { data, width, height in
                importPhoto(data, width: width, height: height)
                showingCamera = false
            }
            .ignoresSafeArea()
        }
        .confirmationDialog("Delete this photo?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) {
                guard let photoID = deletePhotoID else { return }
                guard store.deleteJobPhoto(photoID: photoID) else {
                    errors[photoID] = "The photo could not be deleted."
                    return
                }
                errors[photoID] = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This removes the photo from this job and the customer portal.") }
    }

    private var selectedPhotoIsPresented: Binding<Bool> {
        Binding(
            get: { selectedPhotoID != nil },
            set: { if !$0 { selectedPhotoID = nil } }
        )
    }

    private func visibilityBinding(for photo: Canonical.JobPhoto) -> Binding<Bool> {
        Binding(
            get: { store.isJobPhotoCustomerVisible(photoID: photo.id) },
            set: { visible in
                if !store.setJobPhotoVisibility(photoID: photo.id, visible: visible) {
                    errors[photo.id] = "Visibility could not be changed."
                } else {
                    errors[photo.id] = nil
                }
            }
        )
    }

    private func importLibraryItems(_ items: [PhotosPickerItem]) {
        pickerItems = []
        for item in items {
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw PhotoUIError.invalidImage }
                    await MainActor.run { importPhoto(data, width: nil, height: nil) }
                } catch {
                    await MainActor.run { importError = "A selected image could not be read." }
                }
            }
        }
    }

    private func importPhoto(_ data: Data, width: Int?, height: Int?) {
        guard store.createJobPhoto(jobID: jobID, sourceData: data, width: width, height: height) != nil else {
            importError = "The photo could not be saved. Use a smaller image and try again."
            return
        }
        importError = nil
    }
}

private enum PhotoUIError: Error { case invalidImage }

private struct PhotoThumbnail: View {
    let photo: Canonical.JobPhoto
    let bytes: Data?
    let error: String?
    let action: () -> Void
    /// 11.10b A16: the thumbnail grows with Dynamic Type so its "Waiting for
    /// download" caption fits, clamped so a row of photos still shows more
    /// than one on a phone.
    @ScaledMetric(relativeTo: .caption2) private var scaledSide: CGFloat = 112

    private var side: CGFloat { NativeAccessibilityAudit.PhotoThumbnail.side(scaled: scaledSide) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomLeading) {
                if let bytes, let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.12)
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.down.circle").font(.title2)
                        Text("Waiting for download").font(.caption2).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.secondary)
                    .padding(6)
                }
                if error != nil { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.tradeDangerText).padding(7) }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bytes == nil ? "Photo waiting for download" : "Open job photo")
        // 11.10b A17: the red badge is visual only; VoiceOver reads the error.
        .accessibilityValue(error ?? "")
    }
}

private struct NativeJobPhotoViewer: View {
    @Environment(\.dismiss) private var dismiss
    let photo: Canonical.JobPhoto
    let bytes: Data?

    var body: some View {
        NavigationStack {
            Group {
                if let bytes, let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView("Waiting for download", systemImage: "arrow.down.circle", description: Text("This photo is available on another device and will appear after transfer."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }
    }
}

/// Shared camera capture sheet (`UIViewControllerRepresentable`). Module-wide so
/// the receipt flow in `NativeExpenseEditor` reuses it instead of growing a
/// second picker that could drift from this one.
struct NativeJobCamera: UIViewControllerRepresentable {
    let onImage: (Data, Int?, Int?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        picker.cameraCaptureMode = .photo
        return picker
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (Data, Int?, Int?) -> Void
        init(onImage: @escaping (Data, Int?, Int?) -> Void) { self.onImage = onImage }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: 0.85) else { picker.dismiss(animated: true); return }
            onImage(data, Int(image.size.width), Int(image.size.height))
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}
