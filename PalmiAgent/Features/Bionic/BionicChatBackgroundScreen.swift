import SwiftUI
import PhotosUI
import UIKit

struct BionicWallpaperView: View {
    let archive: BionicArchiveStore
    let instance: String
    let backgroundID: String?
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .systemGroupedBackground)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: backgroundID) {
            guard let backgroundID else { image = nil; return }
            do {
                let data = try await archive.chatBackgroundData(instance, id: backgroundID)
                guard !Task.isCancelled else { return }
                image = data.flatMap { UIImage(data: $0) }
            } catch {
                if !Task.isCancelled { image = nil }
            }
        }
    }
}

struct BionicChatBackgroundScreen: View {
    @Bindable var store: BionicStore
    let instance: String
    let aspect: CGFloat
    @State private var photo: PhotosPickerItem?
    @State private var cropInput: CropInput?
    @State private var loadingPhoto = false
    @State private var saving = false
    private var busy: Bool { loadingPhoto || saving }
    @State private var resetConfirmation = false
    @State private var error: String?

    private struct CropInput: Identifiable {
        let id = UUID()
        let data: Data
        let image: UIImage
    }
    private var safeAspect: CGFloat { min(3, max(0.3, aspect)) }
    private var backgroundID: String? { store.chatPreferences[instance]?.backgroundID }

    var body: some View {
        List {
            if backgroundID != nil {
                Section {
                    BionicWallpaperView(archive: store.archive, instance: instance, backgroundID: backgroundID)
                        .aspectRatio(safeAspect, contentMode: .fit)
                        .frame(maxWidth: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
            }
            Section {
                PhotosPicker(selection: $photo, matching: .images) {
                    Label(PalmiL10n.tr("bionic.chooseBackground"), systemImage: "photo.on.rectangle")
                }
                .disabled(busy)
                if backgroundID != nil {
                    Button(PalmiL10n.tr("bionic.resetBackground")) { resetConfirmation = true }
                        .disabled(busy)
                }
                if busy { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(PalmiL10n.tr("bionic.chatBackground"))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photo) {
            guard let selected = photo, !saving else { return }
            loadingPhoto = true
            defer { loadingPhoto = false }
            do {
                guard let original = try await selected.loadTransferable(type: Data.self) else {
                    throw BionicFailure("invalidImage")
                }
                let normalized = try await BionicBackgroundImageProcessor.shared.prepare(original)
                try Task.checkCancellation()
                guard photo == selected else { return }
                guard let image = UIImage(data: normalized) else { throw BionicFailure("invalidImage") }
                cropInput = CropInput(data: normalized, image: image)
            } catch is CancellationError { }
            catch {
                if !Task.isCancelled { self.error = BionicStore.errorText(error) }
            }
        }
        .sheet(item: $cropInput, onDismiss: { photo = nil }) { input in
            NavigationStack {
                BionicBackgroundCropView(image: input.image, aspect: safeAspect) { rect in
                    save(input.data, rect: rect)
                }
            }
        }
        .confirmationDialog(PalmiL10n.tr("bionic.resetBackground"),
                            isPresented: $resetConfirmation, titleVisibility: .visible) {
            Button(PalmiL10n.tr("bionic.resetBackground"), role: .destructive) {
                guard !busy else { return }
                saving = true
                Task { @MainActor in
                    defer { saving = false }
                    do { try await store.saveChatBackground(instance, data: nil) }
                    catch { self.error = BionicStore.errorText(error) }
                }
            }
        }
        .alert(PalmiL10n.tr("bionic.errorTitle"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button(PalmiL10n.tr("bionic.ok"), role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private func save(_ data: Data, rect: CGRect) {
        guard !saving else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                let cropped = try await BionicBackgroundImageProcessor.shared.crop(data, normalizedRect: rect)
                try await store.saveChatBackground(instance, data: cropped)
            } catch { self.error = BionicStore.errorText(error) }
        }
    }
}

private struct BionicBackgroundCropView: View {
    let image: UIImage
    let aspect: CGFloat
    let onDone: (CGRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var viewport: CGSize = .zero

    private func drawnSize(_ size: CGSize) -> CGSize {
        let factor = max(size.width / image.size.width, size.height / image.size.height) * scale
        return CGSize(width: image.size.width * factor, height: image.size.height * factor)
    }
    private func clamp(_ value: CGSize, in size: CGSize) -> CGSize {
        let drawn = drawnSize(size)
        let x = max(0, (drawn.width - size.width) / 2)
        let y = max(0, (drawn.height - size.height) / 2)
        return CGSize(width: min(x, max(-x, value.width)), height: min(y, max(-y, value.height)))
    }
    private var cropRect: CGRect? {
        guard viewport.width > 0, viewport.height > 0 else { return nil }
        let drawn = drawnSize(viewport)
        let location = clamp(offset, in: viewport)
        return CGRect(
            x: ((drawn.width - viewport.width) / 2 - location.width) / drawn.width,
            y: ((drawn.height - viewport.height) / 2 - location.height) / drawn.height,
            width: viewport.width / drawn.width, height: viewport.height / drawn.height
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let width = min(480, max(1, proxy.size.width - 32))
            let height = min(max(1, proxy.size.height - 32), width / aspect)
            let size = CGSize(width: height * aspect, height: height)
            ZStack {
                Color.black.ignoresSafeArea()
                ZStack {
                    Image(uiImage: image).resizable()
                        .frame(width: drawnSize(size).width, height: drawnSize(size).height)
                        .offset(offset)
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { value in
                    offset = clamp(CGSize(width: lastOffset.width + value.translation.width,
                                          height: lastOffset.height + value.translation.height), in: size)
                }.onEnded { _ in lastOffset = offset })
                .simultaneousGesture(MagnificationGesture().onChanged { value in
                    scale = min(6, max(1, lastScale * value))
                    offset = clamp(offset, in: size)
                }.onEnded { _ in
                    lastScale = scale
                    offset = clamp(offset, in: size)
                    lastOffset = offset
                })
                .overlay { Rectangle().strokeBorder(.white.opacity(0.85), lineWidth: 1).allowsHitTesting(false) }
                .onAppear { viewport = size }
                .onChange(of: size) { _, next in
                    viewport = next
                    offset = clamp(offset, in: next)
                    lastOffset = offset
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(PalmiL10n.tr("bionic.cropBackground"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(PalmiL10n.tr("bionic.cancel")) { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("bionic.useBackground")) {
                    guard let cropRect else { return }
                    onDone(cropRect)
                    dismiss()
                }
                .disabled(cropRect == nil)
            }
        }
    }
}
