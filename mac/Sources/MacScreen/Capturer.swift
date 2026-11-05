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
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "macscreen.capture", qos: .userInteractive)
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
        config.capturesAudio = false

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
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
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onPixelBuffer?(pixelBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
