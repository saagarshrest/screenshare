import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

struct DisplaySize: Equatable {
    let title: String
    let width: Int
    let height: Int
    static let all = [
        DisplaySize(title: "Phone · bigger text (1280 × 576)", width: 1280, height: 576),
        DisplaySize(title: "Phone · more space (1600 × 720)", width: 1600, height: 720),
        DisplaySize(title: "Widescreen 16:9 (1600 × 900)", width: 1600, height: 900),
        DisplaySize(title: "Portrait · bigger text (576 × 1280)", width: 576, height: 1280),
        DisplaySize(title: "Portrait · more space (720 × 1600)", width: 720, height: 1600),
    ]
}

struct StreamQuality: Equatable {
    let title: String
    let maxWidth: Int
    let bitrate: Int
    let jpeg: CGFloat
    // Long side capped at 1920: the most phone H.264 decoders handle at 60 fps.
    static let all = [
        StreamQuality(title: "Fast (best for Wi‑Fi)", maxWidth: 1280, bitrate: 5_000_000, jpeg: 0.55),
        StreamQuality(title: "Balanced", maxWidth: 1920, bitrate: 10_000_000, jpeg: 0.7),
        StreamQuality(title: "Sharp (best over USB)", maxWidth: 1920, bitrate: 20_000_000, jpeg: 0.82),
    ]
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let server = StreamServer()
    private let video = VideoServer()
    private var encoder: H264Encoder?
    private let encoderLock = NSLock()
    private var jpegQuality: CGFloat = 0.7
    private var webViewers = 0
    private var appViewers = 0
    private let discovery = Discovery()
    private let capturer = Capturer()
    private var display: VirtualDisplay?
    private var running = false
    private var startedByPhone = false
    private var viewerCount = 0
    private var autoStopWork: DispatchWorkItem?
    private var qrWindow: NSPanel?
    private let defaults = UserDefaults.standard

