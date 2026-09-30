import Foundation

/// 每个探针样本都带身份标记。来自其他 appearance/角色/最新一条消息的样本一律拒绝。
struct BionicBottomScope: Equatable, Hashable, Sendable {
    let installationID: String
    let presentationID: UUID
    let latestMessageID: String?
    let layoutRevision: UInt64
}

/// 两层证据：最新真实消息行的实时几何优先；懒列表几何估计只作后备。
enum BionicBottomEvidence: Equatable, Sendable {
    case unknown
    case noMessages
    case distance(Double)

    static func measured(lastMessageMaxY: Double, readableBottomY: Double) -> Self {
        guard lastMessageMaxY.isFinite, readableBottomY.isFinite else { return .unknown }
        return .distance(max(0, lastMessageMaxY - readableBottomY))
    }

    /// 仅作后备。避让必须由 inset 表达，不再同时存在一个高透明尾行。
    static func estimated(
        contentHeight: Double, containerHeight: Double,
        topInset: Double, bottomInset: Double, offsetY: Double
    ) -> Self {
        let numbers = [contentHeight, containerHeight, topInset, bottomInset, offsetY]
        guard numbers.allSatisfy(\.isFinite), containerHeight > 1, contentHeight >= 0 else {
            return .unknown
        }
        let minimumOffset = -topInset
        let maximumOffset = max(minimumOffset, contentHeight - containerHeight + bottomInset)
        // 不可滚动内容的橡皮筋回弹不得制造出"回到底部"按钮。
        guard maximumOffset - minimumOffset > 1 else { return .distance(0) }
        return .distance(max(0, maximumOffset - offsetY))
    }
}

/// 箭头显示的纯值策略：位置滞回（>48 显示，≤16 隐藏，之间保持），与未读无关。
/// "箭头隐藏"不等于"自动跟随已重新开启"：重新 follow 需要真实抵达 2pt 以内。
struct BionicBottomPolicy: Equatable, Sendable {
    enum Intent: Equatable, Sendable { case followLatest, readHistory }
    private(set) var scope: BionicBottomScope?
    private(set) var intent: Intent = .followLatest
    private(set) var isActive = false
    private(set) var isUserInteracting = false
    private(set) var showLatestButton = false
    private(set) var distanceToLatest: Double?

    // 本轮产品阈值（pt），不是 Apple 声称的标准值。
    static let showThreshold: Double = 48
    static let hideThreshold: Double = 16
    static let arrivalTolerance: Double = 2

    var latestIsReached: Bool {
        distanceToLatest.map { $0 <= Self.arrivalTolerance } ?? false
    }

    mutating func enter(_ scope: BionicBottomScope, following: Bool) {
        self.scope = scope
        intent = following ? .followLatest : .readHistory
        isActive = true
        isUserInteracting = false
        showLatestButton = false
        distanceToLatest = nil
    }

    /// 新消息/新布局不是一次新访问：按钮保持当前显示，直到重新测量。
    mutating func updateScope(_ next: BionicBottomScope) {
        guard let old = scope,
              old.installationID == next.installationID,
              old.presentationID == next.presentationID else {
            enter(next, following: true)
            return
        }
        guard old != next else { return }
        scope = next
        distanceToLatest = nil
        if next.latestMessageID == nil { showLatestButton = false }
    }

    mutating func leave() {
        isActive = false
        isUserInteracting = false
        showLatestButton = false
        distanceToLatest = nil
        scope = nil
    }

    mutating func beginUserInteraction() {
        isUserInteracting = true
        intent = .readHistory
    }

    mutating func endUserInteraction() {
        isUserInteracting = false
        // 只有真实抵达末尾的证据才重新接上 follow，不是"在 48pt 以内"。
        if latestIsReached { intent = .followLatest }
    }

    mutating func chooseLatest() {
        intent = .followLatest
        // 不在这里隐藏按钮伪造"已到达"。
    }

    mutating func chooseHistory() { intent = .readHistory }

    /// 宿主显式同步跟随意图（用于 store.followingLatest 的投影），不是第二个真相源。
    mutating func setIntent(_ next: Intent) { intent = next }

    mutating func observe(_ evidence: BionicBottomEvidence, scope sampleScope: BionicBottomScope) {
        guard isActive, sampleScope == scope else { return }
        switch evidence {
        case .unknown:
            break
        case .noMessages:
            guard sampleScope.latestMessageID == nil else { return }
            distanceToLatest = 0
            showLatestButton = false
        case .distance(let raw):
            guard raw.isFinite else { return }
            let distance = max(0, raw)
            distanceToLatest = distance
            if distance <= Self.hideThreshold {
                showLatestButton = false
            } else if distance > Self.showThreshold {
                showLatestButton = true
            }
            // (16, 48] 之间保持上一次显示状态（滞回）。
        }
    }
}

/// 按布局合并滚动命令，不按滚动 offset 的每个像素发命令。
struct BionicBottomCommandGate: Equatable, Sendable {
    private(set) var pending = false
    private var lastIssuedLayout: String?
    private var issuedIdleCorrection = false
    private var issuedLayoutCommands = 0
    static let maximumLayoutCommands = 2

    mutating func request() {
        guard !pending else { return }
        pending = true
        lastIssuedLayout = nil
        issuedIdleCorrection = false
        issuedLayoutCommands = 0
    }

    mutating func shouldIssue(layoutKey: String) -> Bool {
        guard pending, lastIssuedLayout != layoutKey,
              issuedLayoutCommands < Self.maximumLayoutCommands else { return false }
        lastIssuedLayout = layoutKey
        issuedLayoutCommands += 1
        return true
    }

    /// idle 后最多一次无动画校正，不是计时器或无限 yield 循环。
    /// 校正是命令的最后一个动作：下发后命令即终止，之后由实际位置决定箭头；
    /// 新的源事件（用户点箭头、发送成功）可以重新 request。
    mutating func shouldCorrectAtIdle() -> Bool {
        guard pending, !issuedIdleCorrection else { return false }
        issuedIdleCorrection = true
        pending = false
        lastIssuedLayout = nil
        issuedLayoutCommands = 0
        issuedIdleCorrection = false
        return true
    }

    mutating func acknowledgeArrival() { cancel() }
    mutating func cancel() {
        pending = false
        lastIssuedLayout = nil
        issuedIdleCorrection = false
        issuedLayoutCommands = 0
    }
}
