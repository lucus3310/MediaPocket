import Foundation
import WebKit

// This delegate is retained by the app because WKWebView keeps delegates weak.
// Solver WebViews never need to navigate: Python fetches the player script and
// WebKit only computes its result on about:blank.
@MainActor
final class ResolverWebViewPolicy: NSObject, WKNavigationDelegate, WKUIDelegate {
    static let shared = ResolverWebViewPolicy()
    private(set) var blockedNavigations = 0
    private(set) var blockedWindows = 0

    func configure(_ view: WKWebView) {
        view.navigationDelegate = self
        view.uiDelegate = self
        view.setAllMediaPlaybackSuspended(true, completionHandler: nil)
        if let url = Bundle.main.url(forResource: "ResolverMediaGuard", withExtension: "js"),
           let script = try? String(contentsOf: url, encoding: .utf8) {
            view.configuration.userContentController.addUserScript(WKUserScript(
                source: script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        blockedNavigations += 1
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        blockedWindows += 1
        return nil
    }
}

// Called by the bundled Python WebKit factory on the UI thread, before any
// solver code runs. The GIL is released by the C bridge during this call.
func configureResolverWebView(_ address: UInt) {
    let configure: @Sendable () -> Void = {
        MainActor.assumeIsolated {
            guard let pointer = UnsafeRawPointer(bitPattern: address) else { return }
            let view = Unmanaged<WKWebView>.fromOpaque(pointer).takeUnretainedValue()
            ResolverWebViewPolicy.shared.configure(view)
        }
    }
    if Thread.isMainThread { configure() }
    else { DispatchQueue.main.sync(execute: configure) }
}
