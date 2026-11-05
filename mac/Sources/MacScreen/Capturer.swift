import CoreImage
import CoreMedia
import Foundation
import ImageIO
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit at up to 60 fps.
/// ScreenCaptureKit only delivers "complete" frames when something on screen changed,
/// so a static screen costs almost nothing.
final class Capturer: NSObject, SCStreamOutput, SCStreamDelegate {
    /// Raw frames, already scaled to the output size (called on the capture queue).
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?
    /// System sound as PCM s16le, 48 kHz, stereo (only when `captureAudio` is on).
    var onAudio: ((Data) -> Void)?
    var captureAudio = false
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "macscreen.capture", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "macscreen.audio", qos: .userInteractive)
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    enum CaptureError: LocalizedError {
        case displayNotFound
        var errorDescription: String? { "The virtual display didn't show up for screen capture." }
    }

    func start(displayID: CGDirectDisplayID, outputWidth: Int, outputHeight: Int, fps: Int32 = 60) async throws {
        // A freshly created virtual display can take a moment to appear.
        var target: SCDisplay?
        for _ in 0..<25 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            target = content.displays.first { $0.displayID == displayID }
            if target != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let target else { throw CaptureError.displayNotFound }

        let config = SCStreamConfiguration()
        config.width = outputWidth
        config.height = outputHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        // NV12 is what the H.264 hardware encoder wants: no colour conversion step.
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.queueDepth = 5
        config.showsCursor = true
        config.capturesAudio = captureAudio
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// JPEG for the browser viewer (fallback path).
    func jpeg(from buffer: CVPixelBuffer, quality: CGFloat) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let options = [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): quality]
        return ciContext.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio { handleAudio(sampleBuffer); return }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onPixelBuffer?(pixelBuffer)
    }

    /// Float32 (planar or interleaved) → interleaved Int16 stereo.
    private func handleAudio(_ sample: CMSampleBuffer) {
        guard let onAudio, sample.isValid,
              let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return }
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0 else { return }
        var blockBuffer: CMBlockBuffer?
        var needed = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: &needed, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: needed, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let listPtr = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample, bufferListSizeNeededOut: nil, bufferListOut: listPtr, bufferListSize: needed,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, blockBufferOut: &blockBuffer) == noErr
        else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(listPtr)
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let channels = Int(asbd.mChannelsPerFrame)
        var out = Data(count: frames * 4)
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            let pcm = dst.bindMemory(to: Int16.self)
            func sample(_ ch: Int, _ i: Int) -> Float {
                let c = min(ch, channels - 1)
                if planar {
                    guard c < buffers.count, let data = buffers[c].mData else { return 0 }
                    return data.assumingMemoryBound(to: Float.self)[i]
                }
                guard let data = buffers[0].mData else { return 0 }
                return data.assumingMemoryBound(to: Float.self)[i * channels + c]
            }
            for i in 0..<frames {
                for ch in 0..<2 {
                    let v = max(-1, min(1, sample(ch, i)))
                    pcm[i * 2 + ch] = Int16(v * 32767).littleEndian
                }
            }
        }
        onAudio(out)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
