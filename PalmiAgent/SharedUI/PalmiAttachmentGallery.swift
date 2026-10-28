import SwiftUI
import UIKit

struct PalmiAttachmentGallery: View {
    enum Presentation: Equatable { case composer, message }
    let attachments: [PalmiChatAttachment]
    let presentation: Presentation
    var composerIsFocused = false
    let resolvedURL: (PalmiChatAttachment) -> URL?
    let onTap: (PalmiChatAttachment) -> Void
    var onRemove: ((PalmiChatAttachment) -> Void)? = nil

    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var availableWidth: CGFloat = 300
    @State private var keyboardVisible = false
    @ScaledMetric(relativeTo: .subheadline) private var fileRowHeight: CGFloat = 76
    private let gap: CGFloat = 8

    private var images: [PalmiChatAttachment] {
        attachments.filter { $0.source != .filePicker || PalmiFilePresentation.resolve(name: $0.name).isRasterImage }
    }
    private var files: [PalmiChatAttachment] {
        attachments.filter { $0.source == .filePicker && !PalmiFilePresentation.resolve(name: $0.name).isRasterImage }
    }
    private var cellSide: CGFloat { max(44, (availableWidth - gap * 2) / 3) }
    private var imageRows: Int { (images.count + 2) / 3 }
    private var imageContentHeight: CGFloat {
        imageRows == 0 ? 0 : CGFloat(imageRows) * cellSide + CGFloat(imageRows - 1) * gap
    }
    private var contentHeight: CGFloat {
        let fileHeight = CGFloat(files.count) * fileRowHeight + CGFloat(max(0, files.count - 1)) * gap
        return imageContentHeight + fileHeight + (!images.isEmpty && !files.isEmpty ? 10 : 0)
    }
    private var viewportHeight: CGFloat {
        // Three columns, at most three rows visible; all fifteen attachments remain reachable.
        let normalLimit = min(360, images.isEmpty ? fileRowHeight * 3 + gap * 2 : cellSide * 3 + gap * 2)
        let compact = verticalSizeClass == .compact
        let limit: CGFloat
        if presentation == .composer && (composerIsFocused || keyboardVisible || compact) {
            limit = min(normalLimit, compact ? 148 : 190)
        } else {
            limit = normalLimit
        }
        return min(contentHeight, limit)
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if !images.isEmpty {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: gap), count: 3),
                              alignment: .leading, spacing: gap) {
                        ForEach(images) { attachment in
                            PalmiAttachmentImageTile(
                                attachment: attachment,
                                url: resolvedURL(attachment),
                                side: cellSide,
                                onTap: { onTap(attachment) },
                                onRemove: onRemove.map { action in { action(attachment) } }
                            )
                        }
                    }
                }
                if !files.isEmpty {
                    LazyVStack(spacing: gap) {
                        ForEach(files) { attachment in
                            PalmiAttachmentFileCard(
                                attachment: attachment,
                                url: resolvedURL(attachment),
                                minimumHeight: fileRowHeight,
                                onTap: { onTap(attachment) },
                                onRemove: onRemove.map { action in { action(attachment) } }
                            )
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.visible)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: max(0, viewportHeight))
        .frame(maxWidth: 360, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { proxy in
            max(148, min(360, proxy.size.width))
        } action: { availableWidth = $0 }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
        .accessibilityElement(children: .contain)
    }
}

private struct PalmiAttachmentImageTile: View {
    let attachment: PalmiChatAttachment
    let url: URL?
    let side: CGFloat
    let onTap: () -> Void
    let onRemove: (() -> Void)?
    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var failed = false

    private var pixelSize: Int { Int(ceil(side * displayScale)) }
    private var requestID: String { "\(attachment.id)|\(url?.path ?? "")|\(pixelSize)" }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                ZStack {
                    Color(uiColor: .secondarySystemBackground)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(width: side, height: side)
                    } else if failed {
                        VStack(spacing: 4) {
                            PalmiFileIcon(name: attachment.name, size: 34)
                            Text(PalmiL10n.tr("attachment.previewUnavailable"))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(6)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PalmiL10n.tr("attachment.openOriginal", attachment.name))

            if let onRemove {
                PalmiAttachmentRemoveButton(onRemove: onRemove)
            }
        }
        .frame(width: side, height: side)
        .task(id: requestID) {
            thumbnail = nil
            failed = false
            guard let url else { failed = true; return }
            let result = await PalmiAttachmentThumbnailStore.shared.thumbnail(url: url, maxPixel: pixelSize)
            guard !Task.isCancelled else { return }
            if let result {
                thumbnail = UIImage(cgImage: result.cgImage)
            } else {
                failed = true
            }
        }
    }
}

private struct PalmiAttachmentFileCard: View {
    let attachment: PalmiChatAttachment
    let url: URL?
    let minimumHeight: CGFloat
    let onTap: () -> Void
    let onRemove: (() -> Void)?
    @State private var byteCount: Int64?

    private var descriptor: PalmiFilePresentation { .resolve(name: attachment.name) }
    private var subtitle: String {
        guard let byteCount else { return descriptor.label }
        return descriptor.label + " · " + ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 10) {
                    PalmiFileIcon(presentation: descriptor, size: 38)
                    VStack(alignment: .leading, spacing: 4) {
                        Text((attachment.name as NSString).lastPathComponent)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .multilineTextAlignment(.leading)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 10)
                .padding(.trailing, onRemove == nil ? 10 : 0)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(attachment.name + ", " + subtitle)
            if let onRemove {
                PalmiAttachmentRemoveButton(onRemove: onRemove, dark: false)
                    .padding(.trailing, 2)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.75)
                .allowsHitTesting(false)
        }
        .task(id: url) {
            byteCount = nil
            guard let url else { return }
            let count = await Task.detached(priority: .utility) { () -> Int64? in
                guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
                return Int64(size)
            }.value
            guard !Task.isCancelled else { return }
            byteCount = count
        }
    }
}

private struct PalmiAttachmentRemoveButton: View {
    let onRemove: () -> Void
    var dark = true

    var body: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(dark ? Color.white : Color.secondary)
                .frame(width: 25, height: 25)
                .background(dark ? Color.black.opacity(0.56) : Color.primary.opacity(0.06), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(PalmiL10n.tr("attachment.remove"))
    }
}
