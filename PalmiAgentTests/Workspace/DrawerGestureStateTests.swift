import XCTest
@testable import PalmiAgent

final class DrawerGestureStateTests: XCTestCase {
    func testCancelledClosingDoesNotRequestAHistoryResettingBindingWrite() {
        var gesture = DrawerGestureState()
        let id = UUID()
        let configuration = configuration(isOpen: true)
        XCTAssertTrue(gesture.begin(id: id, kind: .close, configuration: configuration))
        gesture.change(id: id, translation: -240, configuration: configuration)

        let completion = gesture.finish(id: id, termination: .cancelled, configuration: configuration)

        XCTAssertNotNil(completion)
        XCTAssertNil(completion?.targetIsOpen)
        XCTAssertNil(gesture.progress)
    }

    func testCancelledOpeningAndFailedRecognitionNeverRequestABindingWrite() {
        var gesture = DrawerGestureState()
        let id = UUID()
        let configuration = configuration()
        XCTAssertNil(gesture.finish(id: id, termination: .cancelled, configuration: configuration))
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration))
        gesture.change(id: id, translation: 350, configuration: configuration)
        XCTAssertNil(gesture.finish(id: id, termination: .cancelled, configuration: configuration)?.targetIsOpen)
        XCTAssertFalse(gesture.isDragging)
    }

    func testNormalReleaseReturningToTheOriginalSideDoesNotWriteTheBinding() {
        for isOpen in [false, true] {
            var gesture = DrawerGestureState()
            let id = UUID()
            let configuration = configuration(isOpen: isOpen)
            XCTAssertTrue(gesture.begin(id: id, kind: isOpen ? .close : .open, configuration: configuration))
            let completion = gesture.finish(id: id, termination: .ended(translation: isOpen ? -80 : 80, velocity: 0),
                                            configuration: configuration)
            XCTAssertNotNil(completion)
            XCTAssertNil(completion?.targetIsOpen)
            XCTAssertFalse(gesture.isDragging)
        }
    }

    func testOpenAndCloseUsePositionAndVelocityInBothLayoutDirections() {
        let cases: [(DrawerGestureState.Direction, Bool, CGFloat, CGFloat, Bool)] = [
            (.leftToRight, false, 240, 0, true),
            (.leftToRight, true, -240, 0, false),
            (.rightToLeft, false, -240, 0, true),
            (.rightToLeft, true, 240, 0, false),
            (.leftToRight, false, 40, 900, true),
            (.leftToRight, true, -40, -900, false),
            (.rightToLeft, false, -40, -900, true),
            (.rightToLeft, true, 40, 900, false)
        ]
        for (direction, isOpen, translation, velocity, expected) in cases {
            var gesture = DrawerGestureState()
            let id = UUID()
            let configuration = configuration(isOpen: isOpen, direction: direction)
            XCTAssertTrue(gesture.begin(id: id, kind: isOpen ? .close : .open, configuration: configuration))
            XCTAssertEqual(gesture.finish(id: id, termination: .ended(translation: translation, velocity: velocity),
                                          configuration: configuration)?.targetIsOpen, expected)
        }
    }

    func testProgressClampsAndReversesRelativeToTheCapturedStartingSide() {
        var gesture = DrawerGestureState()
        let id = UUID()
        let configuration = configuration(isOpen: true)
        XCTAssertTrue(gesture.begin(id: id, kind: .close, configuration: configuration))
        gesture.change(id: id, translation: -800, configuration: configuration)
        XCTAssertEqual(gesture.progress, 0)
        gesture.change(id: id, translation: 200, configuration: configuration)
        XCTAssertEqual(gesture.progress, 1)
        gesture.change(id: id, translation: -100, configuration: configuration)
        XCTAssertEqual(gesture.progress, 0.75)
    }

    func testDeepNavigationCanDisableOpeningWithoutDisablingClosing() {
        var gesture = DrawerGestureState()
        XCTAssertFalse(gesture.begin(id: UUID(), kind: .open,
                                     configuration: configuration(allowsOpeningSwipe: false)))
        XCTAssertTrue(gesture.begin(id: UUID(), kind: .close,
                                    configuration: configuration(isOpen: true, allowsOpeningSwipe: false)))
    }

    func testGestureCannotTakeOwnershipOfTheWrongStartingSideOrAnotherDrag() {
        var gesture = DrawerGestureState()
        XCTAssertFalse(gesture.begin(id: UUID(), kind: .open, configuration: configuration(isOpen: true)))
        XCTAssertFalse(gesture.begin(id: UUID(), kind: .close, configuration: configuration()))
        XCTAssertTrue(gesture.begin(id: UUID(), kind: .open, configuration: configuration()))
        XCTAssertFalse(gesture.begin(id: UUID(), kind: .open, configuration: configuration()))
        XCTAssertEqual(gesture.progress, 0)
    }

    func testZeroNegativeAndNonfiniteWidthsCannotStartADrag() {
        for width: CGFloat in [0, -1, .infinity, .nan] {
            var gesture = DrawerGestureState()
            XCTAssertFalse(gesture.begin(id: UUID(), kind: .open, configuration: configuration(width: width)))
            XCTAssertNil(gesture.progress)
        }
    }

    func testChangedLayoutInvalidatesTheOldGesture() {
        var gesture = DrawerGestureState()
        let id = UUID()
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration()))
        let navigated = configuration(width: 600)
        XCTAssertTrue(gesture.invalidate(ifConfigurationChanged: navigated))
        XCTAssertFalse(gesture.invalidate(ifConfigurationChanged: navigated))
        XCTAssertEqual(gesture.change(id: id, translation: 360, configuration: navigated), .ignored)
        XCTAssertNil(gesture.finish(id: id, termination: .ended(translation: 360, velocity: 800), configuration: navigated))
        XCTAssertNil(gesture.progress)
    }

    func testEndCannotOverwriteExternalOpenStateEvenBeforeTheViewProcessesItsChange() {
        var gesture = DrawerGestureState()
        let id = UUID()
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration()))
        let completion = gesture.finish(id: id, termination: .ended(translation: 0, velocity: -800),
                                       configuration: configuration(isOpen: true))
        XCTAssertNotNil(completion)
        XCTAssertNil(completion?.targetIsOpen)
        XCTAssertFalse(gesture.isDragging)
    }

    func testEndRejectsChangedLayoutBeforeAnInvalidationCallback() {
        var gesture = DrawerGestureState()
        let id = UUID()
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration()))
        let completion = gesture.finish(id: id, termination: .ended(translation: 360, velocity: 800),
                                       configuration: configuration(width: 600))
        XCTAssertNotNil(completion)
        XCTAssertNil(completion?.targetIsOpen)
        XCTAssertFalse(gesture.isDragging)
    }

    func testUnchangedConfigurationKeepsTheActiveDrag() {
        var gesture = DrawerGestureState()
        let id = UUID()
        let configuration = configuration()
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration))
        XCTAssertFalse(gesture.invalidate(ifConfigurationChanged: configuration))
        XCTAssertTrue(gesture.isDragging)
        XCTAssertEqual(gesture.change(id: id, translation: 100, configuration: configuration), .updated)
        XCTAssertEqual(gesture.progress, 0.25)
    }

    func testChangedConfigurationCancelsInsteadOfRebasingTheProgress() {
        let changes = [configuration(width: 600), configuration(width: 0), configuration(direction: .rightToLeft),
                       configuration(allowsOpeningSwipe: false)]
        for changed in changes {
            var gesture = DrawerGestureState()
            let id = UUID()
            XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration()))
            XCTAssertEqual(gesture.change(id: id, translation: 240, configuration: changed), .cancelled)
            XCTAssertFalse(gesture.isDragging)
            XCTAssertNil(gesture.progress)
            XCTAssertNil(gesture.finish(id: id, termination: .ended(translation: 240, velocity: 0), configuration: changed))
        }
    }

    func testStaleEventsCannotFinishAReplacementGesture() {
        var gesture = DrawerGestureState()
        let oldID = UUID()
        let newID = UUID()
        let configuration = configuration()
        XCTAssertTrue(gesture.begin(id: oldID, kind: .open, configuration: configuration))
        XCTAssertTrue(gesture.cancel())
        XCTAssertFalse(gesture.cancel())
        XCTAssertTrue(gesture.begin(id: newID, kind: .open, configuration: configuration))
        XCTAssertEqual(gesture.change(id: oldID, translation: 300, configuration: configuration), .ignored)
        XCTAssertNil(gesture.finish(id: oldID, termination: .cancelled, configuration: configuration))
        XCTAssertTrue(gesture.isDragging)
        XCTAssertEqual(gesture.finish(id: newID, termination: .ended(translation: 300, velocity: 0),
                                     configuration: configuration)?.targetIsOpen, true)
    }

    func testOnlyHorizontalVelocityInTheCorrectDirectionCanBegin() {
        let cases: [(DrawerGestureState.Kind, DrawerGestureState.Direction, CGFloat, CGFloat, Bool)] = [
            (.open, .leftToRight, 100, 10, true), (.close, .leftToRight, -100, 10, true),
            (.open, .rightToLeft, -100, 10, true), (.close, .rightToLeft, 100, 10, true),
            (.open, .leftToRight, -100, 0, false), (.close, .leftToRight, 100, 0, false),
            (.open, .rightToLeft, 100, 0, false), (.close, .rightToLeft, -100, 0, false),
            (.open, .leftToRight, 10, 100, false), (.close, .leftToRight, -10, 100, false),
            (.open, .leftToRight, 100, 100, false), (.close, .leftToRight, 0, 0, false),
            (.open, .leftToRight, .infinity, 0, false), (.close, .leftToRight, -.infinity, 0, false)
        ]
        for (kind, direction, horizontal, vertical, expected) in cases {
            XCTAssertEqual(DrawerGestureState.acceptsInitialVelocity(kind: kind, direction: direction,
                                                                     horizontal: horizontal, vertical: vertical), expected)
        }
    }

    func testNonfiniteSamplesCancelWithoutRequestingABindingWrite() {
        var gesture = DrawerGestureState()
        let id = UUID()
        let configuration = configuration()
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration))
        XCTAssertEqual(gesture.change(id: id, translation: .nan, configuration: configuration), .cancelled)
        XCTAssertNil(gesture.progress)
        XCTAssertTrue(gesture.begin(id: id, kind: .open, configuration: configuration))
        XCTAssertNil(gesture.finish(id: id, termination: .ended(translation: 300, velocity: .infinity),
                                   configuration: configuration)?.targetIsOpen)
        XCTAssertFalse(gesture.isDragging)
    }

    private func configuration(
        isOpen: Bool = false,
        width: CGFloat = 400,
        direction: DrawerGestureState.Direction = .leftToRight,
        allowsOpeningSwipe: Bool = true
    ) -> DrawerGestureState.Configuration {
        .init(isOpen: isOpen, width: width, direction: direction,
              allowsOpeningSwipe: allowsOpeningSwipe)
    }
}
