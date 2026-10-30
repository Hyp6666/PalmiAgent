import XCTest
@testable import PalmiAgent

@MainActor
final class AppShellNavigationTests: XCTestCase {
    private let modes: [AppShellMode] = [.chat, .professional, .bionic]

    func testSuccessfulNavigationCommitsModeOnlyAfterActivation() {
        for previous in modes {
            for target in modes {
                for isOpen in [false, true] {
                    let navigation = AppShellNavigation(mode: previous)
                    navigation.isDrawerOpen = isOpen
                    var activationCount = 0

                    XCTAssertTrue(navigation.navigate(to: target) {
                        activationCount += 1
                        XCTAssertEqual(navigation.mode, previous, "存储层切换成功前不提交模式")
                        return true
                    })

                    XCTAssertEqual(activationCount, 1)
                    XCTAssertEqual(navigation.mode, target)
                    XCTAssertFalse(navigation.isDrawerOpen, "打开会话、新会话后收起侧栏")
                }
            }
        }
    }

    func testDrawerSliderSwitchKeepsTheDrawerOpen() {
        for previous in modes {
            for target in modes {
                let navigation = AppShellNavigation(mode: previous)
                navigation.isDrawerOpen = true

                XCTAssertTrue(navigation.navigate(to: target, keepsDrawerOpen: true) { true })

                XCTAssertEqual(navigation.mode, target, "滑块与背后页面读同一个模式")
                XCTAssertTrue(navigation.isDrawerOpen)
            }
        }
    }

    func testFailedNavigationPreservesModeAndDrawer() {
        for previous in modes {
            for target in modes {
                for isOpen in [false, true] {
                    let navigation = AppShellNavigation(mode: previous)
                    navigation.isDrawerOpen = isOpen

                    XCTAssertFalse(navigation.navigate(to: target) { false })

                    XCTAssertEqual(navigation.mode, previous)
                    XCTAssertEqual(navigation.isDrawerOpen, isOpen)
                }
            }
        }
    }
}
