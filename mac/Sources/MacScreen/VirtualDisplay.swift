import CoreGraphics
import CGVirtualDisplayPrivate
import Foundation

/// An extra monitor that only exists in software. macOS treats it like a real
/// display: you can drag windows onto it and arrange it in System Settings.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let logicalSize: CGSize
    let pixelSize: CGSize

    var displayID: CGDirectDisplayID { display.displayID }

    init?(width: Int, height: Int, hiDPI: Bool) {
        let scale = hiDPI ? 2 : 1
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.queue = DispatchQueue.main
        descriptor.name = "Phone Screen"
        descriptor.maxPixelsWide = UInt32(width * scale)
        descriptor.maxPixelsHigh = UInt32(height * scale)
        // Roughly a 13" laptop's density, so macOS picks sensible UI sizes.
        let mmPerPoint = 25.4 / 110.0
        descriptor.sizeInMillimeters = CGSize(width: Double(width) * mmPerPoint,
                                              height: Double(height) * mmPerPoint)
        descriptor.vendorID = 0x5A57
        descriptor.productID = 0x0001
        descriptor.serialNum = 0x0001
        descriptor.terminationHandler = { _, _ in }

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = hiDPI ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt32(width), height: UInt32(height), refreshRate: 60)]
        guard display.applySettings(settings) else { return nil }

        self.display = display
        self.logicalSize = CGSize(width: width, height: height)
        self.pixelSize = CGSize(width: width * scale, height: height * scale)
    }
    // The display disappears when this object is released.
}
