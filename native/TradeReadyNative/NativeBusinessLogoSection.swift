import PhotosUI
import SwiftUI

/// The Business Profile "Logo" section: preview, Add/Change and Remove, matching RN's
/// `SettingsBusinessScreen` logo control. The picked image goes through
/// `AppStore.setBusinessLogo` (512px PNG, local file, reference in `settings.logoPhoto`).
struct NativeBusinessLogoSection: View {
    @EnvironmentObject private var store: AppStore
    @State private var pickerItem: PhotosPickerItem?
    @State private var showingSource = false
    @State private var showingLibrary = false
    @State private var showingCamera = false
    @State private var showingRemoveConfirmation = false
    @State private var failureMessage: String?
    @State private var previewImage: UIImage?
    /// The preview grows with Dynamic Type instead of holding a fixed 72pt box (A16).
    @ScaledMetric(relativeTo: .title2) private var previewSize: CGFloat = 72

    private var reference: String { store.settings.logoPhoto }
    /// A reference that outlives its file (reinstall, another device's path) reads as no logo.
    private var hasLogo: Bool { NativeLogoMedia.fileExists(reference: reference) }

    var body: some View {
        Section {
            HStack(spacing: 16) {
                preview
                VStack(alignment: .leading, spacing: 10) {
                    Button(hasLogo ? "Change logo" : "Add logo") { showingSource = true }
                    if hasLogo {
                        Button(role: .destructive) {
                            showingRemoveConfirmation = true
                        } label: {
                            Text("Remove logo").nativeDestructiveText()
                        }
                    }
                }
                .buttonStyle(.borderless)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .confirmationDialog(hasLogo ? "Change logo" : "Add your logo", isPresented: $showingSource, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo") { showingCamera = true }
                }
                Button("Choose from Library") { showingLibrary = true }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Remove your logo?", isPresented: $showingRemoveConfirmation, titleVisibility: .visible) {
                Button("Remove logo", role: .destructive) { store.removeBusinessLogo() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Estimates and invoices will go out without a logo.")
            }
            .photosPicker(isPresented: $showingLibrary, selection: $pickerItem, matching: .images)
            .onChange(of: pickerItem) { _, item in importPickerItem(item) }
            .sheet(isPresented: $showingCamera) {
                NativeJobCamera { data, _, _ in
                    showingCamera = false
                    apply(data)
                }
                .ignoresSafeArea()
            }
            .alert("Couldn't save that image", isPresented: Binding(
                get: { failureMessage != nil },
                set: { if !$0 { failureMessage = nil } }
            )) {
                Button("OK", role: .cancel) { failureMessage = nil }
            } message: {
                Text(failureMessage ?? "")
            }
            .task(id: reference) { previewImage = loadPreview() }
        } header: {
            Text("LOGO")
        } footer: {
            Text("Shown on estimates, invoices and PDFs. Your logo is stored on this device.")
        }
    }

    @ViewBuilder
    private var preview: some View {
        Group {
            if hasLogo, let previewImage {
                Image(uiImage: previewImage)
                    .resizable()
                    .scaledToFit()
                    .accessibilityLabel("Business logo")
            } else {
                Image(systemName: "photo.badge.plus")
                    .font(.title)
                    .foregroundStyle(Color.tradeReady)
                    .accessibilityLabel("No logo yet")
            }
        }
        .frame(width: previewSize, height: previewSize)
        .background(Color.tradeReady.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func loadPreview() -> UIImage? {
        guard hasLogo, let url = URL(string: reference), let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    private func importPickerItem(_ item: PhotosPickerItem?) {
        guard let item else { return }
        pickerItem = nil
        Task {
            let data = try? await item.loadTransferable(type: Data.self)
            await MainActor.run {
                guard let data else {
                    failureMessage = "That photo couldn't be read. Try another image."
                    return
                }
                apply(data)
            }
        }
    }

    private func apply(_ data: Data) {
        if !store.setBusinessLogo(sourceData: data) {
            failureMessage = "Your logo wasn't changed. Try another image."
        }
    }
}
