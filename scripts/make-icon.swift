#!/usr/bin/env swift
//
// make-icon.swift — render the CityDesk app icon at every macOS size.
//
// The mark is a lowercase lambda over a skyline.
//
// λ is the wiki's own `\secpar` — the security parameter, and the single most
// common symbol on the site. It means something precise to the one audience
// this app has, it is unlike any other icon in a Dock, and it survives being
// shrunk to 16 pt, which a page-of-math glyph does not. The three blocks
// beneath it are the "city" half of the name and read as a desk at small sizes.
// The palette is the website's purple, so the app and the site look related.
//
// Pure CoreGraphics: no assets, no dependencies, runs under plain `swift`.
// `make icon` runs `iconutil -c icns build/AppIcon.iconset` on what this writes.

import AppKit

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

func draw(into ctx: CGContext, size s: CGFloat) {
    // macOS icons sit in a rounded tile inset from the canvas, with the corner
    // radius Apple uses (~22% of the tile).
    let inset = s * 0.06
    let tile = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let corner = tile.width * 0.225
    let tilePath = CGPath(
        roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    // The website's purple: #7a30b8 → #3a1060, lit from the top-left the way
    // macOS icons are.
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 0.55, green: 0.24, blue: 0.78, alpha: 1),
            CGColor(red: 0.23, green: 0.06, blue: 0.38, alpha: 1),
        ] as CFArray,
        locations: [0, 1])!

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: tile.minX, y: tile.maxY),
        end: CGPoint(x: tile.maxX, y: tile.minY),
        options: [])

    // A soft highlight across the top, which is what stops a flat gradient
    // looking like a web button.
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0),
        ] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: tile.midX, y: tile.maxY),
        end: CGPoint(x: tile.midX, y: tile.midY),
        options: [])
    ctx.restoreGState()

    // A hairline rim, the detail that makes a tile look placed rather than
    // pasted. Skipped below 32 pt, where it just muddies the edge.
    if s >= 32 {
        ctx.saveGState()
        ctx.addPath(tilePath)
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        ctx.setLineWidth(max(1, s * 0.004))
        ctx.strokePath()
        ctx.restoreGState()
    }

    drawSkyline(into: ctx, tile: tile, size: s)
    drawLambda(into: ctx, tile: tile, size: s)
}

/// Blocks flanking the lambda, standing on a common ground line.
///
/// They sit *beside* the mark rather than behind it: overlapping the legs made
/// the λ read as a stray glyph on top of noise instead of as one building among
/// several.
func drawSkyline(into ctx: CGContext, tile: CGRect, size s: CGFloat) {
    // At 16 pt these are two or three pixels tall and read as grit.
    guard s >= 32 else { return }

    let baseline = tile.minY + tile.height * 0.170
    let unit = tile.width
    // (x, width, height) in fractions of the tile, left to right.
    let blocks: [(CGFloat, CGFloat, CGFloat)] = [
        (0.150, 0.100, 0.170),
        (0.262, 0.070, 0.115),
        (0.668, 0.070, 0.135),
        (0.750, 0.100, 0.205),
    ]

    ctx.saveGState()
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.26))
    for (x, width, height) in blocks {
        let rect = CGRect(
            x: tile.minX + unit * x, y: baseline,
            width: unit * width, height: unit * height)
        let radius = unit * 0.018
        ctx.addPath(CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    }
    ctx.fillPath()

    // The ground line the blocks stand on.
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.42))
    let rule = CGRect(
        x: tile.minX + unit * 0.140, y: baseline - unit * 0.030,
        width: unit * 0.720, height: unit * 0.028)
    ctx.addPath(CGPath(
        roundedRect: rule, cornerWidth: rule.height / 2, cornerHeight: rule.height / 2,
        transform: nil))
    ctx.fillPath()
    ctx.restoreGState()
}

/// A lowercase lambda, drawn as two stroked paths rather than set in a font —
/// no font dependency, and full control of the weight at every size.
func drawLambda(into ctx: CGContext, tile: CGRect, size s: CGFloat) {
    let unit = tile.width
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: tile.minX + unit * x, y: tile.minY + unit * y)
    }

    // Heavier at small sizes, so the mark keeps its colour when it is only a
    // few pixels wide.
    let weight = unit * (s <= 32 ? 0.125 : 0.105)

    ctx.saveGState()
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.setLineWidth(weight)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))

    // The descending stroke: a short hook at the top left, then down to the
    // bottom right, landing on the ground line the blocks stand on.
    ctx.move(to: point(0.360, 0.815))
    ctx.addQuadCurve(to: point(0.487, 0.735), control: point(0.442, 0.820))
    ctx.addLine(to: point(0.648, 0.215))
    ctx.strokePath()

    // The left leg, branching below the apex.
    ctx.move(to: point(0.547, 0.540))
    ctx.addLine(to: point(0.392, 0.215))
    ctx.strokePath()
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
