import SwiftUI
import WebKit
import UIKit

struct PalmiHTMLArtifactView: View {
    let session: PalmiUIArtifactSession
    let expanded: Bool
    @State private var height: CGFloat = 320
    @State private var loading = true
    @State private var failed = false

    var body: some View {
        if failed {
            VStack(spacing: 12) {
                Label(PalmiL10n.tr("ui.unavailable"), systemImage: "rectangle.slash")
                Text(session.validated.artifact.summary).font(.subheadline).foregroundStyle(.secondary)
                Button(PalmiL10n.tr("ui.retry")) { session.reload() }.buttonStyle(.bordered)
            }.frame(maxWidth: .infinity).padding(24)
        } else {
            PalmiHTMLWebView(session: session, renderID: session.reloadID, html: session.validated.artifact.html ?? "", initialState: session.state,
                             onState: { session.replaceState($0) },
                             onHeight: { height = min(max($0, 200), expanded ? 760 : 480) },
                             onReady: { loading = false }, onFailure: { failed = true })
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if loading {
                        ZStack {
                            Color(uiColor: .secondarySystemBackground)
                            ProgressView(PalmiL10n.tr("ui.loading"))
                        }
                    }
                }
        }
    }
}

private struct PalmiHTMLWebView: UIViewRepresentable {
    let session: PalmiUIArtifactSession
    let renderID: UUID
    let html: String
    let initialState: [String: PalmiUIValue]
    let onState: ([String: PalmiUIValue]) -> Void
    let onHeight: (CGFloat) -> Void
    let onReady: () -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsInlineMediaPlayback = false
        let controller = configuration.userContentController
        controller.add(context.coordinator, contentWorld: Coordinator.hostWorld, name: Coordinator.handlerName)
        controller.addUserScript(WKUserScript(source: PalmiHTMLDocument.hardenGlobals,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: false,
                                              in: .page))
        controller.addUserScript(WKUserScript(source: PalmiHTMLDocument.hostBridge(nonce: context.coordinator.nonce),
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true,
                                              in: Coordinator.hostWorld))
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        context.coordinator.webView = view
        context.coordinator.prepareAndLoad(html: html, initialState: initialState)
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // A completed block is immutable. Parent text deltas and local state changes do not reload its WebView.
        context.coordinator.owner = self
    }

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) { coordinator.detachAndDispose(uiView) }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let hostWorld = WKContentWorld.world(name: "PalmiArtifactHostV1")
        static let handlerName = "palmiArtifactV1"
        let nonce = UUID().uuidString
        let renderID: UUID
        var owner: PalmiHTMLWebView
        weak var webView: WKWebView?
        private var disposed = false
        private var detaching = false
        private var allowedMainLoad = false
        private var allowedChildLoad = false
        private var ready = false
        private var watchdog: Task<Void, Never>?
        private var rateStart = Date.distantPast
        private var rateCount = 0
        private let snapshotToken = UUID()
        private var snapshotID: String?
        private var snapshotContinuation: CheckedContinuation<[String: PalmiUIValue], Error>?
        private var snapshotTimeout: Task<Void, Never>?

        init(owner: PalmiHTMLWebView) { self.owner = owner; self.renderID = owner.renderID }

        func prepareAndLoad(html: String, initialState: [String: PalmiUIValue]) {
            let rules = #"[{"trigger":{"url-filter":"^[a-z]+://","url-filter-is-case-sensitive":false},"action":{"type":"block"}}]"#
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "palmi-ui-offline-v1", encodedContentRuleList: rules) { [weak self] ruleList, error in
                Task { @MainActor [weak self] in
                    guard let self, !self.disposed, let view = self.webView else { return }
                    guard error == nil, let ruleList else { self.fail(); return }
                    view.configuration.userContentController.add(ruleList)
                    let document = PalmiHTMLDocument.make(html: html, state: initialState, nonce: self.nonce)
                    view.loadHTMLString(document, baseURL: nil)
                    self.watchdog = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(8)) } catch { return }
                        guard let self, !self.ready, !self.disposed else { return }
                        self.fail()
                    }
                }
            }
        }

        func dispose() {
            guard !disposed else { return }; disposed = true
            finishSnapshot(.failure(PalmiUIValidationError.invalid("The UI was closed")))
            owner.session.removeSnapshotProvider(token: snapshotToken)
            watchdog?.cancel(); watchdog = nil
            webView?.stopLoading()
            webView?.navigationDelegate = nil; webView?.uiDelegate = nil
            webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.hostWorld)
            webView?.configuration.userContentController.removeAllUserScripts()
            webView = nil
        }

        func detachAndDispose(_ view: WKWebView) {
            guard !disposed, !detaching else { return }; detaching = true
            owner.session.removeSnapshotProvider(token: snapshotToken)
            let revision = owner.session.stateRevision
            Task { @MainActor [self, view] in
                if ready, renderID == owner.session.reloadID, snapshotContinuation == nil,
                   let snapshot = try? await requestSnapshot() {
                    owner.session.acceptDetachedSnapshot(snapshot, ifRevision: revision)
                }
                dispose()
                withExtendedLifetime(view) { }
            }
        }

        private func fail() {
            guard !disposed else { return }
            finishSnapshot(.failure(PalmiUIValidationError.invalid("The UI is unavailable")))
            owner.session.removeSnapshotProvider(token: snapshotToken)
            watchdog?.cancel(); watchdog = nil
            webView?.stopLoading()
            owner.onFailure()
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !disposed, renderID == owner.session.reloadID,
                  message.name == Self.handlerName, message.frameInfo.isMainFrame,
                  message.webView === webView, let body = message.body as? [String: Any],
                  body["nonce"] as? String == nonce, let kind = body["kind"] as? String else { return }
            if kind == "snapshot" {
                guard let requestID = body["requestID"] as? String, requestID == snapshotID,
                      let state = decodeState(body["payload"]) else { return }
                finishSnapshot(.success(state)); return
            }
            let now = Date()
            if now.timeIntervalSince(rateStart) >= 1 { rateStart = now; rateCount = 0 }
            rateCount += 1; guard rateCount <= 30 else { return }
            switch kind {
            case "state":
                guard !detaching, let state = decodeState(body["payload"]) else { return }
                owner.onState(state)
            case "height":
                guard let number = body["payload"] as? NSNumber else { return }
                let value = number.doubleValue
                if value.isFinite, value > 0, value <= 20_000 { owner.onHeight(CGFloat(value)) }
            case "ready":
                ready = true; watchdog?.cancel(); watchdog = nil; owner.onReady()
                owner.session.registerSnapshotProvider(token: snapshotToken) { [weak self] in
                    guard let self else { throw PalmiUIValidationError.invalid("The UI was closed") }
                    return try await self.requestSnapshot()
                }
            case "error": fail()
            default: break
            }
        }

        private func decodeState(_ value: Any?) -> [String: PalmiUIValue]? {
            guard let raw = value as? String, raw.utf8.count <= PalmiUIValidator.maximumStateBytes,
                  let state = try? JSONDecoder().decode([String: PalmiUIValue].self, from: Data(raw.utf8)),
                  (try? PalmiUIValidator.validateState(state)) != nil else { return nil }
            return state
        }

        private func requestSnapshot() async throws -> [String: PalmiUIValue] {
            guard !disposed, ready, let view = webView, snapshotContinuation == nil else {
                throw PalmiUIValidationError.invalid("The UI cannot provide a snapshot")
            }
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let id = UUID().uuidString
                    snapshotID = id; snapshotContinuation = continuation
                    snapshotTimeout = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(3)) } catch { return }
                        self?.finishSnapshot(.failure(PalmiUIValidationError.invalid("UI state snapshot timed out")))
                    }
                    if Task.isCancelled {
                        finishSnapshot(.failure(CancellationError())); return
                    }
                    view.callAsyncJavaScript("globalThis.__palmiSnapshotRequest(requestID);", arguments: ["requestID": id],
                                             in: nil, in: Self.hostWorld) { [weak self] result in
                        if case .failure(let error) = result {
                            Task { @MainActor [weak self] in self?.finishSnapshot(.failure(error)) }
                        }
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finishSnapshot(.failure(CancellationError())) }
            }
        }

        private func finishSnapshot(_ result: Result<[String: PalmiUIValue], Error>) {
            guard let continuation = snapshotContinuation else { return }
            snapshotContinuation = nil; snapshotID = nil
            snapshotTimeout?.cancel(); snapshotTimeout = nil
            continuation.resume(with: result)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url?.absoluteString ?? ""
            if action.targetFrame?.isMainFrame == true, !allowedMainLoad,
               action.navigationType == .other, url == "about:blank" {
                allowedMainLoad = true; decisionHandler(.allow); return
            }
            if action.targetFrame?.isMainFrame == false, !allowedChildLoad,
               action.navigationType == .other, url == "about:srcdoc" {
                allowedChildLoad = true; decisionHandler(.allow); return
            }
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            let value = response.response.url?.absoluteString ?? ""
            decisionHandler(response.canShowMIMEType && (value == "about:blank" || value == "about:srcdoc") ? .allow : .cancel)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if (error as NSError).code != NSURLErrorCancelled { fail() }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { fail() }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        func webView(_ webView: WKWebView, requestDeviceOrientationAndMotionPermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
        func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                     completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) { completionHandler(nil) }
    }
}

