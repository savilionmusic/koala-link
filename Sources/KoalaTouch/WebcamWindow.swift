import AppKit
import AVFoundation

/// WEBCAM: the live picture beside its setup (camera, sound, shape, Koala's screen, overlay, effects), RECORD, a hold
/// STUTTER, a clean OUTPUT window to capture in OBS, and a small FLOATING PREVIEW that stays on top of Koala while you
/// make the beat (it keeps the webcam running with this window closed). Opened from the start screen or the menu.
final class WebcamWindowController: NSWindowController, NSWindowDelegate {
    private let studio = WebcamStudio()
    private let preview = WebcamPictureView(frame: NSRect(x: 20, y: 20, width: 800, height: 660))
    private var output: NSWindow?, floating: NSPanel?, floatingPicture: WebcamPictureView?
    /// The preview's ARM: armed waits for the next pad (or key) to start recording; pressed again it disarms or stops.
    private let arm = WebcamFirstClickButton(title: "● ARM", target: nil, action: nil)
    private var armedAt: Double?, armWatch: Timer?
    private let cameraPopup = NSPopUpButton(), soundPopup = NSPopUpButton(), rotatePopup = NSPopUpButton()
    private let shape = NSSegmentedControl(labels: ["16:9", "9:16"], trackingMode: .selectOne, target: nil, action: nil)
    private var checks: [NSButton] = []
    private let record = NSButton(title: "● RECORD", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var problem: String?
    private var clock: Timer?, recordStarted: Date?
    /// SOUND OUT and LAYOUT (the third column).
    /// The same meter and sound controls on this window and on the floating preview.
    private let strip = WebcamSoundStrip(frame: NSRect(x: 0, y: 0, width: 295, height: WebcamSoundStrip.height))
    private let floatingStrip = WebcamSoundStrip(frame: NSRect(x: 0, y: 0, width: 400, height: WebcamSoundStrip.height))
    private let editLayout = NSButton(checkboxWithTitle: "Move things on the picture", target: nil, action: nil)
    private let canvas = WebcamLayoutCanvas(frame: NSRect(x: 20, y: 20, width: 800, height: 660))
    private var meterClock: Timer?
    private let folderLabel = NSTextField(labelWithString: "")
    private let listenPopup = NSPopUpButton()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1500, height: 700), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Koala Link · Webcam"
        window.isReleasedWhenClosed = false; window.backgroundColor = KoalaLook.background
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1500, height: 700))
        window.contentView = content
        content.addSubview(preview)
        canvas.isHidden = true; content.addSubview(canvas)

        var y: CGFloat = 648
        let x: CGFloat = 845, width: CGFloat = 315
        func place(_ view: NSView, height: CGFloat, gap: CGFloat = 10) { view.frame = NSRect(x: x, y: y - height, width: width, height: height); content.addSubview(view); y -= height + gap }
        func heading(_ text: String) {
            let label = NSTextField(labelWithString: text); label.font = KoalaLook.font(15); label.textColor = KoalaLook.muted
            place(label, height: 20, gap: 4)
        }
        let title = NSTextField(labelWithString: "WEBCAM"); title.font = KoalaLook.font(30); title.textColor = KoalaLook.pink
        place(title, height: 38)
        heading("CAMERA"); place(cameraPopup, height: 26)
        heading("SOUND"); place(soundPopup, height: 26)
        heading("SHAPE"); place(shape, height: 26)
        heading("CAMERA IN 9:16"); place(rotatePopup, height: 26, gap: 14)
        rotatePopup.addItems(withTitles: ["Upright (no turn)", "Turn right", "Turn left"])
        for (i, name) in ["Koala screen (tutorial)", "Pad and waveform overlay", "Video effects", "Mirror camera"].enumerated() {
            let check = NSButton(checkboxWithTitle: name, target: self, action: #selector(changed)); check.tag = i
            checks.append(check); place(check, height: 22, gap: 6)
        }
        y -= 8
        let stutter = WebcamHoldButton(title: "HOLD FOR STUTTER", target: nil, action: nil)
        stutter.onHold = { KoalaPerformanceFeed.shared.setManualStutter($0) }
        record.target = self; record.action = #selector(toggleRecording)
        let pop = NSButton(title: "OUTPUT WINDOW (FOR OBS)", target: self, action: #selector(toggleOutput))
        let mini = NSButton(title: "FLOATING PREVIEW", target: self, action: #selector(toggleFloating))
        for button in [stutter, record, mini, pop] { button.bezelStyle = .rounded; button.font = KoalaLook.font(16); place(button, height: 32, gap: 6) }
        note.font = NSFont.systemFont(ofSize: 12); note.textColor = KoalaLook.muted
        note.frame = NSRect(x: x, y: 20, width: width, height: max(40, y - 24)); content.addSubview(note)
        shape.target = self; shape.action = #selector(changed)
        cameraPopup.target = self; cameraPopup.action = #selector(changed)
        soundPopup.target = self; soundPopup.action = #selector(changed)
        rotatePopup.target = self; rotatePopup.action = #selector(changed)

        // SOUND OUT: what the recordings' sound goes through (WebcamSound.swift), and its VU.
        var y2: CGFloat = 648
        let x2: CGFloat = 1185, width2: CGFloat = 295
        func place2(_ view: NSView, height: CGFloat, gap: CGFloat = 10) { view.frame = NSRect(x: x2, y: y2 - height, width: width2, height: height); content.addSubview(view); y2 -= height + gap }
        func heading2(_ text: String) {
            let label = NSTextField(labelWithString: text); label.font = KoalaLook.font(15); label.textColor = KoalaLook.muted
            place2(label, height: 20, gap: 4)
        }
        let soundTitle = NSTextField(labelWithString: "SOUND OUT"); soundTitle.font = KoalaLook.font(30); soundTitle.textColor = KoalaLook.pink
        place2(soundTitle, height: 38)
        place2(strip, height: WebcamSoundStrip.height, gap: 8)
        heading2("LISTEN THROUGH"); place2(listenPopup, height: 26, gap: 18)
        listenPopup.target = self; listenPopup.action = #selector(listenDeviceChanged)
        for s in [strip, floatingStrip] { s.onChange = { [weak self] change, done in self?.soundChanged(change, done: done) } }
        let layoutTitle = NSTextField(labelWithString: "LAYOUT"); layoutTitle.font = KoalaLook.font(30); layoutTitle.textColor = KoalaLook.pink
        place2(layoutTitle, height: 38)
        editLayout.target = self; editLayout.action = #selector(toggleEditLayout); place2(editLayout, height: 22, gap: 8)
        let reset = NSButton(title: "RESET LAYOUT", target: self, action: #selector(resetLayout)); reset.bezelStyle = .rounded; reset.font = KoalaLook.font(16)
        place2(reset, height: 32, gap: 8)
        let hint = NSTextField(wrappingLabelWithString: "Drag the card, or Koala's screen in the tutorial layout; drag Koala's top-right corner to size it. Each shape and the tutorial layout keep their own places.")
        hint.font = NSFont.systemFont(ofSize: 12); hint.textColor = KoalaLook.muted
        place2(hint, height: 56, gap: 6)
        heading2("RECORDINGS GO TO")
        let choose = NSButton(title: "CHOOSE FOLDER…", target: self, action: #selector(chooseFolder)); choose.bezelStyle = .rounded; choose.font = KoalaLook.font(16)
        place2(choose, height: 32, gap: 4)
        folderLabel.font = NSFont.systemFont(ofSize: 12); folderLabel.textColor = KoalaLook.foreground; folderLabel.lineBreakMode = .byTruncatingMiddle
        place2(folderLabel, height: 18)
        canvas.onChange = { [weak self] layout, done in
            self?.studio.update(save: done) { $0.layouts = ($0.layouts ?? [:]).merging([$0.layoutKey: layout]) { $1 } }
        }

        studio.onPicture = { [weak self] sample in
            self?.preview.show(sample)
            (self?.output?.contentView as? WebcamPictureView)?.show(sample)
            self?.floatingPicture?.show(sample)
        }
        studio.onProblem = { [weak self] text in self?.problem = text; self?.refreshNote() }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func open() {
        fillControls()
        studio.start(); startMeters()
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshNote()
    }
    private func startMeters() {
        guard meterClock == nil else { return }
        meterClock = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            let reading = self.studio.meter
            self.strip.meter.reading = reading
            if self.floating != nil { self.floatingStrip.meter.reading = reading }
        }
    }
    /// Just the floating preview (the menu's Webcam Preview).
    func openFloating() {
        fillControls()
        studio.start(); startMeters()
        if floating == nil { toggleFloating() }
    }
    /// The webcam stops once both this window and the floating preview are closed.
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === floating {
            floating = nil; floatingPicture = nil
            if window?.isVisible != true { shutDown() }
            return
        }
        output?.close(); output = nil
        if floating == nil { shutDown() }
    }
    private func shutDown() {
        disarm(); clock?.invalidate(); clock = nil; recordStarted = nil
        meterClock?.invalidate(); meterClock = nil
        showRecording()
        KoalaPerformanceFeed.shared.setManualStutter(false)
        studio.stop()
    }

    private func fillControls() {
        let s = studio.settings
        cameraPopup.removeAllItems()
        for device in WebcamDevices.cameras() {
            cameraPopup.addItem(withTitle: device.localizedName); cameraPopup.lastItem?.representedObject = device.uniqueID
        }
        if cameraPopup.numberOfItems == 0 { cameraPopup.addItem(withTitle: "No camera found") }
        if let i = cameraPopup.itemArray.firstIndex(where: { $0.representedObject as? String == s.camera }) { cameraPopup.selectItem(at: i) }
        soundPopup.removeAllItems()
        soundPopup.addItem(withTitle: "Koala's own sound"); soundPopup.lastItem?.representedObject = "koala"
        for device in WebcamDevices.microphones() {
            soundPopup.addItem(withTitle: device.localizedName); soundPopup.lastItem?.representedObject = device.uniqueID
        }
        soundPopup.selectItem(at: soundPopup.itemArray.firstIndex(where: { $0.representedObject as? String == s.audio }) ?? 0)
        shape.selectedSegment = s.vertical ? 1 : 0
        rotatePopup.selectItem(at: s.rotate ?? 1)
        for (check, on) in zip(checks, [s.tutorial, s.overlay, s.effects, s.mirror]) { check.state = on ? .on : .off }
        strip.show(s); floatingStrip.show(s)
        listenPopup.removeAllItems()
        listenPopup.addItem(withTitle: "Mac's default output")
        for output in WebcamAudioOutputs.all() { listenPopup.addItem(withTitle: output.name); listenPopup.lastItem?.representedObject = output.uid }
        listenPopup.selectItem(at: listenPopup.itemArray.firstIndex(where: { $0.representedObject as? String == s.listenDevice }) ?? 0)
        syncCanvas()
        folderLabel.stringValue = (s.folderURL.path as NSString).abbreviatingWithTildeInPath
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Use This Folder"; panel.message = "Choose where Webcam recordings are saved"
        panel.directoryURL = studio.settings.folderURL
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.studio.update { $0.folder = url.path }
            self.folderLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            self.refreshNote()
        }
    }

    @objc private func changed() {
        let camera = cameraPopup.selectedItem?.representedObject as? String
        let sound = soundPopup.selectedItem?.representedObject as? String ?? "koala"
        let vertical = shape.selectedSegment == 1, rotate = rotatePopup.indexOfSelectedItem
        let on = checks.map { $0.state == .on }
        if studio.isRecording, vertical != studio.settings.vertical {
            shape.selectedSegment = studio.settings.vertical ? 1 : 0
            problem = "Stop recording before changing the shape."; refreshNote(); return
        }
        studio.update {
            $0.camera = camera ?? $0.camera; $0.audio = sound; $0.vertical = vertical; $0.rotate = rotate
            $0.tutorial = on[0]; $0.overlay = on[1]; $0.effects = on[2]; $0.mirror = on[3]
        }
        sizeOutput(); syncCanvas()
        refreshNote()
    }

    @objc private func listenDeviceChanged() {
        let uid = listenPopup.selectedItem?.representedObject as? String
        studio.update { $0.listenDevice = uid }
    }
    private func soundChanged(_ change: (inout WebcamSettings) -> Void, done: Bool) {
        studio.update(save: done, change)
        strip.show(studio.settings); floatingStrip.show(studio.settings)
    }
    @objc private func toggleEditLayout() { canvas.isHidden = editLayout.state != .on; syncCanvas() }
    @objc private func resetLayout() {
        studio.update { let key = $0.layoutKey; $0.layouts?[key] = nil }
        syncCanvas()
    }
    private func syncCanvas() {
        let s = studio.settings
        canvas.vertical = s.vertical; canvas.tutorial = s.tutorial; canvas.layout = s.layout
    }

    @objc private func toggleRecording() {
        disarm()
        if studio.isRecording {
            clock?.invalidate(); clock = nil; recordStarted = nil
            showRecording()
            studio.stopRecording { [weak self] url in
                self?.problem = url.map { "Saved \($0.lastPathComponent) in \(($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)." } ?? "The recording couldn't be saved."
                self?.refreshNote()
                if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            return
        }
        do {
            _ = try studio.startRecording()
            recordStarted = Date(); problem = nil
            clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tickClock() }
            tickClock()
        } catch { problem = "Recording didn't start: \(error.localizedDescription)"; refreshNote() }
    }
    private func tickClock() { showRecording() }
    private func showRecording() {
        if let recordStarted {
            let t = Int(Date().timeIntervalSince(recordStarted)), time = String(format: "%d:%02d", t / 60, t % 60)
            record.title = "■ STOP  " + time; arm.title = "■ STOP  " + time; arm.contentTintColor = KoalaLook.pink
        } else {
            record.title = "● RECORD"
            arm.title = armedAt == nil ? "● ARM" : "ARMED · PLAY A PAD"
            arm.contentTintColor = armedAt == nil ? nil : KoalaLook.pink
        }
    }

    /// ARM on the preview: arm, disarm, or stop a recording.
    @objc private func toggleArm() {
        if studio.isRecording || armedAt != nil { armedAt == nil ? toggleRecording() : disarm(); return }
        armedAt = KoalaPerformanceFeed.now(); showRecording()
        // The first pad or key after arming starts the recording.
        armWatch = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
            guard let self, let armedAt = self.armedAt else { return }
            if let hit = KoalaPerformanceFeed.shared.snapshot.lastHit, hit.time > armedAt { self.toggleRecording() }
        }
    }
    private func disarm() {
        armWatch?.invalidate(); armWatch = nil
        guard armedAt != nil else { return }
        armedAt = nil; showRecording()
    }

    @objc private func toggleOutput() {
        if let output { output.close(); self.output = nil; return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                         backing: .buffered, defer: false)
        w.title = "Koala Link · Webcam Output"; w.isReleasedWhenClosed = false
        w.contentView = WebcamPictureView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        output = w; sizeOutput(); w.center(); w.makeKeyAndOrderFront(nil)
    }
    /// A small window over everything (Koala included, on every Space), which doesn't take the keyboard from Koala.
    @objc private func toggleFloating() {
        if let floating { floating.close(); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 225),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Webcam"; panel.isFloatingPanel = true; panel.level = .floating; panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 225 + Self.bar))
        let picture = WebcamPictureView(frame: NSRect(x: 0, y: Self.bar, width: 400, height: 225))
        picture.autoresizingMask = [.width, .height]
        floatingStrip.frame = NSRect(x: 6, y: 40, width: 388, height: WebcamSoundStrip.height); floatingStrip.autoresizingMask = [.width]
        floatingStrip.show(studio.settings)
        arm.frame = NSRect(x: 6, y: 4, width: 388, height: 32); arm.autoresizingMask = [.width]
        arm.bezelStyle = .rounded; arm.font = KoalaLook.font(15); arm.target = self; arm.action = #selector(toggleArm)
        content.addSubview(picture); content.addSubview(floatingStrip); content.addSubview(arm)
        panel.contentView = content
        floating = panel; floatingPicture = picture; sizeOutput(); showRecording()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 20, y: f.maxY - 20))
        }
        panel.orderFrontRegardless()
    }
    /// The floating preview's controls under the picture: the sound strip and ARM.
    private static let bar: CGFloat = WebcamSoundStrip.height + 46
    private func sizeOutput() {
        let vertical = studio.settings.vertical
        if let output {
            let size = vertical ? NSSize(width: 405, height: 720) : NSSize(width: 960, height: 540)
            output.contentAspectRatio = size; output.setContentSize(size)
        }
        if let floating {
            let size = vertical ? NSSize(width: 290, height: 516) : NSSize(width: 400, height: 225)
            floating.setContentSize(NSSize(width: size.width, height: size.height + Self.bar))
        }
    }

    private func refreshNote() {
        let s = studio.settings
        var lines = [problem].compactMap { $0 }
        lines.append(s.tutorial ? "Koala's window fills the picture with you in the corner." : "Your camera fills the picture.")
        lines.append("STUTTER, GATE, FILTER and CRUSH from the Push show on the picture. Effects touched on Koala's own screen can't be seen by Koala Link: hold STUTTER here instead.")
        lines.append("LISTEN swaps Koala's own sound for the one with DRIVE, MPC3000 OUT and the limiter, on the LISTEN THROUGH output.")
        lines.append("Recordings go to \((s.folderURL.path as NSString).abbreviatingWithTildeInPath).")
        note.stringValue = lines.joined(separator: "\n\n")
    }
}

