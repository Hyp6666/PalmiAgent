import SwiftUI
import UIKit
import XCTest
@testable import PalmiAgent

@MainActor
final class NeoRuntimeDetailTests: XCTestCase {
    func testOpenReasoningDetailKeepsReceivingStreamingText() throws {
        let buffer = LiveReasoningBuffer(initialText: "First reasoning. ")
        let message = PalmiChatMessage(role: .agent, kind: .toolCall, content: "", toolCall: .init(
            cardKind: .modelThink, toolTitle: "Thought", toolName: "model_think",
            presentationKind: .data, status: .success, summary: "First reasoning",
            details: "First reasoning. ", argumentsJSON: "", requiresUserInteraction: false
        ))
        let step = NeoRuntimeStep(id: message.id, kind: .thinking, state: .running, messages: [message])
        let host = UIHostingController(rootView: NeoRuntimeStepDetailSheet(
            step: step, liveReasoningBuffer: { $0 == message.id ? buffer : nil },
            onOpenRelatedThread: { _ in }
        ))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.2))
        XCTAssertTrue(reasoningTexts(in: host.view).contains("First reasoning. "))

        buffer.append("More reasoning arrives while the sheet is open.")
        RunLoop.main.run(until: Date.now.addingTimeInterval(0.2))
        host.view.layoutIfNeeded()
        XCTAssertTrue(reasoningTexts(in: host.view).contains(buffer.snapshot()))
    }

    private func reasoningTexts(in view: UIView) -> [String] {
        let own = (view as? UITextView).map { [$0.text ?? ""] } ?? []
        return own + view.subviews.flatMap(reasoningTexts(in:))
    }
}
