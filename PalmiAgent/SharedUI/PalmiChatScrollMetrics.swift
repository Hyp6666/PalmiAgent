import SwiftUI

struct PalmiChatScrollMetrics: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let bottomInset: CGFloat

    init(_ value: ScrollGeometry) {
        offset = value.contentOffset.y
        contentHeight = value.contentSize.height
        containerHeight = value.containerSize.height
        bottomInset = value.contentInsets.bottom
    }
    var nearBottom: Bool {
        offset + containerHeight >= contentHeight + bottomInset - 70
    }
    func isUserMovingToOlder(comparedWith previous: Self) -> Bool {
        abs(contentHeight - previous.contentHeight) < 1
            && abs(containerHeight - previous.containerHeight) < 1
            && abs(bottomInset - previous.bottomInset) < 1
            && offset < previous.offset - 1
    }
}
