import AppKit
import AVFoundation

/// WEBCAM: the live picture beside its setup (camera, sound, shape, Koala's screen, overlay, effects), RECORD, a hold
/// STUTTER, a clean OUTPUT window to capture in OBS, and a small FLOATING PREVIEW that stays on top of Koala while you
/// make the beat (it keeps the webcam running with this window closed). Opened from the start screen or the menu.
final class WebcamWindowController: NSWindowController, NSWindowDelegate {
    private let studio = WebcamStudio()
    private let preview = WebcamPictureView(frame: NSRect(x: 20, y: 20, width: 800, height: 660))
    private var output: NSWindow?, floating: NSPanel?
    private let cameraPopup = NSPopUpButton(), soundPopup = NSPopUpButton(), rotatePopup = NSPopUpButton()
    private let shape = NSSegmentedControl(labels: ["16:9", "9:16"], trackingMode: .selectOne, target: nil, action: nil)
    private var checks: [NSButton] = []
    private let record = NSButton(title: "● RECORD", target: nil, action: nil)
    private let note = NSTextField(wrappingLabelWithString: "")
    private var problem: String?
    private var clock: Timer?, recordStarted: Date?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700), styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = "Koala Link · Webcam"
        window.isReleasedWhenClosed = false; window.backgroundColor = KoalaLook.background
        window.appearance = NSAppearance(named: .darkAqua)
        super.init(window: window)
        window.delegate = self
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 1180, height: 700))
        window.contentView = content
        content.addSubview(preview)

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

        studio.onPicture = { [weak self] sample in
            self?.preview.show(sample)
            (self?.output?.contentView as? WebcamPictureView)?.show(sample)
            (self?.floating?.contentView as? WebcamPictureView)?.show(sample)
        }
        studio.onProblem = { [weak self] text in self?.problem = text; self?.refreshNote() }
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }

    func open() {
        fillControls()
        studio.start()
        showWindow(nil); window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        refreshNote()
    }
    /// Just the floating preview (the menu's Webcam Preview).
    func openFloating() {
        fillControls()
        studio.start()
        if floating == nil { toggleFloating() }
    }
    /// The webcam stops once both this window and the floating preview are closed.
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === floating {
            floating = nil
            if window?.isVisible != true { shutDown() }
            return
        }
        output?.close(); output = nil
        if floating == nil { shutDown() }
    }
    private func shutDown() {
        clock?.invalidate(); clock = nil; recordStarted = nil
        record.title = "● RECORD"
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
        sizeOutput()
        refreshNote()
    }

    @objc private func toggleRecording() {
        if studio.isRecording {
            clock?.invalidate(); clock = nil; recordStarted = nil
            record.title = "● RECORD"
            studio.stopRecording { [weak self] url in
                self?.problem = url.map { "Saved \($0.lastPathComponent) in Movies › Koala Link." } ?? "The recording couldn't be saved."
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
    private func tickClock() {
        guard let recordStarted else { return }
        let t = Int(Date().timeIntervalSince(recordStarted))
        record.title = String(format: "■ STOP  %d:%02d", t / 60, t % 60)
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
        panel.contentView = WebcamPictureView(frame: NSRect(x: 0, y: 0, width: 400, height: 225))
        floating = panel; sizeOutput()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.maxX - panel.frame.width - 20, y: f.maxY - 20))
        }
        panel.orderFrontRegardless()
    }
    private func sizeOutput() {
        let vertical = studio.settings.vertical
        if let output {
            let size = vertical ? NSSize(width: 405, height: 720) : NSSize(width: 960, height: 540)
            output.contentAspectRatio = size; output.setContentSize(size)
        }
        if let floating {
            let size = vertical ? NSSize(width: 225, height: 400) : NSSize(width: 400, height: 225)
            floating.contentAspectRatio = size; floating.setContentSize(size)
        }
    }

    private func refreshNote() {
        let s = studio.settings
        var lines = [problem].compactMap { $0 }
        lines.append(s.tutorial ? "Koala's window fills the picture with you in the corner." : "Your camera fills the picture.")
        lines.append("STUTTER, GATE, FILTER and CRUSH from the Push show on the picture. Effects touched on Koala's own screen can't be seen by Koala Link: hold STUTTER here instead.")
        lines.append("Recordings go to Movies › Koala Link.")
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

/// A button that reports being held down and let go.
final class WebcamHoldButton: NSButton {
    var onHold: ((Bool) -> Void)?
    override func mouseDown(with event: NSEvent) { onHold?(true); super.mouseDown(with: event); onHold?(false) }
}
