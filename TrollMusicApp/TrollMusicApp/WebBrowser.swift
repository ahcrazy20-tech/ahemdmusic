import SwiftUI
import UIKit
import WebKit
import Combine

struct BrowserTab: Identifiable {
    let id = UUID()
    var webView: WKWebView
    var urlString: String
    var title: String
}

class WebViewModel: NSObject, ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var currentTabIndex: Int = 0 {
        didSet { refreshNavState() }
    }
    @Published var showTabs: Bool = false
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false

    // Name prompt before handing download to DownloadCenter
    @Published var showNamePrompt: Bool = false
    @Published var customSongName: String = ""
    private var pendingDownloadURL: URL?

    override init() {
        super.init()
        addNewTab()
    }

    var currentWebView: WKWebView { tabs[currentTabIndex].webView }

    private func makeWebView() -> WKWebView {
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences = prefs
        config.allowsInlineMediaPlayback = true
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        wv.navigationDelegate = self
        wv.uiDelegate = self
        return wv
    }

    func addNewTab() {
        let wv = makeWebView()
        tabs.append(BrowserTab(webView: wv, urlString: "https://google.com", title: "New Tab"))
        currentTabIndex = tabs.count - 1
        loadUrl("https://google.com")
    }
    func closeTab(at index: Int) {
        tabs.remove(at: index)
        if tabs.isEmpty { addNewTab() }
        else if currentTabIndex >= tabs.count { currentTabIndex = tabs.count - 1 }
        else { refreshNavState() }
    }
    func goBack()    { currentWebView.goBack() }
    func goForward() { currentWebView.goForward() }
    func refresh()   { currentWebView.reload() }

    func loadUrl(_ urlString: String) {
        var s = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return }
        if !s.contains(".") || s.contains(" ") {
            if let enc = s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
                s = "https://www.google.com/search?q=\(enc)"
            }
        } else if !s.hasPrefix("http") {
            s = "https://" + s
        }
        if let u = URL(string: s) { currentWebView.load(URLRequest(url: u)) }
    }

    func grabAudio() {
        let js = """
        (function(){
          var m = document.querySelectorAll('audio,video,source');
          for(var i=0;i<m.length;i++){
            var s = m[i].src || (m[i].currentSrc);
            if(s && s.startsWith('http')) return s;
          }
          // look in blob URLs too
          return null;
        })()
        """
        currentWebView.evaluateJavaScript(js) { [weak self] result, err in
            guard let self = self else { return }
            if let err = err { print("grabAudio err:", err) }
            let chosen: URL? = {
                if let s = result as? String, let uu = URL(string: s) { return uu }
                return self.currentWebView.url
            }()
            guard let u = chosen else { return }
            self.pendingDownloadURL = u
            self.customSongName = self.suggestedName(for: u)
            self.showNamePrompt = true
        }
    }

    // Inject a floating "Download" button. Clicking it navigates to asmusic-dl://<base64url>
    // which we catch in decidePolicyFor and route to the download prompt.
    func injectFloatingDL() {
        let js = """
        (function(){
          if (document.getElementById('__as_music_dl_btn__')) {
            document.getElementById('__as_music_dl_btn__').style.display='block'; return;
          }
          var b = document.createElement('a');
          b.id = '__as_music_dl_btn__';
          b.innerText = '⬇ DL';
          b.style.cssText = 'position:fixed;right:14px;bottom:80px;z-index:999999;' +
            'background:linear-gradient(135deg,#9333ea,#ec4899);color:#fff;' +
            'padding:10px 14px;border-radius:24px;font:bold 14px sans-serif;' +
            'box-shadow:0 4px 16px rgba(0,0,0,0.5);text-decoration:none;';
          b.onclick = function(e){
            e.preventDefault();
            var src = null;
            document.querySelectorAll('audio,video').forEach(function(el){
              if(!src && el.currentSrc) src = el.currentSrc;
              if(!src && el.src) src = el.src;
            });
            var pick = src || location.href;
            var enc = btoa(unescape(encodeURIComponent(pick)));
            location.href = 'asmusic-dl://?u=' + encodeURIComponent(enc);
          };
          document.body.appendChild(b);
        })();
        """
        currentWebView.evaluateJavaScript(js, completionHandler: nil)
    }

    func confirmDownload() {
        guard let u = pendingDownloadURL else { return }
        DownloadCenter.shared.enqueueDirect(url: u, suggestedName: customSongName)
        pendingDownloadURL = nil
    }
    func cancelPendingDownload() {
        pendingDownloadURL = nil
    }

    private func suggestedName(for url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        if base.isEmpty { return url.host ?? "Track" }
        return base
    }

    private func refreshNavState() {
        guard tabs.indices.contains(currentTabIndex) else { return }
        let wv = tabs[currentTabIndex].webView
        canGoBack = wv.canGoBack
        canGoForward = wv.canGoForward
        tabs[currentTabIndex].urlString = wv.url?.absoluteString ?? tabs[currentTabIndex].urlString
    }
}

