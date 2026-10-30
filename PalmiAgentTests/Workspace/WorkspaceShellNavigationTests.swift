import XCTest
import SwiftUI
import UIKit
@testable import PalmiAgent

@MainActor
final class WorkspaceShellNavigationTests: XCTestCase {
    func testFullScreenRoundTripPreservesConversationInBothAssistantModes() async throws {
        let defaults = UserDefaults.standard
        let keys = [OnboardingStorage.hasCompletedKey, "palmi.app-shell-mode", ReleaseNotesCatalog.acknowledgedKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(true, forKey: OnboardingStorage.hasCompletedKey)
        defaults.set(ReleaseNotesCatalog.currentID, forKey: ReleaseNotesCatalog.acknowledgedKey)
        for surface in [WorkspaceProjectSurface.chat, .professional] {
            defaults.set(surface == .chat ? "chat" : "professional", forKey: "palmi.app-shell-mode")
            let fixture = try ChatReadFixture(surface: surface)
            defer { fixture.cleanUp() }
            let shell = WorkspaceShellScreen(workspaceStore: fixture.workspace, manualLabStore: fixture.manualLab,
                skillRegistry: fixture.registry, chatStore: fixture.store, bionicStore: fixture.bionic)
            let host = UIHostingController(rootView: shell)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(200))
            // Startup opens a draft. Select a real conversation before entering a full-screen surface.
            if surface == .chat {
                fixture.workspace.selectChatConversation(try XCTUnwrap(fixture.workspace.chatProjects.first))
            } else {
                fixture.workspace.selectThread(try XCTUnwrap(fixture.workspace.thread(for: fixture.selection)))
            }
            XCTAssertEqual(fixture.workspace.selectedSelection, fixture.selection)
            for _ in 0..<2 {
                let browser = UIViewController()
                browser.modalPresentationStyle = .fullScreen
                await withCheckedContinuation { continuation in
                    host.present(browser, animated: false) { continuation.resume() }
                }
                await withCheckedContinuation { continuation in
                    browser.dismiss(animated: false) { continuation.resume() }
                }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(fixture.workspace.selectedSelection, fixture.selection,
                    "Returning from a full-screen browser must preserve the selected conversation")
            }
        }
    }
}
