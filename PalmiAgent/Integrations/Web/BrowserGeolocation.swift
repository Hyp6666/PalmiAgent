import CoreLocation
import UIKit
import WebKit

/// 内置浏览器的网页定位：用户在设置里（或首次询问时）同意一次，之后网站请求定位时自动提供，不再逐站询问。
@MainActor
final class BrowserGeolocation: NSObject, CLLocationManagerDelegate {
    static let shared = BrowserGeolocation()
    static let preferenceKey = "palmi.browser.geolocation-allowed"

    private let manager = CLLocationManager()
    private var authorizationWaiters: [CheckedContinuation<Void, Never>] = []
    private var locationWaiters: [CheckedContinuation<CLLocation?, Never>] = []
    private var consentTask: Task<Bool, Never>?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    /// 网站是否可以拿到定位：用户同意过，且 App 已获得系统定位授权。
    func isAllowed() async -> Bool {
        guard await hasConsent() else { return false }
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorizationWaiters.append(continuation)
                manager.requestWhenInUseAuthorization()
            }
        }
        return manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
    }

    func currentLocation() async -> CLLocation? {
        await withCheckedContinuation { continuation in
            locationWaiters.append(continuation)
            if locationWaiters.count == 1 { manager.requestLocation() }
        }
    }

    /// 只在从未设置过时询问一次，结果写入设置；之后在设置里修改。
    private func hasConsent() async -> Bool {
        if UserDefaults.standard.object(forKey: Self.preferenceKey) != nil {
            return UserDefaults.standard.bool(forKey: Self.preferenceKey)
        }
        if let consentTask { return await consentTask.value }
        let task = Task { @MainActor () -> Bool in
            let allowed = await Self.askOnce()
            UserDefaults.standard.set(allowed, forKey: Self.preferenceKey)
            return allowed
        }
        consentTask = task
        let allowed = await task.value
        consentTask = nil
        return allowed
    }

    private static func askOnce() async -> Bool {
        guard let presenter = PresentationWindow.topController() else { return false }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: PalmiL10n.tr("browser.location.title"),
                message: PalmiL10n.tr("browser.location.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: PalmiL10n.tr("browser.location.deny"), style: .cancel) { _ in
                continuation.resume(returning: false)
            })
            alert.addAction(UIAlertAction(title: PalmiL10n.tr("browser.location.allow"), style: .default) { _ in
                continuation.resume(returning: true)
            })
            presenter.present(alert, animated: true)
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            let waiters = authorizationWaiters
            authorizationWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in finishLocation(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finishLocation(nil) }
    }

    private func finishLocation(_ location: CLLocation?) {
        let waiters = locationWaiters
        locationWaiters.removeAll()
        waiters.forEach { $0.resume(returning: location) }
    }
}

/// iOS 26 没有网页定位授权回调：注入脚本接管 navigator.geolocation，转给原生定位后回填结果。
@MainActor
final class BrowserGeolocationBridge: NSObject, WKScriptMessageHandler {
    static let handlerName = "palmiGeolocation"
    private weak var webView: WKWebView?

    static let script = """
    (() => {
      if (!window.navigator || !navigator.geolocation || window.__palmiGeo) return;
      const pending = new Map(); let seq = 0;
      window.__palmiGeo = {
        resolve(id, c) {
          const p = pending.get(id); if (!p) return; if (!p.watch) pending.delete(id);
          if (p.ok) p.ok({ coords: { latitude: c.lat, longitude: c.lng, accuracy: c.acc, altitude: null, altitudeAccuracy: null, heading: null, speed: null }, timestamp: Date.now() });
        },
        reject(id, code, message) {
          const p = pending.get(id); if (!p) return; pending.delete(id);
          if (p.err) p.err({ code, message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
        }
      };
      const request = (ok, err, watch) => {
        const id = ++seq; pending.set(id, { ok, err, watch });
        window.webkit.messageHandlers.\(handlerName).postMessage({ id });
        return id;
      };
      const define = (name, value) => Object.defineProperty(Geolocation.prototype, name, { value, configurable: true, writable: true });
      define('getCurrentPosition', function (ok, err) { request(ok, err, false); });
      define('watchPosition', function (ok, err) { return request(ok, err, true); });
      define('clearWatch', function (id) { pending.delete(id); });
      if (navigator.permissions && navigator.permissions.query) {
        const query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = (d) => d && d.name === 'geolocation' ? Promise.resolve({ state: 'prompt', onchange: null }) : query(d);
      }
    })();
    """

    func install(on webView: WKWebView) {
        self.webView = webView
        let controller = webView.configuration.userContentController
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .page))
        controller.add(self, contentWorld: .page, name: Self.handlerName)
    }

    func uninstall() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: .page)
        webView = nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let id = (body["id"] as? NSNumber)?.intValue else { return }
        Task { @MainActor [weak self] in
            guard await BrowserGeolocation.shared.isAllowed() else {
                self?.reply("window.__palmiGeo && window.__palmiGeo.reject(\(id), 1, 'User denied Geolocation')")
                return
            }
            guard let location = await BrowserGeolocation.shared.currentLocation() else {
                self?.reply("window.__palmiGeo && window.__palmiGeo.reject(\(id), 2, 'Position unavailable')")
                return
            }
            let c = location.coordinate
            self?.reply("window.__palmiGeo && window.__palmiGeo.resolve(\(id), {lat: \(c.latitude), lng: \(c.longitude), acc: \(max(1, location.horizontalAccuracy))})")
        }
    }

    private func reply(_ script: String) {
        webView?.evaluateJavaScript(script, in: nil, in: .page, completionHandler: nil)
    }
}
