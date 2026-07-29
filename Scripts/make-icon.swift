#!/usr/bin/env swift
// Draws the application icon. Run: swift Scripts/make-icon.swift <output.icns>
//
// The icon is code rather than a committed binary so that the mark has a reviewable diff and
// the reasoning behind its geometry stays reachable. That reasoning — and the meaning of every
// number below — is in docs/superpowers/specs/2026-07-29-app-icon-design.md.
import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Design spec §2.4. Cinnabar was the colour the important letter was written in; it is the
/// icon's only accent, and it is the guillemets rather than the letter that carry it.
enum Palette {
    static let ink = NSColor(srgbRed: 0x1B / 255, green: 0x24 / 255, blue: 0x30 / 255, alpha: 1)
    static let parchment = NSColor(srgbRed: 0xEF / 255, green: 0xE7 / 255, blue: 0xD7 / 255, alpha: 1)
    static let cinnabar = NSColor(srgbRed: 0xD9 / 255, green: 0x58 / 255, blue: 0x3F / 255, alpha: 1)
}

/// The ten members of a macOS iconset, and the pixel size each one is rendered at.
let members: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

/// The Т is sized by cap height, not by point size. A point size hardcoded against one font
/// silently changes the mark if the font is ever substituted; a cap-height target does not.
func serifFont(capHeight target: CGFloat) throws -> NSFont {
    let probeSize: CGFloat = 100
    let systemSerif = NSFont.systemFont(ofSize: probeSize).fontDescriptor.withDesign(.serif)
        .flatMap { NSFont(descriptor: $0, size: probeSize) }
    guard let probe = systemSerif ?? NSFont(name: "Georgia", size: probeSize) else {
        throw Failure("neither the system serif nor Georgia is available")
    }
    guard probe.capHeight > 0 else { throw Failure("\(probe.fontName) reports no cap height") }
    guard let sized = NSFont(descriptor: probe.fontDescriptor, size: probeSize * target / probe.capHeight) else {
        throw Failure("could not resize \(probe.fontName) to cap height \(target)")
    }
    return sized
}

