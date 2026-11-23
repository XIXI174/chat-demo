//
//  LocalServer.swift
//  ChatDemo
//
//  只在 127.0.0.1 上服务的极简静态文件服务器。
//
//  为什么需要它：WKWebView 直接打开 file:// 页面时，该页面不是 secure context，
//  getUserMedia（语音输入）不可用，IndexedDB 在 file:// 下也会抛 SecurityError。
//  127.0.0.1 属于 loopback，被 WebKit 视为 potentially trustworthy origin，
//  因此浏览器里的一切能力（IndexedDB、localStorage、麦克风、剪贴板）都正常可用。
//

import Foundation
import Network

/// 解析后的 HTTP 请求头。只处理静态资源需要的字段。
struct LocalHTTPRequest {
    let method: String
    let target: String
    let keepAlive: Bool
    let contentLength: Int

    init?(head: [UInt8]) {
        guard let text = String(bytes: head, encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        self.method = String(parts[0]).uppercased()
        self.target = String(parts[1])

        // HTTP/1.0 默认短连接，HTTP/1.1 默认长连接，可被 Connection 头覆盖。
        let isHTTP10 = requestLine.contains("HTTP/1.0")
        var explicitClose: Bool?
        var length = 0
        for line in lines.dropFirst() {
            guard !line.isEmpty, let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            switch name {
            case "connection":
                explicitClose = value.lowercased().contains("close")
            case "content-length":
                length = Int(value) ?? 0
            default:
                break
            }
        }
        self.keepAlive = !(explicitClose ?? isHTTP10)
        self.contentLength = max(0, min(length, 8 * 1024 * 1024))
    }
}

final class LocalServer {
    private static let headerSeparator: [UInt8] = [13, 10, 13, 10]
    private static let mimeTypes: [String: String] = [
        "html": "text/html; charset=utf-8",
        "htm": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "txt": "text/plain; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "ico": "image/x-icon",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "ttf": "font/ttf",
        "otf": "font/otf",
        "wasm": "application/wasm",
        "mp3": "audio/mpeg",
        "wav": "audio/wav",
    ]

    private let root: URL
    private let queue = DispatchQueue(label: "chatdemo.local-server", qos: .userInitiated)
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    init(root: URL) {
        self.root = root.standardizedFileURL
    }

    /// 启动服务器并返回实际监听端口。
    func start() throws -> UInt16 {
        do {
            return try listen(loopbackOnly: true)
        } catch {
            // 极少数情况下 loopback 绑定拿不到端口，退回默认绑定（仍是本机进程独占端口）。
            return try listen(loopbackOnly: false)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func listen(loopbackOnly: Bool) throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.acceptLocalOnly = loopbackOnly
        if loopbackOnly {
            parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        }

        let listener = try NWListener(using: parameters)
        self.listener = listener

        let ready = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var failure: Error?
        var resolvedPort: UInt16?

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                lock.lock()
                resolvedPort = listener.port?.rawValue
                lock.unlock()
                ready.signal()
            case .failed(let error):
                lock.lock()
                failure = error
                lock.unlock()
                ready.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) != .timedOut else {
            listener.cancel()
            throw ServerError.startTimeout
        }
        lock.lock()
        let error = failure
        let port = resolvedPort
        lock.unlock()
        listener.stateUpdateHandler = nil

        if let error {
            listener.cancel()
            throw error
        }
        guard let port, port != 0 else {
            listener.cancel()
            throw ServerError.missingPort
        }
        self.port = port
        return port
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: [])
    }

    /// 累积字节流，按 `\r\n\r\n` 切出请求，支持 keep-alive 上的连续请求。
    private func receive(on connection: NWConnection, buffer: [UInt8]) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(contentsOf: data)
            }
            // 单个请求头上限，防止畸形请求把内存吃满。
            if buffer.count > 512 * 1024 {
                connection.cancel()
                return
            }

            var remaining = buffer
            var keepAlive = true
            while keepAlive, let separator = Self.findHeaderSeparator(remaining) {
                let head = Array(remaining[0..<separator])
                let bodyStart = separator + Self.headerSeparator.count
                guard let request = LocalHTTPRequest(head: head) else {
                    connection.cancel()
                    return
                }
                let requestEnd = bodyStart + request.contentLength
                guard remaining.count >= requestEnd else {
                    // 请求体还没到齐，等下一次 receive 再切。
                    break
                }
                remaining = Array(remaining[requestEnd...])
                let response = self.response(for: request)
                connection.send(content: response, completion: .contentProcessed { _ in })
                keepAlive = request.keepAlive
            }

            if !keepAlive {
                connection.cancel()
                return
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: remaining)
        }
    }

    private static func findHeaderSeparator(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= headerSeparator.count else { return nil }
        let last = bytes.count - headerSeparator.count
        for index in 0...last where bytes[index] == 13
            && bytes[index + 1] == 10
            && bytes[index + 2] == 13
            && bytes[index + 3] == 10
        {
            return index
        }
        return nil
    }

    private func response(for request: LocalHTTPRequest) -> Data {
        let isHead = request.method == "HEAD"
        guard request.method == "GET" || isHead else {
            return Self.simpleResponse(status: "405 Method Not Allowed", isHead: false)
        }
        guard let url = fileURL(for: request.target) else {
            return Self.simpleResponse(status: "404 Not Found", isHead: isHead)
        }
        guard let data = try? Data(contentsOf: url) else {
            return Self.simpleResponse(status: "404 Not Found", isHead: isHead)
        }
        let mime = Self.mimeTypes[url.pathExtension.lowercased()] ?? "application/octet-stream"
        var head = "HTTP/1.1 200 OK\r\n"
        head += "Content-Type: \(mime)\r\n"
        head += "Content-Length: \(data.count)\r\n"
        // 页面与资源同源、名字带内容哈希，但仍禁用缓存避免升级后拿到旧包。
        head += "Cache-Control: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        head += "\r\n"
        var output = Data(head.utf8)
        if !isHead {
            output.append(data)
        }
        return output
    }

    private static func simpleResponse(status: String, isHead: Bool) -> Data {
        let body = status
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: text/plain; charset=utf-8\r\n"
        head += "Content-Length: \(body.utf8.count)\r\n"
        head += "\r\n"
        var output = Data(head.utf8)
        if !isHead {
            output.append(contentsOf: body.utf8)
        }
        return output
    }

    /// 把请求路径映射到 bundle 内文件，拒绝目录穿越。
    private func fileURL(for target: String) -> URL? {
        var path = target
        if let index = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<index])
        }
        guard let decoded = path.removingPercentEncoding else { return nil }
        let relative = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        guard !relative.contains("..") else { return nil }
        let candidate = relative.isEmpty
            ? root.appendingPathComponent("index.html")
            : root.appendingPathComponent(relative)
        let standardized = candidate.standardizedFileURL
        guard standardized.path.hasPrefix(root.path) else { return nil }
        return standardized
    }

    enum ServerError: LocalizedError {
        case startTimeout
        case missingPort

        var errorDescription: String? {
            switch self {
            case .startTimeout: return "本地服务启动超时"
            case .missingPort: return "本地服务没有拿到监听端口"
            }
        }
    }
}