/// Shows the composed pictures as they arrive (a sample-buffer layer keeps each buffer until it is shown).
final class WebcamPictureView: NSView {
    private let display = AVSampleBufferDisplayLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        display.videoGravity = .resizeAspect
        display.frame = bounds; display.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(display)
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func show(_ sample: CMSampleBuffer) {
        if display.status == .failed { display.flush() }
        display.enqueue(sample)
    }
}

/// LAYOUT: boxes for Koala's screen (tutorial) and the card over the preview, to move (and Koala's screen to size).
final class WebcamLayoutCanvas: NSView {
    var vertical = false { didSet { needsDisplay = true } }
    var tutorial = false { didSet { needsDisplay = true } }
    var layout = WebcamLayout.standard(vertical: false, tutorial: false) { didSet { needsDisplay = true } }
    /// The new layout, and whether the drag is over.
    var onChange: ((WebcamLayout, Bool) -> Void)?
    private enum Part { case card, camera, koala }
    private var drag: (part: Part, resize: Bool, start: NSPoint, from: WebcamLayout)?

    /// Where the picture sits in the view (fitted, as the preview shows it).
    private var picture: NSRect {
        let aspect: CGFloat = vertical ? 9.0 / 16 : 16.0 / 9
        let w = min(bounds.width, bounds.height * aspect), h = w / aspect
        return NSRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }
    private var cardSize: CGSize {
        let frame = vertical ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
        let size = WebcamOverlayPainter.cardSize(vertical: vertical, frameSize: frame)
        return CGSize(width: size.width / frame.width, height: size.height / frame.height)
    }
    private func rect(_ part: Part) -> CGRect {
        switch part {
        case .card: return CGRect(origin: layout.card, size: cardSize)
        case .camera: return layout.camera
        case .koala: return layout.koala
        }
    }
    private func view(_ r: CGRect) -> NSRect {
        let p = picture
        return NSRect(x: p.minX + r.minX * p.width, y: p.minY + r.minY * p.height, width: r.width * p.width, height: r.height * p.height)
    }
    private var parts: [Part] { tutorial ? [.card, .koala] : [.card] }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for part in parts {
            let r = view(rect(part))
            let corner = part != .card && abs(p.x - r.maxX) < 16 && abs(p.y - r.maxY) < 16
            if corner || r.contains(p) { drag = (part, corner, p, layout); return }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        let p = convert(event.locationInWindow, from: nil), size = picture.size
        let dx = (p.x - drag.start.x) / size.width, dy = (p.y - drag.start.y) / size.height
        var next = drag.from
        func moved(_ r: CGRect) -> CGRect {
            CGRect(x: max(0, min(1 - r.width, r.minX + dx)), y: max(0, min(1 - r.height, r.minY + dy)), width: r.width, height: r.height)
        }
        func sized(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX, y: r.minY, width: max(0.1, min(1 - r.minX, r.width + dx)), height: max(0.1, min(1 - r.minY, r.height + dy)))
        }
        switch drag.part {
        case .card: next.card = moved(CGRect(origin: next.card, size: cardSize)).origin
        case .camera: next.camera = drag.resize ? sized(next.camera) : moved(next.camera)
        case .koala: next.koala = drag.resize ? sized(next.koala) : moved(next.koala)
        }
        layout = next; onChange?(next, false)
    }
    override func mouseUp(with event: NSEvent) {
        guard drag != nil else { return }
        drag = nil; onChange?(layout, true)
    }
    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [.font: KoalaLook.font(15), .foregroundColor: NSColor.white]
        for part in parts.reversed() {
            let r = view(rect(part)).insetBy(dx: 1, dy: 1)
            let colour: NSColor = part == .card ? KoalaLook.pink : part == .camera ? KoalaLook.blue : .systemYellow
            colour.withAlphaComponent(0.12).setFill(); r.fill()
            let outline = NSBezierPath(rect: r); outline.lineWidth = 2; outline.setLineDash([6, 4], count: 2, phase: 0)
            colour.setStroke(); outline.stroke()
            let name = (part == .card ? "CARD" : part == .camera ? "CAMERA" : "KOALA SCREEN") as NSString
            name.draw(at: NSPoint(x: r.minX + 8, y: r.maxY - 22), withAttributes: attributes)
            if part != .card { colour.setFill(); NSRect(x: r.maxX - 12, y: r.maxY - 12, width: 12, height: 12).fill() }
        }
    }
}

