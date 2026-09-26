import SwiftUI
import PhotosUI
import UIKit

struct BionicUserProfileScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = BionicUserProfileStore.shared
    @State private var name = ""
    @State private var avatar: Data?
    @State private var originalName = ""
    @State private var originalAvatar: Data?
    @State private var loaded = false
    @State private var importing = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var crop: Crop?
    @State private var leaving = false
    @State private var error: String?
    private struct Crop: Identifiable { let id = UUID(); let image: UIImage }
    private var changed: Bool { name != originalName || avatar != originalAvatar }
    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    BionicAvatar(data: avatar, name: name, size: 64)
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Text(PalmiL10n.tr("bionic.chooseAvatar"))
                    }
                    Spacer(minLength: 0)
                    if importing { ProgressView() }
                }
                .padding(.vertical, 8)
                TextField(PalmiL10n.tr("bionic.myName"), text: $name)
                    .textInputAutocapitalization(.never)
                if avatar != nil {
                    Button(PalmiL10n.tr("profile.removeAvatar"), role: .destructive) { avatar = nil }
                }
            }
        }
        .disabled(!loaded || importing)
        .navigationTitle(PalmiL10n.tr("profile.title"))
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(changed || importing)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    if changed { leaving = true } else { dismiss() }
                } label: { Image(systemName: "chevron.left") }
                .disabled(importing)
                .accessibilityLabel(PalmiL10n.tr("common.back"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(PalmiL10n.tr("bionic.save")) { save() }
                    .disabled(!loaded || importing || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .task {
            guard !loaded else { return }
            name = store.displayName; avatar = store.avatarPNG
            originalName = name; originalAvatar = avatar; loaded = true
            error = store.errorMessage
        }
        .task(id: selectedPhoto) {
            guard let photo = selectedPhoto else { return }
            importing = true
            defer { importing = false }
            do {
                guard let bytes = try await photo.loadTransferable(type: Data.self) else { throw BionicFailure("invalidImage") }
                let prepared = try await BionicAttachmentProcessor.shared.prepare(data: bytes, filename: "avatar")
                try Task.checkCancellation()
                guard selectedPhoto == photo, let image = UIImage(data: prepared.data) else { return }
                crop = Crop(image: image)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { self.error = BionicStore.errorText(error) } }
        }
        .sheet(item: $crop, onDismiss: { selectedPhoto = nil }) { value in
            NavigationStack { BionicAvatarCropView(image: value.image) { avatar = $0 } }
        }
        .confirmationDialog(PalmiL10n.tr("bionic.unsavedChanges"), isPresented: $leaving, titleVisibility: .visible) {
            Button(PalmiL10n.tr("bionic.saveAndReturn")) { save() }
            Button(PalmiL10n.tr("bionic.discardAndReturn"), role: .destructive) { dismiss() }
            Button(PalmiL10n.tr("bionic.cancel"), role: .cancel) { }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) { Button(PalmiL10n.tr("bionic.ok"), role: .cancel) { } }
        message: { Text(error ?? "") }
    }
    private func save() {
        do { try store.save(name: name, avatar: avatar); dismiss() }
        catch { self.error = BionicStore.errorText(error) }
    }
}
