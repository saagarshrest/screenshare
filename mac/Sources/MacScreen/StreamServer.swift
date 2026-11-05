import Foundation
import Network

/// Two tiny servers on the local network:
///  - HTTP on 8780 serves the viewer page (and /ping for the Android app)
///  - WebSocket on 8781 pushes JPEG frames to every connected viewer
/// Slow viewers never build a backlog: each one holds at most one pending frame,
/// and newer frames replace it.
final class StreamServer {
    static let httpPort: UInt16 = 8780
    static let wsPort: UInt16 = 8781

    var onViewerCountChanged: ((Int) -> Void)?

    private final class Viewer {
        let connection: NWConnection
        var sending = false
        var pending: Data?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private let queue = DispatchQueue(label: "macscreen.server")
    private var httpListener: NWListener?
    private var wsListener: NWListener?
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var connecting: [ObjectIdentifier: Viewer] = [:]
    private var lastFrame: Data?
    private var statusText = "Starting your Mac's display…"

    func start() throws {
        let http = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: Self.httpPort)!)
        http.newConnectionHandler = { [weak self] in self?.serveHTTP($0) }
        http.start(queue: queue)
        httpListener = http

        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 16 * 1024 * 1024
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let wsListener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.wsPort)!)
        wsListener.newConnectionHandler = { [weak self] in self?.addViewer($0) }
        wsListener.start(queue: queue)
        self.wsListener = wsListener
    }

    /// Push a new frame to everyone.
    func broadcast(frame: Data) {
        queue.async {
            self.lastFrame = frame
            for viewer in self.viewers.values { self.send(frame, to: viewer) }
        }
    }

    /// Show a message on every viewer (and remember it for new ones).
    func broadcast(status: String) {
        queue.async {
            self.statusText = status
            self.lastFrame = nil
            for viewer in self.viewers.values { self.sendText(status, to: viewer) }
        }
    }

    // MARK: HTTP

    private func serveHTTP(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { data, _, _, _ in
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let isPing = path.hasPrefix("/ping")
            let body = Data((isPing ? "macscreen h264:\(VideoServer.port)" : ViewerPage.html).utf8)
            let type = isPing ? "text/plain" : "text/html; charset=utf-8"
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n"
                + "Cache-Control: no-store\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }

    // MARK: WebSocket viewers

    private func addViewer(_ connection: NWConnection) {
        let viewer = Viewer(connection)
        // Keep a strong reference while connecting; otherwise the viewer (and its
        // connection) is freed before the WebSocket handshake finishes.
        connecting[ObjectIdentifier(viewer)] = viewer
        connection.stateUpdateHandler = { [weak self, weak viewer] state in
            guard let self, let viewer else { return }
            switch state {
            case .ready:
                self.connecting.removeValue(forKey: ObjectIdentifier(viewer))
                self.viewers[ObjectIdentifier(viewer)] = viewer
                self.notifyCount()
                if let frame = self.lastFrame { self.send(frame, to: viewer) }
                else { self.sendText(self.statusText, to: viewer) }
                self.receiveLoop(viewer)
            case .failed, .cancelled:
                self.remove(viewer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ viewer: Viewer) {
        viewer.connection.receiveMessage { [weak self, weak viewer] _, _, _, error in
            guard let self, let viewer else { return }
            if error != nil { self.remove(viewer); return }
            self.receiveLoop(viewer)
        }
    }

    private func send(_ frame: Data, to viewer: Viewer) {
        if viewer.sending { viewer.pending = frame; return }
        viewer.sending = true
        let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        viewer.connection.send(content: frame, contentContext: context, isComplete: true,
                               completion: .contentProcessed { [weak self, weak viewer] error in
            guard let self, let viewer else { return }
            viewer.sending = false
            if error != nil { self.remove(viewer); return }
            if let next = viewer.pending {
                viewer.pending = nil
                self.send(next, to: viewer)
            }
        })
    }

    private func sendText(_ text: String, to viewer: Viewer) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "status", metadata: [meta])
        viewer.pending = nil
        viewer.connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                               completion: .contentProcessed { _ in })
    }

    private func remove(_ viewer: Viewer) {
        if connecting.removeValue(forKey: ObjectIdentifier(viewer)) != nil { viewer.connection.cancel() }
        guard viewers.removeValue(forKey: ObjectIdentifier(viewer)) != nil else { return }
        viewer.connection.cancel()
        notifyCount()
    }

    private let countLock = NSLock()
    private var _count = 0
    var hasViewers: Bool { countLock.lock(); defer { countLock.unlock() }; return _count > 0 }

    private func notifyCount() {
        let count = viewers.count
        countLock.lock(); _count = count; countLock.unlock()
        DispatchQueue.main.async { self.onViewerCountChanged?(count) }
    }
}
