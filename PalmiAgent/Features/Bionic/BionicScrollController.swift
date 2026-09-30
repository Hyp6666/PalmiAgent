import SwiftUI
import UIKit

/// 仿生聊天页的单一滚动执行器：拥有 policy、commandGate、最新几何与命令生命周期。
/// 只在 showLatestButton 或跟随意图变化时更新对应的小视图，不把实时距离发布给整页。
@MainActor @Observable
final class BionicScrollController {
    private(set) var showsLatestButton = false
    private(set) var isFollowingLatest = true

    @ObservationIgnored private var policy = BionicBottomPolicy()
    @ObservationIgnored private var commandGate = BionicBottomCommandGate()
    @ObservationIgnored private var scope: BionicBottomScope?
    @ObservationIgnored private var latestGeometry: ScrollGeometry?
    @ObservationIgnored private var layoutRevision: UInt64 = 0
    @ObservationIgnored private var latestMessageMaxYInScrollView: CGFloat?
    @ObservationIgnored private var readableBottom: CGFloat?
    @ObservationIgnored private var scheduledScroll: Task<Void, Never>?
    @ObservationIgnored private var proxyHolder: ScrollViewProxy?

    var latestIsReached: Bool { policy.latestIsReached }
    var hasPendingCommand: Bool { commandGate.pending }

    func bind(proxy: ScrollViewProxy) {
        proxyHolder = proxy
        schedulePendingScroll()
    }

    func observeReadableBottom(_ value: CGFloat) {
        readableBottom = value
        recomputeEvidence()
    }

    func setFollowingLatest(_ following: Bool) {
        policy.setIntent(following ? .followLatest : .readHistory)
        if !following { commandGate.cancel() }
        syncPublished()
    }

    // MARK: 生命周期

    /// 每次进入角色视图创建新的 presentationID；退出时取消命令和旧 probe。
    func enterRole(installationID: String, followingLatest: Bool) {
        layoutRevision &+= 1
        let scopeValue = BionicBottomScope(
            installationID: installationID,
            presentationID: UUID(),
            latestMessageID: nil,
            layoutRevision: layoutRevision
        )
        policy.enter(scopeValue, following: followingLatest)
        scope = scopeValue
        commandGate.cancel()
        syncPublished()
    }

    func leaveRole() {
        scheduledScroll?.cancel()
        scheduledScroll = nil
        policy.leave()
        scope = nil
        commandGate.cancel()
        latestMessageMaxYInScrollView = nil
        latestGeometry = nil
        syncPublished()
    }

    private func syncPublished() {
        let button = policy.showLatestButton
        if showsLatestButton != button { showsLatestButton = button }
        let following = policy.intent == .followLatest
        if isFollowingLatest != following { isFollowingLatest = following }
    }

    // MARK: 几何证据

    /// 最新一条真实消息行在 全局坐标中的 maxY（零布局占用的探针回调）。
    func observeLatestRow(maxY: CGFloat?) {
        latestMessageMaxYInScrollView = maxY
        recomputeEvidence()
    }

    /// ScrollView 几何变化（同一坐标系的 contentOffset/contentSize/insets）。
    func observeScrollGeometry(_ geometry: ScrollGeometry) {
        latestGeometry = geometry
        recomputeEvidence()
        schedulePendingScroll()
    }

    /// 布局结构变化（宽度、输入区高度、safe area、loadOlder prepend）推进 revision。
    func invalidateLayout() {
        layoutRevision &+= 1
        guard let current = scope else { return }
        let next = BionicBottomScope(
            installationID: current.installationID,
            presentationID: current.presentationID,
            latestMessageID: current.latestMessageID,
            layoutRevision: layoutRevision
        )
        policy.updateScope(next)
        scope = next
    }

    /// 最新消息变化（追加、jump、窗口替换）。
    func updateLatestMessage(_ id: String?, following: Bool?) {
        guard let current = scope else { return }
        let next = BionicBottomScope(
            installationID: current.installationID,
            presentationID: current.presentationID,
            latestMessageID: id,
            layoutRevision: layoutRevision
        )
        policy.updateScope(next)
        if let following { policy.setIntent(following ? .followLatest : .readHistory) }
        scope = next
        syncPublished()
    }

    private func recomputeEvidence() {
        guard let scope else { return }
        // 优先最新真实行的实时几何；它比 LazyVStack contentSize 的估计更能说明屏幕上是否还有消息。
        if let rowMaxY = latestMessageMaxYInScrollView, let readableBottom {
            policy.observe(
                .measured(lastMessageMaxY: Double(rowMaxY), readableBottomY: Double(readableBottom)),
                scope: scope
            )
        } else if let geometry = latestGeometry {
            // 后备：同一 ScrollView 的几何估计，只在没有新鲜实际行证据时使用。
            policy.observe(
                .estimated(
                    contentHeight: Double(geometry.contentSize.height),
                    containerHeight: Double(geometry.containerSize.height),
                    topInset: Double(geometry.contentInsets.top),
                    bottomInset: Double(geometry.contentInsets.bottom),
                    offsetY: Double(geometry.contentOffset.y)
                ),
                scope: scope
            )
        }
        syncPublished()
    }

    // MARK: 用户交互

    func beginUserInteraction() {
        policy.beginUserInteraction()
        commandGate.cancel()
        syncPublished()
    }

    func endUserInteraction() {
        policy.endUserInteraction()
        syncPublished()
    }

    func userScrolledToOlder() {
        policy.chooseHistory()
        commandGate.cancel()
        syncPublished()
    }

    // MARK: 滚动命令

    /// 点击箭头：只发出滚动到末尾的意图，不加载消息、不清未读、不伪造到达。
    func chooseLatest() {
        policy.chooseLatest()
        requestBottom()
        syncPublished()
    }

    /// follow 意图下的自动到底（新消息追加、首次有效展示、输入区变化）。
    func requestBottom() {
        guard policy.intent == .followLatest else { return }
        commandGate.request()
        schedulePendingScroll()
    }

    private func schedulePendingScroll() {
        guard commandGate.pending, scheduledScroll == nil else { return }
        scheduledScroll = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self else { return }
            self.scheduledScroll = nil
            self.issuePendingScroll()
        }
    }

    private func issuePendingScroll() {
        guard proxyHolder != nil, let geometry = latestGeometry else { return }
        let layoutKey = "\(layoutRevision):\(geometry.contentSize.height):\(geometry.containerSize.height)"
        if commandGate.shouldIssue(layoutKey: layoutKey) {
            scrollToBottom(animated: false)
        }
    }

    func shouldCorrectAtIdle() -> Bool {
        commandGate.shouldCorrectAtIdle()
    }

    /// 新鲜终点几何 actualDistance ≤ 2pt 时确认到达；禁止 scrollTo 后立即调用。
    func acknowledgeArrivalIfReached() {
        if policy.latestIsReached { commandGate.acknowledgeArrival() }
    }

    func cancelCommands() { commandGate.cancel() }

    var isReadingHistory: Bool { policy.intent == .readHistory }

    // MARK: 执行

    /// 回到底部：用 scrollTo(anchor: .bottom)，不依赖"懒列表尚未物化的最后行 ID + yield"。
    func scrollToBottom(animated: Bool) {
        proxyHolder?.scrollTo("bionic-end", anchor: .bottom)
    }

    /// 定位消息使用同一个执行器；引用定位是明确的历史阅读意图。
    func scrollTarget(_ id: String) {
        proxyHolder?.scrollTo(id, anchor: .top)
        policy.chooseHistory()
        syncPublished()
    }
}
