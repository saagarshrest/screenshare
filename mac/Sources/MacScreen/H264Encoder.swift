import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Hardware H.264 encoder tuned for the lowest possible delay:
/// real-time mode, low-latency rate control, no B-frames (no frame reordering).
/// Output is Annex-B (start-code) NAL units, which Android's MediaCodec reads directly.
final class H264Encoder {
    /// SPS+PPS in Annex-B form, sent before every keyframe.
    var onConfig: ((Data) -> Void)?
    /// One encoded frame (Annex-B), whether it is a keyframe, and its time in microseconds.
    var onFrame: ((Data, Bool, Int64) -> Void)?

    let width: Int
    let height: Int

    private var session: VTCompressionSession?
    private let queue = DispatchQueue(label: "macscreen.encoder", qos: .userInteractive)
    private var forceKeyframe = true
    private var lastBuffer: CVPixelBuffer?
    private static let startCode = Data([0, 0, 0, 1])

    init?(width: Int, height: Int, bitrate: Int, fps: Int) {
        self.width = width
        self.height = height

        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        if status != noErr || created == nil {
            // Fall back to a normal (still hardware) session.
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: nil,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        }
        guard status == noErr, let session = created else { return nil }

        func set(_ key: CFString, _ value: Any) { VTSessionSetProperty(session, key: key, value: value as CFTypeRef) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue!)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_ConstrainedHigh_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse!)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as NSNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as NSNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, (fps * 4) as NSNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 4 as NSNumber)
        // Cap short bursts (e.g. a full-screen change) so they don't clog Wi‑Fi.
        set(kVTCompressionPropertyKey_DataRateLimits, [bitrate / 8 * 2, 1] as CFArray)
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit { invalidate() }

    func invalidate() {
        queue.sync {
            if let session { VTCompressionSessionInvalidate(session) }
            session = nil
            lastBuffer = nil
        }
    }

    func encode(_ buffer: CVPixelBuffer) {
        queue.async {
            self.lastBuffer = buffer
            self.encodeNow(buffer)
        }
    }

    /// New viewer or a viewer that fell behind: send a fresh keyframe right away,
    /// even if the screen isn't changing.
    func requestKeyframe() {
        queue.async {
            self.forceKeyframe = true
            if let buffer = self.lastBuffer { self.encodeNow(buffer) }
        }
    }

    private func encodeNow(_ buffer: CVPixelBuffer) {
        guard let session else { return }
        var props: CFDictionary?
        if forceKeyframe {
            forceKeyframe = false
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
        }
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) {
            [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.handle(sample)
        }
    }

    private func handle(_ sample: CMSampleBuffer) {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKey = !notSync

        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            var config = Data()
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                let ok = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if ok == noErr, let pointer {
                    config.append(Self.startCode)
                    config.append(pointer, count: size)
                }
            }
            if !config.isEmpty { onConfig?(config) }
        }

        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let total = CMBlockBufferGetDataLength(block)
        var avcc = Data(count: total)
        let copied = avcc.withUnsafeMutableBytes { raw -> OSStatus in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: raw.baseAddress!)
        }
        guard copied == noErr else { return }

        // AVCC (4-byte length prefixes) → Annex-B (start codes).
        var annexB = Data(capacity: total + 32)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + 4 <= total {
                let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                offset += 4
                guard length > 0, offset + length <= total else { break }
                annexB.append(Self.startCode)
                annexB.append(bytes.baseAddress! + offset, count: length)
                offset += length
            }
        }
        let micros = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)) * 1_000_000)
        onFrame?(annexB, isKey, micros)
    }
}
