import Foundation

/// One more phone, one more monitor: its own virtual display, capture and encoder,
/// streaming on its own VideoServer channel. Used when "Each Phone Gets Its Own
/// Display" is on and a second (or third) phone connects.
final class ExtraScreen {
    let channel: Int
    private let display: VirtualDisplay
    private let capturer = Capturer()
    private var encoder: H264Encoder?
    private let lock = NSLock()
    private weak var video: VideoServer?

    init?(channel: Int, size: DisplaySize, hiDPI: Bool, quality: StreamQuality, video: VideoServer,
          outputSize: (CGSize, Int) -> (Int, Int)) {
        guard let display = VirtualDisplay(width: size.width, height: size.height, hiDPI: hiDPI,
                                           serial: UInt32(channel + 1)) else { return nil }
        self.channel = channel
        self.display = display
        self.video = video
        let (w, h) = outputSize(display.pixelSize, quality.maxWidth)
        video.reset(width: w, height: h, channel: channel)
        let encoder = H264Encoder(width: w, height: h, bitrate: quality.bitrate, fps: 60)
        encoder?.onConfig = { [weak video] in video?.send(config: $0, channel: channel) }
        encoder?.onFrame = { [weak video] data, isKey, _ in video?.send(frame: data, isKey: isKey, channel: channel) }
        self.encoder = encoder
        capturer.onPixelBuffer = { [weak self] buffer in self?.currentEncoder()?.encode(buffer) }
        Task { [capturer, displayID = display.displayID] in
            try? await capturer.start(displayID: displayID, outputWidth: w, outputHeight: h)
        }
    }

    func requestKeyframe() { currentEncoder()?.requestKeyframe() }

    private func currentEncoder() -> H264Encoder? {
        lock.lock(); defer { lock.unlock() }
        return encoder
    }

    /// Stops capture; the monitor disappears when this object is released.
    func stop() {
        let capturer = self.capturer
        Task { await capturer.stop() }
        lock.lock()
        let old = encoder
        encoder = nil
        lock.unlock()
        old?.invalidate()
    }
}
