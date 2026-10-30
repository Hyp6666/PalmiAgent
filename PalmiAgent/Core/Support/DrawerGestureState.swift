import Foundation

/// One drag owns its starting side and layout snapshot until it finishes or is invalidated.
struct DrawerGestureState {
    enum Kind { case open, close }
    enum Direction: Equatable {
        case leftToRight, rightToLeft

        var multiplier: CGFloat { self == .leftToRight ? 1 : -1 }
    }

    struct Configuration: Equatable {
        let isOpen: Bool
        let width: CGFloat
        let direction: Direction
        let allowsOpeningSwipe: Bool

        func canBegin(_ kind: Kind) -> Bool {
            guard width.isFinite, width > 0 else { return false }
            switch kind {
            case .open: return !isOpen && allowsOpeningSwipe
            case .close: return isOpen
            }
        }
    }

    enum ChangeResult { case ignored, updated, cancelled }

    enum Termination {
        case ended(translation: CGFloat, velocity: CGFloat)
        case cancelled
    }

    struct Completion {
        /// nil means return to the current side without calling a potentially side-effecting Binding setter.
        let targetIsOpen: Bool?
    }

    private var session: (id: UUID, configuration: Configuration)?
    private(set) var progress: CGFloat?

    var isDragging: Bool { session != nil }

    mutating func begin(id: UUID, kind: Kind, configuration: Configuration) -> Bool {
        guard session == nil, configuration.canBegin(kind) else { return false }
        session = (id, configuration)
        progress = configuration.isOpen ? 1 : 0
        return true
    }

    @discardableResult
    mutating func change(id: UUID, translation: CGFloat, configuration: Configuration) -> ChangeResult {
        guard let session, session.id == id else { return .ignored }
        guard session.configuration == configuration, translation.isFinite else {
            cancel()
            return .cancelled
        }
        progress = progress(translation: translation, from: session.configuration)
        return .updated
    }

    mutating func finish(id: UUID, termination: Termination, configuration: Configuration) -> Completion? {
        guard let session, session.id == id else { return nil }
        defer { cancel() }
        guard session.configuration == configuration else { return Completion(targetIsOpen: nil) }
        switch termination {
        case .cancelled:
            return Completion(targetIsOpen: nil)
        case .ended(let translation, let velocity):
            guard translation.isFinite, velocity.isFinite else { return Completion(targetIsOpen: nil) }
            let starting = session.configuration
            let current = progress(translation: translation, from: starting)
            // Fast flicks project the position; slow releases settle according to the midpoint.
            let projected = current + starting.direction.multiplier * velocity / starting.width * 0.25
            let target = projected > 0.5
            return Completion(targetIsOpen: target == starting.isOpen ? nil : target)
        }
    }

    @discardableResult
    mutating func cancel() -> Bool {
        let wasDragging = isDragging
        session = nil
        progress = nil
        return wasDragging
    }

    @discardableResult
    mutating func invalidate(ifConfigurationChanged configuration: Configuration) -> Bool {
        guard let session, session.configuration != configuration else { return false }
        return cancel()
    }

    static func acceptsInitialVelocity(kind: Kind, direction: Direction, horizontal: CGFloat, vertical: CGFloat) -> Bool {
        guard horizontal.isFinite, vertical.isFinite, abs(horizontal) > abs(vertical) else { return false }
        let openingVelocity = direction.multiplier * horizontal
        return kind == .open ? openingVelocity > 0 : openingVelocity < 0
    }

    private func progress(translation: CGFloat, from configuration: Configuration) -> CGFloat {
        min(1, max(0, (configuration.isOpen ? 1 : 0) + configuration.direction.multiplier * translation / configuration.width))
    }
}
