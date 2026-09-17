import SwiftUI
import UIKit

// 头像圆形裁剪：在圆形取景框内拖动、双指缩放图片，确认后输出 256×256 PNG。
struct BionicAvatarCropView: View {
    let image: UIImage
    let onDone: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var viewSide: CGFloat = 0

    private func drawnSize(_ side: CGFloat) -> CGSize {
        let base = max(side / image.size.width, side / image.size.height) * scale
        return CGSize(width: image.size.width * base, height: image.size.height * base)
    }
    private func clamped(_ value: CGSize, side: CGFloat) -> CGSize {
        let drawn = drawnSize(side)
        let maxX = max(0, (drawn.width - side) / 2), maxY = max(0, (drawn.height - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, value.width)), height: min(maxY, max(-maxY, value.height)))
    }
    private func render() -> Data? {
        let side = viewSide > 0 ? viewSide : 256
        let factor = 256 / side
        let drawn = drawnSize(side)
        let rect = CGRect(x: (side / 2 + offset.width) * factor - drawn.width * factor / 2,
                          y: (side / 2 + offset.height) * factor - drawn.height * factor / 2,
                          width: drawn.width * factor, height: drawn.height * factor)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let output = UIGraphicsImageRenderer(size: CGSize(width: 256, height: 256), format: format).image { _ in
            UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 256, height: 256))
            image.draw(in: rect)
        }
        return output.pngData()
    }
    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width - 32, 420)
            ZStack {
                Color.black.ignoresSafeArea()
                VStack {
                    Spacer()
                    ZStack {
                        Image(uiImage: image).resizable()
                            .frame(width: drawnSize(side).width, height: drawnSize(side).height)
                            .offset(offset)
                    }
                    .frame(width: side, height: side)
                    .clipped()
                    .contentShape(Rectangle())
                    .gesture(DragGesture().onChanged { value in
                        offset = clamped(CGSize(width: lastOffset.width + value.translation.width,
                                                height: lastOffset.height + value.translation.height), side: side)
                    }.onEnded { _ in lastOffset = offset })
                    .simultaneousGesture(MagnificationGesture().onChanged { value in
                        scale = min(8, max(1, lastScale * value))
                        offset = clamped(offset, side: side)
                    }.onEnded { _ in
                        lastScale = scale; offset = clamped(offset, side: side); lastOffset = offset
                    })
                    .overlay {
                        Color.black.opacity(0.55)
                            .mask(Rectangle().overlay { Circle().blendMode(.destinationOut) }.compositingGroup())
                            .allowsHitTesting(false)
                    }
                    .overlay { Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5).allowsHitTesting(false) }
                    .onAppear { viewSide = side }
                    Spacer()
                }
            }
        }
        .navigationTitle(PalmiL10n.tr("bionic.cropTitle"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button(PalmiL10n.tr("bionic.cancel")) { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(PalmiL10n.tr("bionic.done")) {
                    if let data = render() { onDone(data) }
                    dismiss()
                }
            }
        }
    }
}
