import Photos
import SwiftUI
import UIKit
import WebKit

/// One persistent WKWebView with the full Studio panel (all functions of the web version).
/// The native dock switches panel tabs through `window.studioShowTab(name)`.
@MainActor
final class WebStore: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    static let shared = WebStore()

    let webView: WKWebView
    @Published var isLoading = false
    @Published var failed = false
    @Published var busyText: String?

    weak var app: AppState?
    private var server = ""
    private var token: String?
    private var pageReady = false
    private var currentTab = "crosspost"
    private let refresh = UIRefreshControl()

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.applicationNameForUserAgent = "LitEnergyStudio/1.0 Mobile/15E148 Safari/604.1"
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        let ucc = WKUserContentController()
        cfg.userContentController = ucc
        webView = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        ucc.add(WeakHandler(self), name: "studio")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.keyboardDismissMode = .interactive
        refresh.tintColor = .white
        refresh.addTarget(self, action: #selector(pullToRefresh), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
    }

    // MARK: session

    func attach(server: String, token: String?) {
        self.server = server
        self.token = token
        pageReady = false
        let store = webView.configuration.websiteDataStore.httpCookieStore
        let host = URL(string: server)?.host ?? ""
        Task { @MainActor in
            let cookies = await store.allCookies()
            for c in cookies where c.name == "studio_session" { await store.deleteCookie(c) }
            guard let token = token, !host.isEmpty,
                  let cookie = HTTPCookie(properties: [
                      .domain: host, .path: "/", .name: "studio_session", .value: token,
                      .expires: Date().addingTimeInterval(89 * 86400),
                  ]) else {
                self.webView.loadHTMLString("<html style='background:#000'></html>", baseURL: nil)
                return
            }
            await store.setCookie(cookie)
            self.loadPanel()
        }
    }

    func loadPanel() {
        guard let url = URL(string: server + "/?app=1") else { return }
        failed = false
        var req = URLRequest(url: url)
        if let token = token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        webView.load(req)
    }

    func show(_ tab: String) {
        currentTab = tab
        guard pageReady else { return }
        webView.evaluateJavaScript("window.studioShowTab && window.studioShowTab('\(tab)')", completionHandler: nil)
    }

    @objc private func pullToRefresh() {
        loadPanel()
    }

    // MARK: navigation

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        failed = false
        refresh.endRefreshing()
        guard webView.url?.host != nil else { return }
        if webView.url?.path == "/login" {
            // cookie rejected → token is no longer valid
            app?.logout(message: "Сессия истекла — войдите снова")
            return
        }
        pageReady = true
        show(currentTab)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        refresh.endRefreshing()
        if (error as NSError).code != NSURLErrorCancelled { failed = true }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
        refresh.endRefreshing()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loadPanel()
    }

    private func isOwn(_ url: URL) -> Bool {
        guard let own = URL(string: server) else { return false }
        return url.host == own.host && (url.port ?? 80) == (own.port ?? 80)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.allow); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "about" || scheme == "blob" || scheme == "data" { decisionHandler(.allow); return }
        if scheme == "http" || scheme == "https" {
            if isOwn(url) {
                if navigationAction.targetFrame?.isMainFrame == true, url.path.hasPrefix("/uploads/") {
                    decisionHandler(.cancel)
                    saveMedia(url)
                    return
                }
                decisionHandler(.allow)
            } else if navigationAction.targetFrame == nil || navigationAction.navigationType == .linkActivated {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            } else {
                decisionHandler(.allow) // iframes / embedded resources
            }
            return
        }
        decisionHandler(.cancel)
        UIApplication.shared.open(url) // tg://, mailto:, etc.
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let http = navigationResponse.response as? HTTPURLResponse
        let disposition = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased()
        if navigationResponse.isForMainFrame, let url = navigationResponse.response.url,
           !navigationResponse.canShowMIMEType || disposition.contains("attachment") {
            decisionHandler(.cancel)
            saveMedia(url)
            return
        }
        decisionHandler(.allow)
    }

    // target=_blank / window.open
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url {
            if isOwn(url) {
                if url.path.hasPrefix("/uploads/") { saveMedia(url) } else { webView.load(URLRequest(url: url)) }
            } else {
                UIApplication.shared.open(url)
            }
        }
        return nil
    }

    // MARK: JS dialogs (the panel uses alert/confirm/prompt)

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(a) { completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(false) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(a) { completionHandler(false) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let a = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        a.addTextField { $0.text = defaultText }
        a.addAction(UIAlertAction(title: "Отмена", style: .cancel) { _ in completionHandler(nil) })
        a.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(a.textFields?.first?.text) })
        present(a) { completionHandler(nil) }
    }

    private func present(_ vc: UIViewController, fallback: @escaping () -> Void) {
        guard let top = Self.topViewController() else { fallback(); return }
        top.present(vc, animated: true)
    }

    static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var vc = window?.rootViewController
        while let p = vc?.presentedViewController { vc = p }
        return vc
    }

    // MARK: bridge from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "auth_required":
            app?.logout(message: "Сессия истекла — войдите снова")
        case "logout":
            app?.logout()
        case "token":
            if let t = body["token"] as? String, !t.isEmpty {
                token = t
                Keychain.set(t, for: "token")
                app?.token = t
            }
        default:
            break
        }
    }

    // MARK: media download → Photos / share sheet

    func saveMedia(_ url: URL) {
        busyText = "Скачивание…"
        Task {
            do {
                var req = URLRequest(url: url, timeoutInterval: 300)
                if let token = token { req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
                let (tmp, resp) = try await URLSession.shared.download(for: req)
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    throw APIError(message: "Ошибка загрузки (\(http.statusCode))")
                }
                let name = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tmp, to: dest)
                let ext = dest.pathExtension.lowercased()
                if ["mp4", "mov", "m4v"].contains(ext) {
                    try await Self.saveVideoToPhotos(dest)
                    busyText = nil
                    Haptics.success()
                    toast("Видео сохранено в Фото")
                } else {
                    busyText = nil
                    let share = UIActivityViewController(activityItems: [dest], applicationActivities: nil)
                    Self.topViewController()?.present(share, animated: true)
                }
            } catch {
                busyText = nil
                Haptics.error()
                toast(error.localizedDescription)
            }
        }
    }

    nonisolated static func saveVideoToPhotos(_ file: URL) async throws {
        let status = await withCheckedContinuation { (c: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { c.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw APIError(message: "Нет доступа к Фото — разрешите в Настройках")
        }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: file)
            }) { ok, err in
                if ok { c.resume() } else { c.resume(throwing: err ?? APIError(message: "Не удалось сохранить видео")) }
            }
        }
    }

    func toast(_ text: String) {
        app?.notice = text
    }
}

/// Avoids a retain cycle between WKUserContentController and the store.
@MainActor
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}

struct WebContainer: UIViewRepresentable {
    let store: WebStore

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        attach(to: v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        if store.webView.superview !== uiView { attach(to: uiView) }
    }

    private func attach(to v: UIView) {
        let w = store.webView
        w.removeFromSuperview()
        w.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(w)
        NSLayoutConstraint.activate([
            w.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            w.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            w.topAnchor.constraint(equalTo: v.topAnchor),
            w.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
    }
}
