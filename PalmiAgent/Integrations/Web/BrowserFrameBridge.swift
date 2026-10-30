import Foundation
import WebKit

// 在每个 frame 的隔离内容世界注册句柄，让坐标点击可以到达跨域 iframe。
@MainActor
final class BrowserFrameBridge: NSObject, WKScriptMessageHandler {
    private let secret = UUID().uuidString.lowercased()
    private var frames: [String: WKFrameInfo] = [:]
    var onBlockedNavigation: ((String) -> Void)?
    private weak var controller: WKUserContentController?
    private static let handlerName = "palmiBrowserFrame"

    func install(on controller: WKUserContentController) {
        self.controller = controller
        controller.add(self, contentWorld: BrowserSession.contentWorld, name: Self.handlerName)
        refreshScripts()
    }

    private func refreshScripts() {
        guard let controller else { return }
        let source = """
        globalThis.__palmiFrameSecret = '\(secret)';
        globalThis.__palmiFrameToken = '\(secret)-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
        window.webkit.messageHandlers.\(Self.handlerName).postMessage(globalThis.__palmiFrameToken);
        window.addEventListener('message', event => {
            const data = event.data;
            if (event.source !== parent || !data || data.palmiFrameQuery !== globalThis.__palmiFrameSecret) return;
            event.source.postMessage({palmiFrameReply:globalThis.__palmiFrameSecret,requestID:data.requestID,token:globalThis.__palmiFrameToken}, '*');
        });
        """
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: BrowserSession.contentWorld))
        controller.addUserScript(WKUserScript(source: BrowserNavigationGuard.isolatedScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: BrowserSession.contentWorld))
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let object = message.body as? [String: Any], let blocked = object["blocked"] as? String {
            onBlockedNavigation?(String(blocked.prefix(160)))
            return
        }
        guard let token = message.body as? String, token.hasPrefix(secret + "-"), token.count < 160 else { return }
        if frames.count < 256 { frames[token] = message.frameInfo }
    }

    func frame(for token: String) throws -> WKFrameInfo {
        guard let frame = frames[token] else {
            throw BrowserToolError(code: "stale_frame", message: "iframe 已变化，请先 observe 或 look 后再使用坐标。")
        }
        return frame
    }

    func reset() { frames.removeAll() }

    func dispose() {
        controller?.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: BrowserSession.contentWorld)
        frames.removeAll()
    }
}
