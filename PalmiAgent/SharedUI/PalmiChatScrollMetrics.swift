import SwiftUI

struct PalmiChatScrollMetrics: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(_ value: ScrollGeometry) {
        offset = value.contentOffset.y
        contentHeight = value.contentSize.height
        containerHeight = value.containerSize.height
        topInset = value.contentInsets.top
        bottomInset = value.contentInsets.bottom
    }

    var distanceToBottom: CGFloat {
        let lastOffset = max(-topInset, contentHeight - containerHeight + bottomInset)
        return max(0, lastOffset - offset)
    }

    var nearBottom: Bool { distanceToBottom <= 48 }
    var atBottom: Bool { distanceToBottom <= 2 }

    func isUserMovingToOlder(comparedWith previous: Self) -> Bool {
        abs(contentHeight - previous.contentHeight) < 1
            && abs(containerHeight - previous.containerHeight) < 1
            && abs(topInset - previous.topInset) < 1
            && abs(bottomInset - previous.bottomInset) < 1
            && offset < previous.offset - 1
    }
}
