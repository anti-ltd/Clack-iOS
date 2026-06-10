#!/usr/bin/env swift
//
// RenderAppIcon.swift — renders the Clack iOS app icon into the asset catalog.
//
// Run via `make icon`. Customize gradient and symbol to match the app's brand.
//
import AppKit

let size = 1024.0
let outDir = "Resources/Assets.xcassets/AppIcon.appiconset"
let outPath = "\(outDir)/icon-1024.png"

let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fatalError("no graphics context")
}

// Full-bleed diagonal gradient, top-left dark gray → bottom-right dark gray (iOS system dark grays).
let colors = [
    NSColor(srgbRed: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1).cgColor,
    NSColor(srgbRed: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1).cgColor,
]
let gradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: colors as CFArray,
    locations: [0, 1])!
ctx.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: size),
    end: CGPoint(x: size, y: 0),
    options: [])

// Centred white glyph at 50% of the canvas.
let glyphPt = size * 0.50
let config = NSImage.SymbolConfiguration(pointSize: glyphPt, weight: .medium)
if let symbol = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)?  // walkie-talkie / PTT brand mark
    .withSymbolConfiguration(config) {
    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let r = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: r)
    r.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let gs = tinted.size
    let origin = NSPoint(x: (size - gs.width) / 2, y: (size - gs.height) / 2)
    tinted.draw(
        at: origin, from: NSRect(origin: .zero, size: gs),
        operation: .sourceOver, fraction: 1.0)
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to encode PNG")
}
try! png.write(to: URL(fileURLWithPath: outPath))
print("→ \(outPath)")
