//
//  WebViewController.swift
//  ChatDemo
//
//  壳的宿主控制器：起本地静态服务器 → 用 WKWebView 打开 http://127.0.0.1:<port>/，
//  再把浏览器有、WKWebView 没有的能力（录音、选文件、下载、新窗口）接回原生。
//

import AVFoundation
import QuickLook
import SafariServices
import UIKit
import WebKit

final class WebViewController: UIViewController {
    /// 前端构建产物在 bundle 里的目录名。
    private static let webDirectory = "web"

    private var server: LocalServer?
    private var webView: WKWebView!
    private var loadErrorView: UIView?
    private var previewFileURL: URL?
    private let filesDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-demo-files", isDirectory: true)

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        configureAudioSession()
        installWebView()
        startServerAndLoad()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent || navigationController?.isBeingDismissed == true {
            server?.stop()
            server = nil
        }
    }

    // MARK: - 音频

    /// 语音朗读播放的是流式 PCM，需要在静音开关打开时也能出声。
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    }

    // MARK: - 组装

    private func installWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        // 语音朗读由点击触发后创建 AudioContext，不需要每次再要一次用户手势。
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.userContentController.add(self, name: BridgeScript.handlerName)
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: BridgeScript.source,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.keyboardDismissMode = .interactive
        webView.isOpaque = false
        webView.backgroundColor = .systemBackground
        webView.scrollView.backgroundColor = .systemBackground
        if #available(iOS 16.4, *) {
            webView.isInspectable = true
        }
        view.addSubview(webView)
        self.webView = webView

        // 贴在安全区内，键盘升起时整体上移（页面自己用 visualViewport 校正布局）。
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
    }

    // MARK: - 本地服务

    private func startServerAndLoad() {
        guard let root = Bundle.main.url(
            forResource: Self.webDirectory,
            withExtension: nil
        ) else {
            showLoadError("安装包里没有前端资源（\(Self.webDirectory)/）")
            return
        }
        do {
            let server = LocalServer(root: root)
            let port = try server.start()
            self.server = server
            guard let url = URL(string: "http://127.0.0.1:\(port)/index.html") else {
                showLoadError("本地服务地址无效")
                return
            }
            webView.load(URLRequest(url: url))
        } catch {
            showLoadError("本地服务启动失败：\(error.localizedDescription)")
        }
    }

    private func showLoadError(_ message: String) {
        loadErrorView?.removeFromSuperview()
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.font = .preferredFont(forTextStyle: .callout)
        label.text = message
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, multiplier: 0.8),
        ])
        loadErrorView = label
    }

    // MARK: - 外部打开

    private func openExternally(_ url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return }
        if scheme == "http" || scheme == "https" {
            let controller = SFSafariViewController(url: url)
            controller.preferredControlTintColor = view.tintColor
            present(controller, animated: true)
            return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
    }

    private func isLocalURL(_ url: URL) -> Bool {
        guard url.host == "127.0.0.1", let port = server?.port else { return false }
        return url.port == Int(port)
    }

    // MARK: - 桥接动作

    private func handleBridgeMessage(_ body: [String: Any]) {
        let action = body["action"] as? String ?? ""
        switch action {
        case "saveFile":
            if let name = body["name"] as? String,
               let base64 = body["data"] as? String
            {
                saveFile(name: name, mime: body["mime"] as? String, base64: base64)
            }
        case "previewFile":
            if let name = body["name"] as? String,
               let base64 = body["data"] as? String
            {
                previewFile(name: name, mime: body["mime"] as? String, base64: base64)
            }
        case "failed":
            let message = body["message"] as? String ?? "未知错误"
            presentAlert(title: "操作失败", message: message)
        default:
            break
        }
    }

    /// base64 走 JS 字符串传进来，超过这个量容易把内存打满，直接拒绝。
    private static let maxEncodedLength = 96 * 1024 * 1024

    private func materialize(name: String, base64: String) -> URL? {
        guard base64.count <= Self.maxEncodedLength else {
            presentAlert(title: "文件过大", message: "文件超过 70 MB，无法在应用内保存。")
            return nil
        }
        guard let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters) else {
            presentAlert(title: "文件读取失败", message: "内容不是有效的 base64 数据。")
            return nil
        }
        let safeName = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fileName = safeName.isEmpty ? "file" : safeName
        try? FileManager.default.createDirectory(
            at: filesDirectory,
            withIntermediateDirectories: true
        )
        let target = filesDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            presentAlert(title: "文件写入失败", message: error.localizedDescription)
            return nil
        }
    }

    private func saveFile(name: String, mime: String?, base64: String) {
        guard let url = materialize(name: name, base64: base64) else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 1,
                height: 1
            )
        }
        present(controller, animated: true)
    }

    private func previewFile(name: String, mime: String?, base64: String) {
        guard let url = materialize(name: name, base64: base64) else { return }
        previewFileURL = url
        let controller = QLPreviewController()
        controller.dataSource = self
        present(controller, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        present(alert, animated: true)
    }
}

// MARK: - WKScriptMessageHandler

extension WebViewController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == BridgeScript.handlerName,
              let body = message.body as? [String: Any]
        else { return }
        handleBridgeMessage(body)
    }
}

// MARK: - WKNavigationDelegate

extension WebViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        if url.isFileURL || isLocalURL(url) || url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        // 页面里的外链一律交给系统浏览器，别让 WebView 变成没有返回键的野页面。
        decisionHandler(.cancel)
        openExternally(url)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        showLoadError("页面加载失败：\(error.localizedDescription)")
    }

    /// WebContent 进程被系统回收（内存压力）时页面会变白，重新加载即可，
    /// IndexedDB 里的会话不会丢。
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

// MARK: - WKUIDelegate

extension WebViewController: WKUIDelegate {
    /// 新窗口：页面里 target=_blank 与 window.open 都走这里。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url, !isLocalURL(url) {
            openExternally(url)
        }
        return nil
    }

    /// iOS 15 起麦克风要单独授权，页面自己再处理一次会二次弹窗，这里直接放行。
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.grant)
    }

    // 页面里的 <input type=file> 交给 WebKit 默认处理（照片图库 / 选取文件）。
    // 不实现 runOpenPanelWith：WKOpenPanelParameters 在 SDK 里标成了 iOS 18.4+，
    // 实现它会把最低版本顶到 18.4，而默认行为在 iOS 15 上已经够用。
}

// MARK: - QLPreviewControllerDataSource

extension WebViewController: QLPreviewControllerDataSource {
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewFileURL == nil ? 0 : 1
    }

    func previewController(
        _ controller: QLPreviewController,
        previewItemAt index: Int
    ) -> QLPreviewItem {
        guard let url = previewFileURL else {
            return NSURL(fileURLWithPath: "")
        }
        return url as NSURL
    }
}