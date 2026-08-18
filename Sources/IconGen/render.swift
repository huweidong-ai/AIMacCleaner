#!/usr/bin/env swift
import AppKit

// Render the AI Mac Cleaner app icon (Lucide broom outline on Petrol Blue gradient)
// to a 1024x1024 PNG at Sources/IconGen/AIMacCleaner.png.
//
// The broom is the Lucide "broom" glyph (lucide-static v1.31.0), drawn as a white
// outline. The previous solid broom and the "AI" corner badge have been removed.

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size, flipped: false) { _ in

    // Background: rounded rect with gradient
    let rect = NSRect(origin: .zero, size: size)
    let path = NSBezierPath(roundedRect: rect, xRadius: 298, yRadius: 298)

    let gradient = NSGradient(
        colors: [
            NSColor(red: 0.0549, green: 0.4235, blue: 0.6196, alpha: 1.0),
            NSColor(red: 0.0353, green: 0.3059, blue: 0.4510, alpha: 1.0)
        ]
    )!
    gradient.draw(in: path, angle: 315)

    // Draw the Lucide broom as a white outline, centered in the canvas.
    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()

    // Map Lucide's 24x24 coordinate space into the 1024 canvas, centered.
    // y is flipped so the glyph keeps its natural on-screen orientation
    // (handle up-right, bristle head down-left).
    let S: CGFloat = 36
    let t = NSAffineTransform()
    t.translateX(by: size.width / 2 - S * 12, yBy: size.height / 2 + S * 12)
    t.scaleX(by: S, yBy: -S)
    t.concat()

    NSColor.white.setStroke()
    let lw: CGFloat = 1.5

    // Broom head: Lucide outline. The original arcs are approximated by round
    // joins, which read cleanly at icon scale.
    let headPts: [NSPoint] = [
        NSPoint(x: 14.734, y: 13.841),
        NSPoint(x: 14.42,  y: 11.421),
        NSPoint(x: 12.58,  y: 9.58),
        NSPoint(x: 10.159, y: 9.266),
        NSPoint(x: 2.502,  y: 13.727),
        NSPoint(x: 2.3,    y: 15.3),
        NSPoint(x: 8.703,  y: 21.703),
        NSPoint(x: 10.274, y: 21.499)
    ]
    let head = NSBezierPath()
    head.move(to: headPts[0])
    for i in 1..<headPts.count { head.line(to: headPts[i]) }
    head.close()
    head.lineWidth = lw
    head.lineJoinStyle = .round
    head.lineCapStyle = .round
    head.stroke()

    func strokeSeg(_ a: NSPoint, _ b: NSPoint) {
        let p = NSBezierPath()
        p.move(to: a)
        p.line(to: b)
        p.lineWidth = lw
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        p.stroke()
    }
    // Handle
    strokeSeg(NSPoint(x: 13.5, y: 10.5), NSPoint(x: 22, y: 2))
    // Bristle / binding detail lines
    strokeSeg(NSPoint(x: 5, y: 18), NSPoint(x: 7, y: 16))
    strokeSeg(NSPoint(x: 7.699, y: 10.7), NSPoint(x: 13.301, y: 16.301))

    ctx.restoreGraphicsState()

    return true
}

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    print("ERROR: conversion failed")
    exit(1)
}

let png = bitmap.representation(using: NSBitmapImageRep.FileType.png, properties: [:])!
let outPath = "Sources/IconGen/AIMacCleaner.png"
try! png.write(to: URL(fileURLWithPath: outPath))
print("OK: \(outPath) (\(png.count) bytes)")
