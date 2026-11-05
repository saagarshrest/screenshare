import AVFoundation
import Network
import SwiftUI
import UIKit

/// Full-screen player. Tap to show or hide live stats.
struct PlayerView: UIViewRepresentable {
    let host: String
    let onDisconnect: () -> Void

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.onDisconnect = onDisconnect
        view.start(host: host)
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {}

    static func dismantleUIView(_ uiView: PlayerUIView, coordinator: ()) { uiView.stop() }
}

final class PlayerUIView: UIView {
    var onDisconnect: (() -> Void)?

    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var videoLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    private let status = UILabel()
    private let stats = UILabel()
    private var client: StreamClient?
    private let audio = PCMPlayer()
    private var format: CMVideoFormatDescription?
    private var videoSize = (0, 0)
    private var statsTimer: Timer?

    // Counters (updated on the network queue, read on main).
    private var bytesIn = 0
    private var frames = 0
    private var dropped = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspect

        status.textColor = UIColor(white: 0.6, alpha: 1)
        status.font = .systemFont(ofSize: 15)
        status.textAlignment = .center
        status.numberOfLines = 0
        status.text = "Connecting to your computer…"
        stats.textColor = .white
        stats.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stats.backgroundColor = UIColor(white: 0, alpha: 0.6)
        stats.numberOfLines = 0
        stats.isHidden = true
        stats.layer.cornerRadius = 6
        stats.clipsToBounds = true
        for v in [status, stats] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -48),
            stats.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 12),
            stats.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
        ])
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(toggleStats)))
    }

    required init?(coder: NSCoder) { fatalError() }

    func start(host: String) {
        let client = StreamClient(host: host, port: HostFinder.videoPort)
        client.onPacket = { [weak self] type, payload in self?.handle(type, payload) }
        client.onClose = { [weak self] in
            DispatchQueue.main.async { self?.stop(); self?.onDisconnect?() }
        }
        self.client = client
        client.start()
    }

    func stop() {
        client?.stop()
        client = nil
        audio.stop()
        statsTimer?.invalidate()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @objc private func toggleStats() {
        stats.isHidden.toggle()
        statsTimer?.invalidate()
        guard !stats.isHidden else { return }
        stats.text = " … "
        statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateStats() }
    }

    private func updateStats() {
        let mbps = Double(bytesIn) * 8 / 1_000_000
        stats.text = String(format: " %dx%d  %d fps \n %.1f Mbit/s \n dropped %d %@",
                            videoSize.0, videoSize.1, frames, mbps, dropped, audio.active ? "\n sound on " : "")
        bytesIn = 0; frames = 0
    }

    // MARK: Packets (network queue)

    private func handle(_ type: UInt8, _ payload: Data) {
        bytesIn += payload.count + 5
        switch type {
        case 1: configure(payload)
        case 2, 3: enqueue(payload, isKey: type == 2)
        case 4:
            let text = String(decoding: payload, as: UTF8.self)
            DispatchQueue.main.async { self.status.text = text; self.status.isHidden = false }
        case 5: audio.play(payload)
        default: break
        }
    }

    private func configure(_ payload: Data) {
        guard payload.count > 8 else { return }
        let w = Int(payload[0..<4].reduce(0) { $0 << 8 | UInt32($1) })
        let h = Int(payload[4..<8].reduce(0) { $0 << 8 | UInt32($1) })
        let nals = AnnexB.split(payload.subdata(in: 8..<payload.count))
        guard let sps = nals.first(where: { ($0.first ?? 0) & 0x1F == 7 }),
              let pps = nals.first(where: { ($0.first ?? 0) & 0x1F == 8 }) else { return }
        var desc: CMVideoFormatDescription?
        sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &desc)
            }
        }
        guard let desc else { return }
        if (w, h) != videoSize { DispatchQueue.main.async { self.videoLayer.flush() } }
        videoSize = (w, h)
        format = desc
    }

    private func enqueue(_ payload: Data, isKey: Bool) {
        guard let format else { if isKey { client?.requestKeyframe() }; return }
        // Annex-B start codes -> 4-byte length prefixes (AVCC), which the layer expects.
        var avcc = Data(capacity: payload.count + 16)
        for nal in AnnexB.split(payload) {
            var length = UInt32(nal.count).bigEndian
            avcc.append(Data(bytes: &length, count: 4))
            avcc.append(nal)
        }
        var block: CMBlockBuffer?
        let count = avcc.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: count,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        avcc.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                                  offsetIntoDestination: 0, dataLength: count) }
        var sample: CMSampleBuffer?
        var size = count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &size,
                                        sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !isKey {
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        DispatchQueue.main.async {
            let layer = self.videoLayer
            if layer.status == .failed {
                layer.flush()
                self.client?.requestKeyframe()
                return
            }
            guard layer.isReadyForMoreMediaData else { self.dropped += 1; return }
            layer.enqueue(sample)
            self.frames += 1
            if !self.status.isHidden { self.status.isHidden = true }
        }
    }
}