// MARK: - WKNavigationDelegate / WKUIDelegate
extension WebViewModel: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let hide = "document.querySelectorAll('.ad,.ads,.popup,iframe').forEach(e=>e.remove());"
        webView.evaluateJavaScript(hide, completionHandler: nil)
        if webView === currentWebView { refreshNavState() }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === currentWebView { refreshNavState() }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if let u = navigationAction.request.url, u.scheme == "asmusic-dl" {
            decisionHandler(.cancel)
            handleMagicDLURL(u)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel)
            triggerDownload(for: navigationAction.request.url, suggested: navigationAction.request.url?.lastPathComponent)
            return
        }
        decisionHandler(.allow)
    }

    private func handleMagicDLURL(_ u: URL) {
        guard let comps = URLComponents(url: u, resolvingAgainstBaseURL: false),
              let ub64 = comps.queryItems?.first(where: { $0.name == "u" })?.value else { return }
        let pad = ub64 + String(repeating: "=", count: (4 - ub64.count % 4) % 4)
        guard let data = Data(base64Encoded: pad),
              let decoded = String(data: data, encoding: .utf8),
              let realURL = URL(string: decoded) else { return }
        DispatchQueue.main.async {
            // If this is a YouTube page, parse video id and route to MP3Juice
            let low = decoded.lowercased()
            if low.contains("youtube.com") || low.contains("youtu.be") {
                // Extract 11-char vid
                if let r = decoded.range(of: #"(?:youtu\.be/|youtube\.com/(?:embed/|live/|shorts/|v/|watch/)|[?&]v=)([a-zA-Z0-9-_]{11})"#, options: .regularExpression),
                   let m = decoded[r].range(of: #"[a-zA-Z0-9-_]{11}"#, options: .regularExpression) {
                    let vid = String(decoded[r][m])
                    DownloadCenter.shared.enqueue(vid: vid, platform: "yt",
                                                  suggestedName: realURL.lastPathComponent.isEmpty ? "YouTube Track" : realURL.lastPathComponent)
                    return
                }
            }
            if low.contains("soundcloud.com") {
                DownloadCenter.shared.enqueueDirect(url: realURL, suggestedName: "SoundCloud Track")
                return
            }
            // Otherwise, treat as direct audio URL
            self.triggerDownload(for: realURL, suggested: realURL.lastPathComponent)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.cancel)
            let suggested = (navigationResponse.response as? HTTPURLResponse)?.suggestedFilename
                ?? navigationResponse.response.url?.lastPathComponent
            triggerDownload(for: navigationResponse.response.url, suggested: suggested)
            return
        }
        if let mime = navigationResponse.response.mimeType?.lowercased(),
           mime.contains("audio") || mime.contains("mpeg") || mime.contains("mp4")
            || mime.contains("webm") || mime.contains("zip") || mime.contains("octet-stream") {
            decisionHandler(.cancel)
            let suggested = (navigationResponse.response as? HTTPURLResponse)?.suggestedFilename
                ?? navigationResponse.response.url?.lastPathComponent
            triggerDownload(for: navigationResponse.response.url, suggested: suggested)
            return
        }
        decisionHandler(.allow)
    }

    private func triggerDownload(for url: URL?, suggested: String?) {
        guard let u = url else { return }
        DispatchQueue.main.async {
            self.pendingDownloadURL = u
            let clean = (suggested?.removingPercentEncoding ?? suggested) ?? u.lastPathComponent
            self.customSongName = clean.isEmpty ? "Track" : clean
            self.showNamePrompt = true
        }
    }
}

struct WebViewUI: UIViewRepresentable {
    @ObservedObject var viewModel: WebViewModel
    @Binding var urlString: String

    func makeUIView(context: Context) -> WKWebView {
        viewModel.currentWebView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

