#!/usr/bin/env swift
//
// make-icon.swift — render the CCwiki app icon at every macOS size.
//
// The mark is the wiki's own logo reduced to what survives being an app icon:
// the purple, the concentric rings, the skyline, and **CC** in the middle.
//
// The full logo (content/Files/cc-full.png) sets CRYPTOLOGY over CITY inside
// the rings with the skyline above the wordmark. Two words at that size are
// unreadable at 32 pt and gone at 16, so the wordmark collapses to its initials
// and everything else steps back: the rings sit near the rim, and the skyline
// becomes a band of texture behind the letters rather than a subject. What is
// left is the same object seen from further away, which is what an icon is.
//
// Pure CoreGraphics and Core Text: no assets, no dependencies, runs under plain
// `swift`. `make icon` runs `iconutil -c icns build/AppIcon.iconset` on the PNGs
// this writes.

import AppKit
import CoreText

let iconsetDir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(
    atPath: iconsetDir, withIntermediateDirectories: true)

// (filename, pixel dimension) — the set iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

// The logo's palette.
let deepPurple = CGColor(red: 0.13, green: 0.07, blue: 0.22, alpha: 1)
let midPurple = CGColor(red: 0.31, green: 0.19, blue: 0.48, alpha: 1)
let ringPurple = CGColor(red: 0.60, green: 0.44, blue: 0.80, alpha: 1)

func draw(into ctx: CGContext, size s: CGFloat) {
    let inset = s * 0.06
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = tile.width * 0.225
    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Background: lit from the top-left, the way macOS icons are.
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [midPurple, deepPurple] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: [])

    drawSkyline(into: ctx, tile: tile, size: s)
    drawRings(into: ctx, tile: tile, size: s)
    ctx.restoreGState()

    // A hairline rim. Below 32 pt it just muddies the edge.
    if s >= 32 {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
        ctx.setLineWidth(max(1, s * 0.004))
        ctx.strokePath()
        ctx.restoreGState()
    }

    drawInitials(into: ctx, tile: tile, size: s)
}

/// The two concentric rings from the logo, near the rim.
func drawRings(into ctx: CGContext, tile: CGRect, size s: CGFloat) {
    guard s >= 32 else { return }
    let unit = tile.width
    let centre = CGPoint(x: tile.midX, y: tile.midY)

    // (radius, line width, alpha) — a heavy outer ring and a light inner one,
    // with the dark gap between them that the logo has.
    let rings: [(CGFloat, CGFloat, CGFloat)] = [
        (0.442, 0.028, 0.92),
        (0.384, 0.013, 0.70),
    ]
    ctx.saveGState()
    for (radius, width, alpha) in rings {
        ctx.setStrokeColor(ringPurple.copy(alpha: alpha)!)
        ctx.setLineWidth(unit * width)
        ctx.addEllipse(in: CGRect(
            x: centre.x - unit * radius, y: centre.y - unit * radius,
            width: unit * radius * 2, height: unit * radius * 2))
        ctx.strokePath()
    }
    ctx.restoreGState()
}

/// A skyline across the middle band, clipped inside the rings.
///
/// Background, not subject: it sits *behind* the initials at low contrast so it
/// reads as texture. At 32 pt and below it is dropped — a few pixels of skyline
/// is grit, not a city.
func drawSkyline(into ctx: CGContext, tile: CGRect, size s: CGFloat) {
    guard s > 32 else { return }
    let unit = tile.width
    let centre = CGPoint(x: tile.midX, y: tile.midY)
    let innerRadius = unit * 0.372

    ctx.saveGState()
    ctx.addEllipse(in: CGRect(
        x: centre.x - innerRadius, y: centre.y - innerRadius,
        width: innerRadius * 2, height: innerRadius * 2))
    ctx.clip()

    // Buildings standing on a line just below centre, so the skyline crowns the
    // initials the way it crowns the wordmark in the logo.
    let baseline = tile.minY + unit * 0.505
    // (x, width, height), left to right, in fractions of the tile. Heights vary
    // widely on purpose: an even row of blocks reads as a barcode, not a city.
    // Two towers carry the silhouette and the rest fall away from them.
    let blocks: [(CGFloat, CGFloat, CGFloat)] = [
        (0.070, 0.070, 0.070), (0.145, 0.048, 0.130), (0.198, 0.088, 0.098),
        (0.292, 0.026, 0.255), (0.300, 0.062, 0.200),  // a spire on a low block
        (0.368, 0.048, 0.128), (0.424, 0.092, 0.310),  // the tall tower
        (0.522, 0.040, 0.155), (0.568, 0.074, 0.245),  // its shorter neighbour
        (0.648, 0.030, 0.290), (0.654, 0.056, 0.170),  // a second spire
        (0.716, 0.070, 0.120), (0.792, 0.050, 0.190), (0.848, 0.078, 0.088),
    ]

    ctx.setFillColor(CGColor(red: 0.04, green: 0.01, blue: 0.09, alpha: 0.72))
    for (x, width, height) in blocks {
        ctx.fill(CGRect(
            x: tile.minX + unit * x, y: baseline,
            width: unit * width, height: unit * height))
    }
    // The ground the city stands on.
    ctx.fill(CGRect(x: tile.minX, y: tile.minY, width: unit, height: baseline - tile.minY))
    ctx.restoreGState()
}

/// **CC**, set in the heaviest system weight and centred on its cap height.
///
/// Core Text rather than `NSAttributedString.draw(at:)` because the latter
/// positions a line fragment, not a baseline — and a mark two characters wide
/// has no margin for a few points of vertical drift.
func drawInitials(into ctx: CGContext, tile: CGRect, size s: CGFloat) {
    let font = NSFont.systemFont(ofSize: tile.height * 0.360, weight: .black)
    let attributed = NSAttributedString(string: "CC", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        // The logo's letterforms are tight; the system font is not.
        .kern: -font.pointSize * 0.055,
    ])
    let line = CTLineCreateWithAttributedString(attributed)
    let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)

    ctx.saveGState()
    // A soft shadow lifts the letters off the skyline behind them, which is the
    // whole reason the skyline can stay as dark as it is.
    if s >= 64 {
        ctx.setShadow(
            offset: .zero, blur: tile.width * 0.032,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.50))
    }
    // Sat in the dark ground below the skyline, where the wordmark sits in the
    // logo — not dead centre, which would put the buildings behind the letters.
    ctx.textPosition = CGPoint(
        x: tile.midX - bounds.width / 2 - bounds.origin.x,
        y: tile.minY + tile.width * 0.272 - font.capHeight / 2)
    CTLineDraw(line, ctx)
    ctx.restoreGState()
}

for (name, pixels) in variants {
    let size = CGFloat(pixels)
    guard let ctx = CGContext(
        data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else {
        FileHandle.standardError.write(Data("✗ could not create a \(pixels)px context\n".utf8))
        exit(1)
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(into: ctx, size: size)

    guard let image = ctx.makeImage() else { exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: pixels, height: pixels)
    guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: "\(iconsetDir)/\(name)"))
}

print("✓ wrote \(variants.count) icons to \(iconsetDir)")