/// The dB meter with DRIVE, THRESHOLD, MPC3000 OUT and LIMITER (ceiling −1 dB), reporting each change.
final class WebcamSoundStrip: NSView {
    static let height: CGFloat = 172
    let meter = WebcamDBMeter(frame: .zero)
    var onChange: (((inout WebcamSettings) -> Void, Bool) -> Void)?
    private let drive = NSSlider(value: 0, minValue: 0, maxValue: 12, target: nil, action: nil)
    private let threshold = NSSlider(value: 0, minValue: -20, maxValue: 0, target: nil, action: nil)
    private let driveValue = NSTextField(labelWithString: ""), thresholdValue = NSTextField(labelWithString: "")
    private let mpcOut = NSButton(checkboxWithTitle: "MPC3000 OUT", target: nil, action: nil)
    private let limiter = NSButton(checkboxWithTitle: "LIMITER · CEILING −1 dB", target: nil, action: nil)
    private let listen = NSButton(checkboxWithTitle: "LISTEN · hear drive and limiter", target: nil, action: nil)
    override init(frame: NSRect) {
        super.init(frame: frame)
        let w = frame.width
        meter.frame = NSRect(x: 0, y: 108, width: w, height: 64); meter.autoresizingMask = [.width]
        addSubview(meter)
        for (i, (name, slider, value)) in [("DRIVE", drive, driveValue), ("THRESH", threshold, thresholdValue)].enumerated() {
            let y = CGFloat(80 - i * 28)
            let label = NSTextField(labelWithString: name); label.font = KoalaLook.font(13); label.textColor = KoalaLook.muted
            label.frame = NSRect(x: 0, y: y, width: 56, height: 20)
            slider.frame = NSRect(x: 58, y: y, width: w - 58 - 66, height: 22); slider.autoresizingMask = [.width]
            slider.isContinuous = true; slider.target = self; slider.action = #selector(changed)
            value.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium); value.textColor = KoalaLook.foreground; value.alignment = .right
            value.frame = NSRect(x: w - 64, y: y + 2, width: 64, height: 18); value.autoresizingMask = [.minXMargin]
            addSubview(label); addSubview(slider); addSubview(value)
        }
        mpcOut.frame = NSRect(x: 0, y: 26, width: 112, height: 20)
        limiter.frame = NSRect(x: 114, y: 26, width: w - 114, height: 20); limiter.autoresizingMask = [.width]
        listen.frame = NSRect(x: 0, y: 2, width: w, height: 20); listen.autoresizingMask = [.width]
        for check in [mpcOut, limiter, listen] { check.font = NSFont.systemFont(ofSize: 11); check.target = self; check.action = #selector(changed); addSubview(check) }
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func show(_ s: WebcamSettings) {
        drive.doubleValue = s.drive ?? 0; threshold.doubleValue = s.threshold ?? 0
        mpcOut.state = s.mpcOut ?? true ? .on : .off; limiter.state = s.limiter ?? true ? .on : .off
        listen.state = s.listen == true ? .on : .off
        threshold.isEnabled = limiter.state == .on
        label()
    }
    private func label() {
        driveValue.stringValue = String(format: "+%.1f dB", drive.doubleValue)
        thresholdValue.stringValue = String(format: "%.1f dB", threshold.doubleValue)
    }
    @objc private func changed() {
        let d = (drive.doubleValue * 2).rounded() / 2, t = (threshold.doubleValue * 2).rounded() / 2
        let clip = mpcOut.state == .on, limit = limiter.state == .on, hear = listen.state == .on
        drive.doubleValue = d; threshold.doubleValue = t; label()
        let done = NSApp.currentEvent?.type != .leftMouseDragged
        onChange?({ $0.drive = d; $0.threshold = t; $0.mpcOut = clip; $0.limiter = limit; $0.listen = hear }, done)
    }
}

/// A button that works on the first click in the floating preview, which never takes focus from Koala.
final class WebcamFirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A button that reports being held down and let go.
final class WebcamHoldButton: NSButton {
    var onHold: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) { onHold?(true); super.mouseDown(with: event); onHold?(false) }
}
