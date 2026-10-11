import AppKit

enum KoalaControllerChoice: String { case mpcTouch, push2 }

/// Every launch offers both controllers; choosing one creates only that
/// controller's MIDI session. The shared Touch service remains independent.
final class ControllerChoiceWindow: NSWindowController {
    var onChoose: ((KoalaControllerChoice) -> Void)?
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 380),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Koala Link · Choose your controller"
        window.isReleasedWhenClosed = false; window.backgroundColor = KoalaLook.background
        super.init(window: window)
        let content = KoalaChoiceBackground(frame: NSRect(x: 0, y: 0, width: 720, height: 380))
        window.contentView = content
        let title = label("KOALA LINK", size: 38, color: KoalaLook.pink)
        title.frame = NSRect(x: 35, y: 286, width: 650, height: 60); content.addSubview(title)
        let detail = label("Choose your controller", size: 21, color: .white)
        detail.frame = NSRect(x: 35, y: 242, width: 650, height: 32); content.addSubview(detail)
        let touch = KoalaChoiceButton(title: "MPC TOUCH", target: self, action: #selector(chooseTouch))
        let push = KoalaChoiceButton(title: "PUSH 2", target: self, action: #selector(choosePush))
        for (i, button) in [touch, push].enumerated() {
            button.isBordered = false; button.font = KoalaLook.font(25)
            button.frame = NSRect(x: CGFloat(35 + i * 340), y: 136, width: 310, height: 75)
            content.addSubview(button)
        }
        let t = label("Touchscreen · 4 pad banks · Q-Links", size: 16, color: KoalaLook.muted)
        t.frame = NSRect(x: 35, y: 100, width: 320, height: 26); content.addSubview(t)
        let p = label("64 pads · Koala screens · encoders & strip", size: 16, color: KoalaLook.muted)
        p.frame = NSRect(x: 375, y: 100, width: 315, height: 26); content.addSubview(p)
        let footer = label("You can change controllers from the Koala Link menu.", size: 16, color: KoalaLook.muted)
        footer.frame = NSRect(x: 35, y: 35, width: 650, height: 28); content.addSubview(footer)
        window.center()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func label(_ text: String, size: CGFloat, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text); field.font = KoalaLook.font(size); field.textColor = color; return field
    }
    @objc private func chooseTouch() { close(); onChoose?(.mpcTouch) }
    @objc private func choosePush() { close(); onChoose?(.push2) }
}

private final class KoalaChoiceBackground: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) { KoalaLook.background.setFill(); bounds.fill() }
}
private final class KoalaChoiceButton: NSButton {
    override func draw(_ dirtyRect: NSRect) {
        (isHighlighted ? KoalaLook.pink : KoalaLook.blue).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font ?? KoalaLook.font(25), .foregroundColor: KoalaLook.foreground]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}
