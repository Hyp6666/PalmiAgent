import XCTest
import SwiftUI
import WebKit
import UIKit
@testable import PalmiAgent

/// Hosted iOS simulator tests. These exercise WKWebView, not a string-only imitation of its policy.
@MainActor
final class PalmiHTMLArtifactIntegrationTests: XCTestCase {
    private var window: UIWindow?
    private var temporaryRoot: URL?

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        if let temporaryRoot { try? FileManager.default.removeItem(at: temporaryRoot) }
        temporaryRoot = nil
        super.tearDown()
    }

    func testHTMLStartsAndRetainsTheLastRapidState() async throws {
        let session = try mount(html: "<p>Counter</p><script>for(let n=0;n<60;n++){PalmiUI.setState({n});}</script>")
        try await eventually { session.snapshotAvailable && session.state["n"] == .number(59) }
        let captured = await session.captureLatestState()
        XCTAssertTrue(captured)
        XCTAssertEqual(session.state["n"], .number(59))
    }

    func testImmediateSnapshotCapturesPendingTrailingState() async throws {
        let session = try mount(html: #"""
        <p>Snapshot</p><script>
        PalmiUI.setState({n:0});
        addEventListener('message',event=>{
          if(event.source===parent && event.data && event.data.testSet===99){
            for(let n=1;n<=99;n++)PalmiUI.setState({n});
          }
        });
        </script>
        """#)
        try await eventually { session.snapshotAvailable }
        let webView = try XCTUnwrap(findWebView(in: window!))
        _ = try await webView.evaluateJavaScript("document.getElementById('palmi-artifact').contentWindow.postMessage({testSet:99},'*');")
        let captured = await session.captureLatestState()
        XCTAssertTrue(captured)
        XCTAssertEqual(session.state["n"], .number(99))
    }

    func testSandboxPreventsHostAccessAndNetworkAPIs() async throws {
        let session = try mount(html: #"""
        <p>Security fixture</p><script>
        const report={parentBlocked:false,storageBlocked:false,popupBlocked:false,fetchBlocked:false,fetchCSP:false,rtcAbsent:false,workerAbsent:false};
        function publish(){PalmiUI.setState(report);}
        try{parent.document.body;}catch(_){report.parentBlocked=true;}
        try{localStorage.getItem('x');}catch(_){report.storageBlocked=true;}
        try{report.popupBlocked=window.open('https://example.invalid')===null;}catch(_){report.popupBlocked=true;}
        report.rtcAbsent=typeof RTCPeerConnection==='undefined';
        report.workerAbsent=typeof Worker==='undefined';
        addEventListener('securitypolicyviolation',event=>{if(event.effectiveDirective==='connect-src'){report.fetchCSP=true;publish();}});
        fetch('https://example.invalid/palmi-ui-test').then(()=>publish(),()=>{report.fetchBlocked=true;publish();});
        publish();
        </script>
        """#)
        try await eventually {
            ["parentBlocked", "storageBlocked", "popupBlocked", "fetchBlocked", "fetchCSP", "rtcAbsent", "workerAbsent"]
                .allSatisfy { session.state[$0] == .bool(true) }
        }
        let webView = try XCTUnwrap(findWebView(in: window!))
        let sandbox = try await webView.evaluateJavaScript("document.getElementById('palmi-artifact').getAttribute('sandbox')") as? String
        XCTAssertEqual(sandbox, "allow-scripts")
    }

    func testExternalResourcesSubframesAndFileFetchAreBlockedInLiveWebKit() async throws {
        let session = try mount(html: #"""
        <p>Offline resources</p><script>
        const report={scriptBlocked:false,imageBlocked:false,frameBlocked:true,fileBlocked:false,websocketAbsent:typeof WebSocket==='undefined',navigationBlocked:false};
        function publish(){PalmiUI.setState(report);}
        addEventListener('securitypolicyviolation',event=>{
          if(event.effectiveDirective.startsWith('script-src'))report.scriptBlocked=true;
          if(event.effectiveDirective==='img-src')report.imageBlocked=true;
          publish();
        });
        const script=document.createElement('script');script.src='https://example.invalid/escape.js';document.body.append(script);
        const img=document.createElement('img');img.src='https://example.invalid/image.png';document.body.append(img);
        addEventListener('message',event=>{if(event.data?.palmiNestedExecuted){report.frameBlocked=false;publish();}});
        const frame=document.createElement('iframe');frame.srcdoc='<script>parent.postMessage({palmiNestedExecuted:true},"*");</scr'+'ipt>';document.body.append(frame);
        fetch('file:///etc/passwd').catch(()=>{report.fileBlocked=true;publish();});
        try{top.location.href='https://example.invalid/escape';}catch(_){report.navigationBlocked=true;}
        publish();
        </script>
        """#)
        // Navigation policy may cancel srcdoc without a CSP event. Check actual execution.
        try await Task.sleep(for: .milliseconds(300))
        do {
            try await eventually {
                ["scriptBlocked", "imageBlocked", "frameBlocked", "fileBlocked", "websocketAbsent", "navigationBlocked"]
                    .allSatisfy { session.state[$0] == .bool(true) }
            }
        } catch {
            XCTFail("Live resource policy results: \(session.snapshotJSON())")
            throw error
        }
        let captured = await session.captureLatestState()
        XCTAssertTrue(captured)
    }

    func testForgedWindowAndNonceMessagesCannotChangeState() async throws {
        let session = try mount(html: #"""
        <p>Bridge identity</p><script>
        PalmiUI.setState({n:1});
        parent.postMessage({channel:'palmi-ui-v1',nonce:'forged',kind:'state',payload:'{"n":99}'},'*');
        </script>
        """#)
        try await eventually { session.snapshotAvailable && session.state["n"] == .number(1) }
        let webView = try XCTUnwrap(findWebView(in: window!))
        let bridgeExposed = try await webView.evaluateJavaScript("Boolean(window.webkit?.messageHandlers?.palmiArtifactV1)") as? Bool
        XCTAssertEqual(bridgeExposed, false)
        _ = try await webView.evaluateJavaScript(#"""
        const guest=document.getElementById('palmi-artifact').srcdoc;
        const nonce=guest.match(/const nonce = '([^']+)'/)[1];
        window.postMessage({channel:'palmi-ui-v1',nonce,kind:'state',payload:'{"n":99}'},'*');
        """#)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(session.state["n"], .number(1))
        let captured = await session.captureLatestState()
        XCTAssertTrue(captured)
        XCTAssertEqual(session.state["n"], .number(1))
    }

    func testResetCannotBeOverwrittenByDetachedOldGuest() async throws {
        let session = try mount(html: #"""
        <p>Reset</p><script>
        const current=PalmiUI.getState();
        PalmiUI.setState({n:current.n||1});
        addEventListener('message',event=>{if(event.source===parent&&event.data?.testSet===99)PalmiUI.setState({n:99});});
        </script>
        """#, state: ["n": 1])
        try await eventually { session.snapshotAvailable }
        let webView = try XCTUnwrap(findWebView(in: window!))
        _ = try await webView.evaluateJavaScript("document.getElementById('palmi-artifact').contentWindow.postMessage({testSet:99},'*');")
        let captured = await session.captureLatestState()
        XCTAssertTrue(captured); XCTAssertEqual(session.state["n"], .number(99))
        session.reset()
        try await eventually { session.snapshotAvailable && session.state["n"] == .number(1) }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(session.state["n"], .number(1))
    }

    private func mount(html: String, state: [String: Any] = [:]) throws -> PalmiUIArtifactSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryRoot = root
        let object: [String: Any] = ["version": 1, "id": "wk-fixture", "kind": "html", "title": "Fixture", "summary": "Integration test.", "initialState": state, "html": html]
        let bytes = try JSONSerialization.data(withJSONObject: object)
        let validated = try PalmiUIValidator.decode(String(decoding: bytes, as: UTF8.self))
        let session = PalmiUIArtifactSession(validated: validated, messageID: UUID(), workspaceURL: root)
        let controller = UIHostingController(rootView: FixtureView(session: session))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return session
    }

    private struct FixtureView: View {
        let session: PalmiUIArtifactSession
        var body: some View { PalmiHTMLArtifactView(session: session, expanded: false).id(session.reloadID) }
    }

    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        return view.subviews.lazy.compactMap { self.findWebView(in: $0) }.first
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(7))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The live WKWebView condition did not become true")
        throw PalmiUIValidationError.invalid("Timed out waiting for WKWebView")
    }
}
