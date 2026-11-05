import Foundation
import Network

/// Raw TCP video stream for the Android app (port 8783). Lowest-overhead path:
/// no WebSocket, no browser. Each packet is
///   [type: 1 byte][length: 4 bytes big-endian][payload]
///   type 1 = config  (payload: width u32, height u32, SPS+PPS Annex-B)
///   type 2 = keyframe, type 3 = frame (Annex-B H.264)
///   type 4 = status text (UTF-8)
///   type 5 = audio (PCM s16le, 48 kHz, stereo)
/// If a viewer can't keep up, we drop frames until the next keyframe instead of
/// letting a backlog (= lag) build up.
///
/// Channels: channel 0 is the main extra display. With `multiDisplay` on, each
/// additional phone gets its own channel (1, 2, …) backed by its own display.
final class VideoServer {
    static let port: UInt16 = 8783

    var onViewerCountChanged: ((Int) -> Void)?
    /// Called (on any queue) when a viewer needs a fresh keyframe.
    var onNeedKeyframe: ((Int) -> Void)?
    /// Channels > 0 that currently have a phone (called on the main queue).
    var onExtraChannelsChanged: ((Set<Int>) -> Void)?
    /// Give each additional phone its own channel instead of sharing channel 0.
    var multiDisplay = false
    static let maxChannels = 3

    private final class Viewer {
        let connection: NWConnection
        var pendingBytes = 0
        var waitingForKeyframe = true
        var channel = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }

    /// About 1/4 s of video at the highest bitrate. More than this queued = falling behind.
    private let maxBacklog = 600_000

    private let queue = DispatchQueue(label: "macscreen.video", qos: .userInteractive)
    private var listener: NWListener?
    private var connecting: [ObjectIdentifier: Viewer] = [:]
    private var viewers: [ObjectIdentifier: Viewer] = [:]
    private var configs: [Int: Data] = [:]
    private var sizes: [Int: (width: Int, height: Int)] = [:]
    private var status = "Starting your Mac's display…"
    private let countLock = NSLock()
    private var _count = 0

    var hasViewers: Bool { countLock.lock(); defer { countLock.unlock() }; return _count > 0 }

    func start() throws {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.newConnectionHandler = { [weak self] in self?.add($0) }
        listener.start(queue: queue)
        self.listener = listener
    }

    /// The encoder changed size (new display or quality): forget the old config.
    func reset(width: Int, height: Int, channel: Int = 0) {
        queue.async {
            self.sizes[channel] = (width, height)
            self.configs[channel] = nil
            for viewer in self.viewers.values where viewer.channel == channel { viewer.waitingForKeyframe = true }
        }
    }

    func send(config annexB: Data, channel: Int = 0) {
        queue.async {
            let size = self.sizes[channel] ?? (0, 0)
            var payload = Data()
            payload.append(UInt32(size.width).bigEndianData)
            payload.append(UInt32(size.height).bigEndianData)
            payload.append(annexB)
            self.configs[channel] = payload
        }
    }

    func send(frame: Data, isKey: Bool, channel: Int = 0) {
        queue.async {
            var needKey = false
            let config = self.configs[channel]
            for viewer in self.viewers.values where viewer.channel == channel {
                if viewer.waitingForKeyframe {
                    guard isKey, let config else { needKey = true; continue }
                    viewer.waitingForKeyframe = false
                    self.write(type: 1, config, to: viewer)
                } else if viewer.pendingBytes > self.maxBacklog {
                    // Network can't keep up: skip ahead to a fresh keyframe.
                    viewer.waitingForKeyframe = true
                    needKey = true
                    continue
                } else if isKey, let config {
                    self.write(type: 1, config, to: viewer)
                }
                self.write(type: isKey ? 2 : 3, frame, to: viewer)
            }
            if needKey { self.onNeedKeyframe?(channel) }
        }
    }

    /// Sound goes only to phones that are already showing video and keeping up.
    func send(audio pcm: Data) {
        queue.async {
            for viewer in self.viewers.values where viewer.channel == 0 && !viewer.waitingForKeyframe && viewer.pendingBytes < self.maxBacklog {
                self.write(type: 5, pcm, to: viewer)
            }
        }
    }

    func send(status text: String) {
        queue.async {
            self.status = text
            for viewer in self.viewers.values where viewer.channel == 0 {
                viewer.waitingForKeyframe = true
                self.write(type: 4, Data(text.utf8), to: viewer)
            }
        }
    }

    // MARK: Connections

    private func add(_ connection: NWConnection) {
        let viewer = Viewer(connection)
        let id = ObjectIdentifier(viewer)
        connecting[id] = viewer
        connection.stateUpdateHandler = { [weak self, weak viewer] state in
            guard let self, let viewer else { return }
            switch state {
            case .ready:
                self.connecting.removeValue(forKey: id)
                viewer.channel = self.freeChannel()
                self.viewers[id] = viewer
                self.updateCount()
                let text = viewer.channel == 0 ? self.status : "Adding a display for this phone…"
                self.write(type: 4, Data(text.utf8), to: viewer)
                self.receiveLoop(viewer)
                self.onNeedKeyframe?(viewer.channel)
            case .failed, .cancelled:
                self.remove(viewer)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func receiveLoop(_ viewer: Viewer) {
        viewer.connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak viewer] data, _, done, error in
            guard let self, let viewer else { return }
            if let data, !data.isEmpty {
                // The phone reset its decoder and needs a keyframe.
                viewer.waitingForKeyframe = true
                self.onNeedKeyframe?(viewer.channel)
            }
            if done || error != nil { self.remove(viewer); return }
            self.receiveLoop(viewer)
        }
    }

    private func write(type: UInt8, _ payload: Data, to viewer: Viewer) {
        var packet = Data(capacity: payload.count + 5)
        packet.append(type)
        packet.append(UInt32(payload.count).bigEndianData)
        packet.append(payload)
        let count = packet.count
        viewer.pendingBytes += count
        viewer.connection.send(content: packet, completion: .contentProcessed { [weak self, weak viewer] error in
            guard let self, let viewer else { return }
            viewer.pendingBytes -= count
            if error != nil { self.remove(viewer) }
        })
    }

    private func remove(_ viewer: Viewer) {
        let id = ObjectIdentifier(viewer)
        let wasConnecting = connecting.removeValue(forKey: id) != nil
        let wasViewer = viewers.removeValue(forKey: id) != nil
        guard wasConnecting || wasViewer else { return }
        viewer.connection.cancel()
        if wasViewer { updateCount() }
    }

    /// Channel 0 unless multi-display is on and channel 0 is taken.
    private func freeChannel() -> Int {
        guard multiDisplay else { return 0 }
        let used = Set(viewers.values.map(\.channel))
        return (0..<Self.maxChannels).first { !used.contains($0) } ?? 0
    }

    private func updateCount() {
        let count = viewers.count
        let extra = Set(viewers.values.map(\.channel).filter { $0 > 0 })
        countLock.lock(); _count = count; countLock.unlock()
        DispatchQueue.main.async {
            self.onViewerCountChanged?(count)
            self.onExtraChannelsChanged?(extra)
        }
    }
}

private extension UInt32 {
    var bigEndianData: Data { withUnsafeBytes(of: self.bigEndian) { Data($0) } }
}
