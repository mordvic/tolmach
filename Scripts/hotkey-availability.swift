// Scripts/hotkey-availability.swift
//
// Whether a combination is free to take as a factory shortcut. Two questions, because they
// fail differently:
//
//   1. Does Carbon accept the registration? A refusal (-9878, eventHotKeyExistsErr) means
//      something in *this process* already holds it — which for a throwaway probe means
//      nothing does, so this half only ever catches a mistake in the probe itself.
//   2. Does macOS itself already use it? System shortcuts live in
//      com.apple.symbolichotkeys, and a hot key registered over one of those is simply never
//      delivered — RegisterEventHotKey returns noErr and the app looks broken.
//
//     swiftc -O -o /tmp/hka Scripts/hotkey-availability.swift && /tmp/hka
//     KEY=15 MODS=cmd,opt /tmp/hka     # the pair being checked; defaults to ⌥⌘R
//
// **The second half sees only what the user has changed, and that is measured, not
// suspected.** The plist holds deviations from the factory set, not the set: on this machine
// it reads 24 entries, and `KEY=49 MODS=cmd` — Spotlight, the most famous system shortcut
// there is — finds nothing, because entry #64 is absent entirely while #60 and #61 (the input
// source shortcuts, which had been changed) are there. So a clean answer means «no shortcut
// the user has customised holds this», which is strictly weaker than «macOS does not use it».
// The factory set has to be checked against Apple's own documentation by hand, and the only
// real proof is pressing the key on a built bundle — which is why `docs/reference/OPEN-ITEMS.md`
// carries that check.
//
// The modifier numbers in symbolichotkeys are NSEvent's raw values, not Carbon's:
// ⌘ 1048576, ⌥ 524288, ⌃ 262144, ⇧ 131072. That is why this reads them rather than
// converting — a table of Carbon constants compared against a plist of Cocoa ones is how a
// probe comes back green on a combination the system owns.
import AppKit
import Carbon.HIToolbox

let keyCode = ProcessInfo.processInfo.environment["KEY"].flatMap { UInt16($0) } ?? 15
let names = (ProcessInfo.processInfo.environment["MODS"] ?? "cmd,opt")
    .split(separator: ",").map(String.init)
let cocoaModifiers: UInt = names.reduce(into: 0) { total, name in
    switch name {
    case "cmd": total |= NSEvent.ModifierFlags.command.rawValue
    case "opt": total |= NSEvent.ModifierFlags.option.rawValue
    case "ctrl": total |= NSEvent.ModifierFlags.control.rawValue
    case "shift": total |= NSEvent.ModifierFlags.shift.rawValue
    default: FileHandle.standardError.write(Data("unknown modifier \(name)\n".utf8))
    }
}
var carbonModifiers: UInt32 = 0
let flags = NSEvent.ModifierFlags(rawValue: cocoaModifiers)
if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

print("checking keyCode \(keyCode) with \(names.joined(separator: "+")) "
      + "(cocoa \(cocoaModifiers), carbon \(carbonModifiers))")

// 1. Carbon
var ref: EventHotKeyRef?
let id = EventHotKeyID(signature: OSType(0x50524F42), id: 1)   // 'PROB'
let status = RegisterEventHotKey(UInt32(keyCode), carbonModifiers, id,
                                 GetEventDispatcherTarget(), 0, &ref)
print("RegisterEventHotKey → \(status)\(status == noErr ? " (accepted)" : " (REFUSED)")")
if let ref { UnregisterEventHotKey(ref) }

// 2. The system's own table
var collisions = 0
if let table = UserDefaults(suiteName: "com.apple.symbolichotkeys")?
    .dictionary(forKey: "AppleSymbolicHotKeys") {
    print("read \(table.count) entries from com.apple.symbolichotkeys")
    for (which, raw) in table {
        guard let entry = raw as? [String: Any],
              entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Int],
              parameters.count >= 3 else { continue }
        // parameters are [ASCII character, key code, modifier mask].
        guard parameters[1] == Int(keyCode) else { continue }
        let mods = UInt(bitPattern: parameters[2])
        print("  symbolichotkeys #\(which): same key, modifiers \(mods)"
              + (mods == cocoaModifiers ? "  ← COLLISION" : ""))
        if mods == cocoaModifiers { collisions += 1 }
    }
} else {
    print("  (no AppleSymbolicHotKeys table readable — treat this half as unmeasured)")
}
print(collisions == 0
      ? "no collision among the shortcuts the user has customised — see the header: this is "
        + "NOT proof that macOS leaves the combination alone"
      : "COLLIDES with \(collisions) customised system shortcut(s)")
