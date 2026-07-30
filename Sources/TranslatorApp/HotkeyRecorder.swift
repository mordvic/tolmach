// Sources/TranslatorApp/HotkeyRecorder.swift
import SwiftUI
import AppKit
import Carbon.HIToolbox
import TextCapture

/// A button that, once clicked, turns the next key press into a `HotkeyCombo`.
///
/// `NSViewRepresentable` rather than SwiftUI, because SwiftUI has no way to read a raw key
/// code: `onKeyPress` reports characters, and a character is layout-dependent while
/// `RegisterEventHotKey` wants the physical code.
struct HotkeyRecorder: NSViewRepresentable {
    @Binding var combo: HotkeyCombo

    func makeNSView(context: Context) -> RecorderView { RecorderView() }

    /// Both the value *and* the callback are refreshed here rather than the callback being
    /// installed once in `makeNSView`. `makeNSView` runs a single time and its closure would
    /// capture that call's `self`, freezing the `Binding` it holds; `updateNSView` is handed
    /// a current one on every pass. It happens not to matter for the binding this pane
    /// passes — `@Bindable` projects closures that address the shared `AppSettings` object,
    /// which outlives every redraw — but that is a property of today's caller, not of the
    /// control, and a caller that bound to `@State` would silently record into a dead copy.
    func updateNSView(_ view: RecorderView, context: Context) {
        view.combo = combo
        view.onRecord = { combo = $0 }
    }

    final class RecorderView: NSView {
        var combo: HotkeyCombo = .default { didSet { needsDisplay = true } }
        var onRecord: ((HotkeyCombo) -> Void)?
        private var isRecording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 24) }

        override func mouseDown(with event: NSEvent) {
            isRecording = true
            window?.makeFirstResponder(self)
        }

        /// Where a ⌘ combination is actually caught. AppKit routes a key-down that carries
        /// Command through key-equivalent dispatch first — the key window's view hierarchy,
        /// then the main menu — and only what nobody claims there arrives at `keyDown`. So
        /// without this override the app's own menu items get first refusal on precisely the
        /// combinations this control exists to record: ⌘W would close the settings window
        /// mid-recording and ⌘Q would quit, instead of either being written down. Claiming
        /// the event here is what every established recorder on this platform does.
        ///
        /// Guarded on `isRecording`, not merely on being first responder: this method is
        /// offered every key equivalent in the window whether or not this view is focused,
        /// and swallowing them while idle would break the rest of the pane. `isRecording` is
        /// only ever set by a click that also takes first responder, and `resignFirstResponder`
        /// clears it, so it is the narrower of the two conditions.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard isRecording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { return super.keyDown(with: event) }
            if Int(event.keyCode) == kVK_Escape { isRecording = false; return }   // Esc abandons
            // Masked by `HotkeyCombo.init`, and read back out of `candidate` rather than off
            // the event from here on. A raw `modifierFlags` carries bits a shortcut cannot
            // hold — caps lock, the numeric pad, fn, and the left/right variants — and every
            // later use has to agree about them: validate the masked value, display the
            // masked value, store the masked value. Validating the event and displaying the
            // combo is how a recorder ends up accepting ⇧+numpad and showing plain ⇧.
            let candidate = HotkeyCombo(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue)
            // Refused here as well as in `HotkeyManager`, so the user sees the recorder
            // stay open rather than watching a combination be accepted and then not work.
            guard candidate.isValid else { NSSound.beep(); return }
            combo = candidate
            isRecording = false
            onRecord?(candidate)
        }

        /// Pressing and releasing modifiers alone records nothing and leaves the control
        /// armed, which is the wanted behaviour and comes for free: AppKit reports a bare
        /// modifier through `flagsChanged(with:)`, never `keyDown`, and that is not
        /// overridden. The way out is Esc, or clicking elsewhere — which lands here.
        override func resignFirstResponder() -> Bool {
            isRecording = false
            return super.resignFirstResponder()
        }

        /// The view draws its own text, so without this it is a blank rectangle to VoiceOver
        /// and the current shortcut cannot be read at all.
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? { "Сочетание клавиш" }
        override func accessibilityValue() -> Any? { combo.displayString }

        override func draw(_ dirtyRect: NSRect) {
            let title = isRecording ? "Нажмите сочетание…" : combo.displayString
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: isRecording ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
            ]
            NSColor.controlBackgroundColor.setFill()
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            path.fill()
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.stroke()
            let text = title as NSString
            let height = text.size(withAttributes: attributes).height
            text.draw(in: bounds.insetBy(dx: 4, dy: (bounds.height - height) / 2), withAttributes: attributes)
        }
    }
}
