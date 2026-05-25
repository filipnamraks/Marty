#!/usr/bin/env swift
import AppKit
import Foundation

// Cream card with "M." Instrument Serif glyph, italic accent dot in warm grey.
// Matches the Marty brand sheet.

func loadFontsFromFontsFolder() {
    let appFolder = URL(fileURLWithPath: CommandLine.arguments.count >= 1 ? CommandLine.arguments[0] : ".")
        .deletingLastPathComponent()
        .appendingPathComponent("MeetingTranscriberApp2/Fonts")
    if let files = try? FileManager.default.contentsOfDirectory(at: appFolder, includingPropertiesForKeys: nil) {
        for url in files where url.pathExtension.lowercased() == "ttf" || url.pathExtension.lowercased() == "otf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

func renderIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let cream = NSColor(red: 0xFB/255.0, green: 0xFA/255.0, blue: 0xF6/255.0, alpha: 1)
    let stone = NSColor(red: 0xE0/255.0, green: 0xDC/255.0, blue: 0xD6/255.0, alpha: 1)
    let ink = NSColor(red: 0x1A/255.0, green: 0x1A/255.0, blue: 0x1A/255.0, alpha: 1)
    let accent = NSColor(red: 0x6B/255.0, green: 0x6B/255.0, blue: 0x66/255.0, alpha: 1)

    let radius = size * 0.224
    let borderWidth = max(1, size * 0.012)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Fill
    let fillPath = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    cream.setFill()
    fillPath.fill()

    // Border (inset so stroke stays inside)
    let borderRect = rect.insetBy(dx: borderWidth/2, dy: borderWidth/2)
    let borderPath = NSBezierPath(roundedRect: borderRect, xRadius: radius - borderWidth/2, yRadius: radius - borderWidth/2)
    stone.setStroke()
    borderPath.lineWidth = borderWidth
    borderPath.stroke()

    // Glyph
    let pointSize = size * 0.66
    let mFont = NSFont(name: "Instrument Serif", size: pointSize) ?? NSFont(name: "Times New Roman", size: pointSize)!
    let dotFont = NSFont(name: "Instrument Serif Italic", size: pointSize) ?? NSFont(name: "Times New Roman Italic", size: pointSize) ?? mFont

    // Negative strokeWidth fills AND outlines — thickens letterforms while keeping the fill.
    // Roughly Bold-weight appearance from a Regular font.
    let strokeWidth: CGFloat = -6
    let mAttrs: [NSAttributedString.Key: Any] = [
        .font: mFont,
        .foregroundColor: ink,
        .strokeWidth: strokeWidth,
        .strokeColor: ink,
    ]
    let dotAttrs: [NSAttributedString.Key: Any] = [
        .font: dotFont,
        .foregroundColor: accent,
        .strokeWidth: strokeWidth,
        .strokeColor: accent,
    ]

    let combined = NSMutableAttributedString()
    combined.append(NSAttributedString(string: "M", attributes: mAttrs))
    combined.append(NSAttributedString(string: ".", attributes: dotAttrs))

    let textSize = combined.size()
    let xOffset = (size - textSize.width) / 2
    // Optical vertical centering for cap-height letterforms
    let yOffset = (size - textSize.height) / 2 - size * 0.04

    combined.draw(at: NSPoint(x: xOffset, y: yOffset))

    return image
}

func saveAsPNG(_ image: NSImage, to url: URL) throws {
    let target = NSSize(width: image.size.width, height: image.size.height)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(target.width),
        pixelsHigh: Int(target.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(origin: .zero, size: target))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed"])
    }
    try data.write(to: url)
}

loadFontsFromFontsFolder()

let scriptDir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let appIconDir = scriptDir.appendingPathComponent("MeetingTranscriberApp2/Assets.xcassets/AppIcon.appiconset")
try FileManager.default.createDirectory(at: appIconDir, withIntermediateDirectories: true)

// macOS AppIcon variants we need to fill
struct Variant {
    let filename: String
    let pixelSize: Int
}

let variants: [Variant] = [
    Variant(filename: "icon_16.png",   pixelSize: 16),
    Variant(filename: "icon_16@2x.png", pixelSize: 32),
    Variant(filename: "icon_32.png",   pixelSize: 32),
    Variant(filename: "icon_32@2x.png", pixelSize: 64),
    Variant(filename: "icon_128.png",  pixelSize: 128),
    Variant(filename: "icon_128@2x.png", pixelSize: 256),
    Variant(filename: "icon_256.png",  pixelSize: 256),
    Variant(filename: "icon_256@2x.png", pixelSize: 512),
    Variant(filename: "icon_512.png",  pixelSize: 512),
    Variant(filename: "icon_512@2x.png", pixelSize: 1024),
]

for v in variants {
    let img = renderIcon(size: CGFloat(v.pixelSize))
    let outURL = appIconDir.appendingPathComponent(v.filename)
    try saveAsPNG(img, to: outURL)
    print("\(v.filename) — \(v.pixelSize)×\(v.pixelSize)")
}

// Rewrite Contents.json so the icons are referenced
let contents: [String: Any] = [
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16", "filename": "icon_16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16", "filename": "icon_16@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32", "filename": "icon_32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32", "filename": "icon_32@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_128@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_256@2x.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_512@2x.png"],
    ],
    "info": ["author": "xcode", "version": 1]
]
let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try data.write(to: appIconDir.appendingPathComponent("Contents.json"))
print("Contents.json updated.")