    private var sizeIndex: Int {
        get { min(defaults.object(forKey: "size") as? Int ?? 1, DisplaySize.all.count - 1) }
        set { defaults.set(newValue, forKey: "size") }
    }
    private var qualityIndex: Int {
        get { min(defaults.object(forKey: "quality") as? Int ?? 1, StreamQuality.all.count - 1) }
        set { defaults.set(newValue, forKey: "quality") }
    }
    private var hiDPI: Bool {
        get { defaults.object(forKey: "hidpi") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "hidpi") }
    }
    private var extraScreens: [Int: ExtraScreen] = [:]
    private var multiDisplay: Bool {
        get { defaults.object(forKey: "multiDisplay") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "multiDisplay") }
    }
    private var playSound: Bool {
        get { defaults.object(forKey: "sound") as? Bool ?? false }
        set { defaults.set(newValue, forKey: "sound") }
    }
    private var autoStart: Bool {
        get { defaults.object(forKey: "autostart") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autostart") }
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        capturer.onPixelBuffer = { [weak self] buffer in
            guard let self else { return }
            if self.video.hasViewers { self.currentEncoder()?.encode(buffer) }
            if self.server.hasViewers, let jpeg = self.capturer.jpeg(from: buffer, quality: self.jpegQuality) {
                self.server.broadcast(frame: jpeg)
            }
        }
        capturer.onAudio = { [weak self] pcm in
            guard let self, self.video.hasViewers else { return }
            self.video.send(audio: pcm)
        }
        capturer.onStop = { [weak self] _ in DispatchQueue.main.async { self?.stop() } }
        server.onViewerCountChanged = { [weak self] in self?.webViewers = $0; self?.viewersChanged() }
        video.onViewerCountChanged = { [weak self] in self?.appViewers = $0; self?.viewersChanged() }
        video.onNeedKeyframe = { [weak self] channel in
            guard let self else { return }
            if channel == 0 { self.currentEncoder()?.requestKeyframe() }
            else { DispatchQueue.main.async { self.extraScreens[channel]?.requestKeyframe() } }
        }
        video.multiDisplay = multiDisplay
        video.onExtraChannelsChanged = { [weak self] in self?.updateExtraScreens($0) }

        do {
            try server.start()
            try video.start()
        } catch {
            alert("Couldn't start the stream server", "Another app may be using ports 8780–8783.\n\n\(error.localizedDescription)")
        }
        discovery.start()
        broadcast(status: "Ready. Your Mac's screen will appear in a moment…")

        // Ask for Screen Recording permission up front so the first connection just works.
        if !defaults.bool(forKey: "askedCapture") {
            defaults.set(true, forKey: "askedCapture")
            CGRequestScreenCaptureAccess()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        display = nil
    }

    // MARK: Start / stop

    private func start(byPhone: Bool = false) {
        guard !running else { return }
        // Don't trust CGPreflightScreenCaptureAccess: for ad-hoc signed apps it often
        // says "no" even when permission is on. Just try to capture and report a real failure.
        let size = DisplaySize.all[sizeIndex]
        guard let display = VirtualDisplay(width: size.width, height: size.height, hiDPI: hiDPI) else {
            alert("Couldn't create the extra display", "macOS refused to create a virtual display.")
            return
        }
        self.display = display
        running = true
        startedByPhone = byPhone
        updateIcon()

        let quality = StreamQuality.all[qualityIndex]
        let (w, h) = outputSize(for: display.pixelSize, maxWidth: quality.maxWidth)
        jpegQuality = quality.jpeg
        broadcast(status: "Starting your Mac's display…")

        video.reset(width: w, height: h)
        let encoder = H264Encoder(width: w, height: h, bitrate: quality.bitrate, fps: 60)
        encoder?.onConfig = { [weak self] in self?.video.send(config: $0) }
        encoder?.onFrame = { [weak self] data, isKey, _ in self?.video.send(frame: data, isKey: isKey) }
        setEncoder(encoder)

        Task { [weak self] in
            guard let self else { return }
            do {
                self.capturer.captureAudio = self.playSound
                try await self.capturer.start(displayID: display.displayID, outputWidth: w, outputHeight: h)
            } catch {
                await MainActor.run {
                    self.stop()
                    self.broadcast(status: "Allow Screen Recording for ShareScreen on your Mac, then reopen it.")
                    self.alert("Couldn't capture the extra display",
                               "Check that ShareScreen is on in System Settings → Privacy & Security → Screen Recording, then quit and reopen it.\n\n\(error.localizedDescription)")
                }
            }
        }
    }

    private func stop() {
        guard running else { return }
        running = false
        startedByPhone = false
        autoStopWork?.cancel()
        let capturer = self.capturer
        Task { await capturer.stop() }
        display = nil // removes the monitor from macOS
        setEncoder(nil)
        broadcast(status: "Your Mac's display is off. Start it from the Mac menu bar.")
        updateIcon()
    }

    /// Create a display for each extra phone; remove it when that phone leaves.
    private func updateExtraScreens(_ channels: Set<Int>) {
        for (channel, screen) in extraScreens where !channels.contains(channel) {
            screen.stop()
            extraScreens[channel] = nil
        }
        for channel in channels where extraScreens[channel] == nil {
            extraScreens[channel] = ExtraScreen(
                channel: channel, size: DisplaySize.all[sizeIndex], hiDPI: hiDPI,
                quality: StreamQuality.all[qualityIndex], video: video,
                outputSize: { [weak self] in self?.outputSize(for: $0, maxWidth: $1) ?? (1280, 720) })
        }
    }

    private func restartIfRunning() {
        guard running else { return }
        let byPhone = startedByPhone
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.start(byPhone: byPhone) }
    }

    private func currentEncoder() -> H264Encoder? {
        encoderLock.lock(); defer { encoderLock.unlock() }
        return encoder
    }

    private func setEncoder(_ new: H264Encoder?) {
        encoderLock.lock()
        let old = encoder
        encoder = new
        encoderLock.unlock()
        old?.invalidate()
    }

    private func broadcast(status: String) {
        server.broadcast(status: status)
        video.send(status: status)
    }

    private func viewersChanged() {
        let count = webViewers + appViewers
        viewerCount = count
        updateIcon()
        if count > 0 {
            autoStopWork?.cancel()
            if autoStart && !running { start(byPhone: true) }
        } else if running && startedByPhone {
            // Phone left: remove the extra display after a short grace period.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.viewerCount == 0 else { return }
                self.stop()
            }
            autoStopWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
        }
    }

    private func outputSize(for pixels: CGSize, maxWidth: Int) -> (Int, Int) {
        // Cap the LONG side, so portrait displays don't send huge frames.
        let scale = min(1, Double(maxWidth) / max(pixels.width, pixels.height))
        let w = Int(pixels.width * scale) & ~1
        let h = Int(pixels.height * scale) & ~1
        return (w, h)
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let state: String
        if running { state = viewerCount > 0 ? "Streaming to \(viewerCount == 1 ? "phone" : "\(viewerCount) viewers")" : "Display on · waiting for phone" }
        else { state = autoStart ? "Waiting for phone" : "Off" }
        let header = NSMenuItem(title: state, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let ip = NetInfo.primaryIP() {
            let address = NSMenuItem(title: "http://\(ip):\(StreamServer.httpPort)", action: nil, keyEquivalent: "")
            address.isEnabled = false
            menu.addItem(address)
        }
        menu.addItem(.separator())

        menu.addItem(item(running ? "Turn Off Extra Display" : "Turn On Extra Display", #selector(toggle), key: "d"))
        menu.addItem(item("Show QR Code…", #selector(showQR), key: "q"))
        menu.addItem(.separator())

        let sizeMenu = NSMenu()
        for (i, size) in DisplaySize.all.enumerated() {
            let entry = item(size.title, #selector(pickSize(_:)))
            entry.tag = i
            entry.state = i == sizeIndex ? .on : .off
            sizeMenu.addItem(entry)
        }
        sizeMenu.addItem(.separator())
        let retina = item("Sharp text (HiDPI)", #selector(toggleHiDPI))
        retina.state = hiDPI ? .on : .off
        sizeMenu.addItem(retina)
        let sizeItem = NSMenuItem(title: "Display Size", action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        let qualityMenu = NSMenu()
        for (i, quality) in StreamQuality.all.enumerated() {
            let entry = item(quality.title, #selector(pickQuality(_:)))
            entry.tag = i
            entry.state = i == qualityIndex ? .on : .off
            qualityMenu.addItem(entry)
        }
        let qualityItem = NSMenuItem(title: "Stream Quality", action: nil, keyEquivalent: "")
        qualityItem.submenu = qualityMenu
        menu.addItem(qualityItem)

        let multi = item("Each Phone Gets Its Own Display", #selector(toggleMultiDisplay))
        multi.state = multiDisplay ? .on : .off
        menu.addItem(multi)

        let sound = item("Play Sound on Phone", #selector(toggleSound))
        sound.state = playSound ? .on : .off
        menu.addItem(sound)

        let auto = item("Turn On When Phone Connects", #selector(toggleAutoStart))
        auto.state = autoStart ? .on : .off
        menu.addItem(auto)

        menu.addItem(.separator())
        menu.addItem(item("Quit ShareScreen", #selector(quit), key: "q", modifiers: [.command]))
    }

    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: modifiers.isEmpty ? "" : key)
        entry.keyEquivalentModifierMask = modifiers
        entry.target = self
        return entry
    }

    @objc private func toggle() { running ? stop() : start() }
    @objc private func pickSize(_ sender: NSMenuItem) { sizeIndex = sender.tag; restartIfRunning() }
    @objc private func pickQuality(_ sender: NSMenuItem) { qualityIndex = sender.tag; restartIfRunning() }
    @objc private func toggleHiDPI() { hiDPI.toggle(); restartIfRunning() }
    @objc private func toggleAutoStart() { autoStart.toggle() }
    @objc private func toggleMultiDisplay() {
        multiDisplay.toggle()
        video.multiDisplay = multiDisplay // applies to phones that connect from now on
    }
    @objc private func toggleSound() { playSound.toggle(); restartIfRunning() }
    @objc private func quit() { stop(); NSApp.terminate(nil) }

    private func updateIcon() {
        let symbol = running ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "ShareScreen")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = running ? "ShareScreen · extra display on" : "ShareScreen"
    }

    // MARK: QR window

    @objc private func showQR() {
        qrWindow?.close()
        let ip = NetInfo.primaryIP() ?? "127.0.0.1"
        let url = "http://\(ip):\(StreamServer.httpPort)/"

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 470),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Open on your phone"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let qr = NSImageView(image: qrImage(for: url))
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.widthAnchor.constraint(equalToConstant: 240).isActive = true
        qr.heightAnchor.constraint(equalToConstant: 240).isActive = true

        let link = NSTextField(labelWithString: url)
        link.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        link.isSelectable = true

        let help = NSTextField(wrappingLabelWithString:
            "Scan with your phone camera, or just open the ShareScreen app on Android — it finds this Mac automatically.\n\n"
            + "USB (lowest lag): with USB debugging on, run\n"
            + "adb reverse tcp:8780 tcp:8780 && adb reverse tcp:8781 tcp:8781")
        help.font = .systemFont(ofSize: 11)
        help.textColor = .secondaryLabelColor
        help.preferredMaxLayoutWidth = 300

        [qr, link, help].forEach(stack.addArrangedSubview)
        panel.contentView = stack
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        qrWindow = panel
    }

    private func qrImage(for text: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let cg = CIContext().createCGImage(output, from: output.extent)
        else { return NSImage() }
        return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
    }

    private func alert(_ title: String, _ text: String) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}