// MARK: - Network

/// [type u8][length u32 BE][payload] packets over TCP 8783.
final class StreamClient {
    var onPacket: ((UInt8, Data) -> Void)?
    var onClose: (() -> Void)?

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "sharescreen.net", qos: .userInteractive)
    private var closed = false
    private var lastKeyRequest = Date.distantPast

    init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        params.serviceClass = .interactiveVideo
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.readHeader()
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func stop() { closed = true; connection.cancel() }

    func requestKeyframe() {
        guard Date().timeIntervalSince(lastKeyRequest) > 0.5 else { return }
        lastKeyRequest = Date()
        connection.send(content: Data([1]), completion: .idempotent)
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        onClose?()
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, done, error in
            guard let self else { return }
            guard let data, data.count == 5, error == nil else { self.close(); return }
            let type = data[data.startIndex]
            let length = data.dropFirst().reduce(0) { $0 << 8 | Int($1) }
            guard length >= 0, length < 32 << 20 else { self.close(); return }
            if length == 0 { self.onPacket?(type, Data()); self.readHeader(); return }
            self.readBody(type, length)
            if done { self.close() }
        }
    }

    private func readBody(_ type: UInt8, _ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else { self.close(); return }
            self.onPacket?(type, data)
            self.readHeader()
        }
    }
}

enum AnnexB {
    /// Annex-B bytes -> NAL units without start codes.
    static func split(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(start: Int, payload: Int)] = []
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                starts.append((i > 0 && bytes[i - 1] == 0 ? i - 1 : i, i + 3))
                i += 3
            } else {
                i += 1
            }
        }
        return starts.enumerated().compactMap { n, s in
            let end = n + 1 < starts.count ? starts[n + 1].start : bytes.count
            return s.payload < end ? Data(bytes[s.payload..<end]) : nil
        }
    }
}

// MARK: - Sound

/// PCM s16le 48 kHz stereo -> AVAudioEngine, with at most ~100 ms queued.
final class PCMPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private var started = false
    private var queued = 0
    private let lock = NSLock()
    private(set) var active = false

    func play(_ pcm: Data) {
        if !started { start() }
        guard started else { return }
        lock.lock()
        let backlog = queued
        lock.unlock()
        if backlog > 5 { return } // falling behind: drop to keep sound in sync
        let frames = pcm.count / 4
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                channels[0][i] = Float(Int16(littleEndian: s[i * 2])) / 32768
                channels[1][i] = Float(Int16(littleEndian: s[i * 2 + 1])) / 32768
            }
        }
        lock.lock(); queued += 1; lock.unlock()
        node.scheduleBuffer(buffer) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }

    private func start() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
            try AVAudioSession.sharedInstance().setActive(true)
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            try engine.start()
            node.play()
            started = true
            active = true
        } catch {
            started = false
        }
    }

    func stop() {
        guard started else { return }
        node.stop()
        engine.stop()
        started = false
        active = false
    }
}