nonisolated enum PalmiHTMLDocument {
    private static let guestPolicy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; media-src 'none'; connect-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; webrtc 'block'"

    static func make(html: String, state: [String: PalmiUIValue], nonce: String) -> String {
        let state64 = ((try? JSONEncoder().encode(state)) ?? Data("{}".utf8)).base64EncodedString()
        let guest = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(escape(guestPolicy))">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="no-referrer">
        <meta http-equiv="x-dns-prefetch-control" content="off">
        <style>:root{color-scheme:light dark}body{font:16px -apple-system,system-ui,sans-serif;margin:0;padding:12px;box-sizing:border-box}*{box-sizing:border-box}img,svg,canvas{max-width:100%}button,input,select{font:inherit}button,input,select{min-height:40px}</style>
        <script>\(guestBridge(nonce: nonce, state64: state64))</script>
        </head><body>\(html)</body></html>
        """
        // Untrusted bytes enter only an escaped srcdoc attribute. They never enter the host document's JS or DOM.
        return """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; frame-src about:; img-src data: blob:; font-src data:; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{padding:0;margin:0;width:100%;height:100%;overflow:hidden;color-scheme:light dark}iframe{display:block;width:100%;height:100%;border:0}</style>
        </head><body><iframe id="palmi-artifact" sandbox="allow-scripts" referrerpolicy="no-referrer" allow="camera 'none'; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write 'none'; display-capture 'none'" srcdoc="\(escape(guest))"></iframe></body></html>
        """
    }

    static let hardenGlobals = #"""
    (() => {
      // CSP does not consistently govern WebRTC. Remove its constructors in every frame before page scripts.
      for (const key of ['RTCPeerConnection','webkitRTCPeerConnection','RTCIceGatherer','RTCDtlsTransport','RTCIceTransport','WebTransport','Worker','SharedWorker','WebSocket','EventSource']) {
        try { Object.defineProperty(globalThis, key, {value:undefined,writable:false,configurable:false}); } catch (_) {}
      }
    })();
    """#

    static func hostBridge(nonce: String) -> String {
        """
        (() => {
          const nonce = '\(nonce)';
          const counts = {state:0,height:0,ready:0,error:0};
          let epoch = performance.now();
          let pendingSnapshot = null;
          Object.defineProperty(globalThis, '__palmiSnapshotRequest', {value:requestID => {
            const frame = document.getElementById('palmi-artifact');
            if (!frame) throw new Error('Artifact frame unavailable');
            pendingSnapshot = requestID;
            frame.contentWindow.postMessage({channel:'palmi-ui-host-v1',nonce,kind:'snapshot',requestID}, '*');
          }, writable:false, configurable:false});
          window.addEventListener('message', event => {
            const frame = document.getElementById('palmi-artifact');
            if (!frame || event.source !== frame.contentWindow || event.origin !== 'null') return;
            const data = event.data;
            if (!data || data.channel !== 'palmi-ui-v1' || data.nonce !== nonce) return;
            if (data.kind === 'snapshot') {
              if (data.requestID !== pendingSnapshot || !pendingSnapshot || typeof data.payload !== 'string' || data.payload.length > 16384) return;
              pendingSnapshot = null;
              window.webkit.messageHandlers.palmiArtifactV1.postMessage({nonce,kind:'snapshot',payload:data.payload,requestID:data.requestID});
              return;
            }
            if (!Object.prototype.hasOwnProperty.call(counts, data.kind)) return;
            const now = performance.now();
            if (now - epoch >= 1000) { epoch = now; for (const key in counts) counts[key] = 0; }
            if (++counts[data.kind] > (data.kind === 'state' ? 12 : 6)) return;
            let payload = data.payload;
            if (data.kind === 'state' && (typeof payload !== 'string' || payload.length > 16384)) return;
            if (data.kind === 'height' && (!Number.isFinite(payload) || payload <= 0 || payload > 20000)) return;
            if (data.kind === 'ready' || data.kind === 'error') payload = null;
            window.webkit.messageHandlers.palmiArtifactV1.postMessage({nonce,kind:data.kind,payload});
          });
        })();
        """
    }

    private static func guestBridge(nonce: String, state64: String) -> String {
        """
        (() => {
          const nonce = '\(nonce)';
          const decoder = new TextDecoder();
          let current = JSON.parse(decoder.decode(Uint8Array.from(atob('\(state64)'), c => c.charCodeAt(0))));
          const post = (kind, payload) => parent.postMessage({channel:'palmi-ui-v1',nonce,kind,payload}, '*');
          const clone = value => JSON.parse(JSON.stringify(value));
          let stateTimer = null, lastStateSent = -Infinity;
          const publishState = () => {
            if (stateTimer !== null) clearTimeout(stateTimer);
            stateTimer = null; lastStateSent = performance.now();
            post('state', JSON.stringify(current));
          };
          const queueState = () => {
            const delay = Math.max(0, 125 - (performance.now() - lastStateSent));
            if (delay === 0) publishState();
            else if (stateTimer === null) stateTimer = setTimeout(publishState, delay);
          };
          const validate = state => {
            if (!state || Array.isArray(state) || typeof state !== 'object') return false;
            const keys = Object.keys(state);
            if (keys.length > 64) return false;
            for (const key of keys) {
              if (!/^[A-Za-z0-9_-]{1,64}$/.test(key)) return false;
              const value = state[key];
              if (typeof value === 'number' && Number.isFinite(value) && Math.abs(value) <= 1e15) continue;
              if (typeof value === 'string' && [...value].length <= 1000) continue;
              if (typeof value === 'boolean') continue;
              return false;
            }
            return new TextEncoder().encode(JSON.stringify(state)).length <= 16384;
          };
          Object.defineProperty(window, 'PalmiUI', {value:Object.freeze({
            getState: () => clone(current),
            setState: next => { if (!validate(next)) throw new Error('Invalid PalmiUI state'); current = clone(next); queueState(); }
          }), writable:false, configurable:false});
          addEventListener('message', event => {
            const data = event.data;
            if (event.source !== parent || !data || data.channel !== 'palmi-ui-host-v1' || data.nonce !== nonce || data.kind !== 'snapshot') return;
            if (typeof data.requestID !== 'string' || !/^[A-Fa-f0-9-]{36}$/.test(data.requestID)) return;
            publishState();
            parent.postMessage({channel:'palmi-ui-v1',nonce,kind:'snapshot',requestID:data.requestID,payload:JSON.stringify(current)}, '*');
          });
          addEventListener('pagehide', publishState);
          document.addEventListener('visibilitychange', () => { if (document.hidden) publishState(); });
          let heightTimer;
          const reportHeight = () => {
            clearTimeout(heightTimer);
            heightTimer = setTimeout(() => post('height', Math.ceil(Math.max(document.body.scrollHeight, document.documentElement.scrollHeight))), 80);
          };
          addEventListener('DOMContentLoaded', () => {
            document.addEventListener('submit', event => event.preventDefault(), true);
            document.addEventListener('click', event => {
              const link = event.target.closest?.('a');
              if (link && !String(link.getAttribute('href') || '').startsWith('#')) event.preventDefault();
            }, true);
            new ResizeObserver(reportHeight).observe(document.body);
            reportHeight(); post('ready', null);
          }, {once:true});
          addEventListener('error', () => post('error', null), {once:true});
          addEventListener('unhandledrejection', () => post('error', null), {once:true});
        })();
        """
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