func drawIcon(in ctx: CGContext, pixels: CGFloat, simplified: Bool) throws {
    // The macOS app-icon grid: the tile body is 824 of the 1024-point canvas, so the artwork
    // deliberately does not run to the edge.
    let bodySide = pixels * 824 / 1024
    let bodyOrigin = (pixels - bodySide) / 2
    let unit = bodySide / 100

    // Artwork y grows downward, as in the sketch the geometry was approved from; the bitmap
    // context's y grows upward. Every coordinate goes through this one flip.
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: bodyOrigin + x * unit, y: pixels - (bodyOrigin + y * unit))
    }

    ctx.addPath(CGPath(roundedRect: CGRect(x: bodyOrigin, y: bodyOrigin, width: bodySide, height: bodySide),
                       cornerWidth: bodySide * 185.4 / 824,
                       cornerHeight: bodySide * 185.4 / 824,
                       transform: nil))
    ctx.setFillColor(Palette.ink.cgColor)
    ctx.fillPath()

    // « Т » — pointing outward. Turning them inward would read better as a graphic, but »…«
    // is the German convention and this application's copy rules are Russian. Spec §2.3.
    //
    // The simplified geometry is not a style choice. At a 16 px raster a 5-unit stroke is
    // 0.64 px and the two chevrons of each guillemet merge; widening the stroke to 9 then
    // brings its rightmost extent — the butt-capped end of the arm, not the miter join, which
    // sits at the apex on the far left — within 1.2 units (0.16 px) of the glyph path's left
    // edge, so the chevrons move outward and the letter shrinks to reopen the gap to ≈6.90
    // units. Spec §3.1.
    let chevrons: [[(CGFloat, CGFloat)]] = simplified
        ? [[(28, 40), (20, 50), (28, 60)], [(72, 40), (80, 50), (72, 60)]]
        : [[(22, 40), (14, 50), (22, 60)], [(32, 40), (24, 50), (32, 60)],
           [(68, 40), (76, 50), (68, 60)], [(78, 40), (86, 50), (78, 60)]]
    ctx.setStrokeColor(Palette.cinnabar.cgColor)
    ctx.setLineWidth((simplified ? 9 : 5) * unit)
    ctx.setLineJoin(.miter)
    ctx.setLineCap(.butt)
    for chevron in chevrons {
        ctx.move(to: point(chevron[0].0, chevron[0].1))
        ctx.addLine(to: point(chevron[1].0, chevron[1].1))
        ctx.addLine(to: point(chevron[2].0, chevron[2].1))
        ctx.strokePath()
    }

    // Not `try?` with a fallback: a tile drawn without its letter is a broken icon that looks
    // like a finished one, and this script's whole contract is to fail loudly instead.
    let font = try serifFont(capHeight: (simplified ? 27 : 31) * unit)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        // CoreText reads its own key. NSAttributedString.Key.foregroundColor is not a
        // substitute here: CTLineDraw ignores it and the letter comes out black.
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): Palette.parchment.cgColor,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Т", attributes: attributes))
    // CoreText can silently substitute a different face for a glyph the requested font lacks.
    // A substitution invalidates the cap-height maths the whole sizing scheme rests on — the
    // font above was sized to *this* font's cap height, not whatever CoreText might swap in —
    // so confirm the line is one glyph run in exactly the font that was asked for.
    let runs = CTLineGetGlyphRuns(line) as! [CTRun]
    guard CTLineGetGlyphCount(line) == 1, runs.count == 1 else {
        throw Failure("Т produced \(CTLineGetGlyphCount(line)) glyph(s) across \(runs.count) run(s), expected one of each")
    }
    let runAttributes = CTRunGetAttributes(runs[0]) as NSDictionary
    guard let runFont = runAttributes[kCTFontAttributeName as String] as! CTFont? else {
        throw Failure("the rendered run for Т carries no font attribute")
    }
    guard CTFontCopyPostScriptName(runFont) as String == CTFontCopyPostScriptName(font) as String else {
        throw Failure("CoreText substituted \(CTFontCopyPostScriptName(runFont)) for Т instead of \(font.fontName)")
    }
    let glyphBounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    let baseline = point(50, simplified ? 64 : 66)
    ctx.textPosition = CGPoint(x: baseline.x - glyphBounds.midX, y: baseline.y)
    CTLineDraw(line, ctx)
}

func renderIcon(pixels: Int, simplified: Bool) throws -> CGImage {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw Failure("sRGB colour space is unavailable")
    }
    guard let ctx = CGContext(data: nil,
                              width: pixels,
                              height: pixels,
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure("could not create a \(pixels)×\(pixels) context")
    }
    try drawIcon(in: ctx, pixels: CGFloat(pixels), simplified: simplified)
    guard let image = ctx.makeImage() else { throw Failure("could not render \(pixels)×\(pixels)") }
    return image
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        throw Failure("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("could not write \(url.path)") }
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw Failure("\(executable) exited \(process.terminationStatus)")
    }
}

func makeIcns(at output: URL) throws {
    // The iconset is left on disk on purpose: it is what `sips` is pointed at and what a human
    // opens to check that the two small rasters really are a different drawing.
    let iconset = output.deletingLastPathComponent()
        .appendingPathComponent(output.deletingPathExtension().lastPathComponent + ".iconset")
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for member in members {
        // 16 and 32 are the sizes the full mark cannot survive; see drawIcon.
        try writePNG(try renderIcon(pixels: member.pixels, simplified: member.pixels <= 32),
                     to: iconset.appendingPathComponent(member.name + ".png"))
    }
    try run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", output.path])
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift Scripts/make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
do {
    let output = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try makeIcns(at: output)
    print("wrote \(output.path)")
} catch {
    // A bundle without an icon must fail loudly rather than quietly ship.
    FileHandle.standardError.write(Data("make-icon: \(error)\n".utf8))
    exit(1)
}
