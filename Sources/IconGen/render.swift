#!/usr/bin/env swift
import AppKit

// Render the AI Mac Cleaner app icon (broom + sparkle on Petrol Blue gradient)
// to a 1024x1024 PNG at Sources/IconGen/AIMacCleaner.png.

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

    // Draw the white broom + sparkle icon
    let ctx = NSGraphicsContext.current!
    ctx.saveGraphicsState()

    // Center the icon and tilt the broom diagonally
    let transform = NSAffineTransform()
    transform.translateX(by: size.width / 2, yBy: size.height / 2)
    transform.rotate(byDegrees: -45)
    transform.concat()

    // Soft drop shadow for depth
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.shadowBlurRadius = 24
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.set()

    let white = NSColor.white
    white.setFill()

    // Handle
    let handlePath = NSBezierPath(
        roundedRect: NSRect(x: -28, y: 30, width: 56, height: 340),
        xRadius: 28,
        yRadius: 28
    )
    handlePath.fill()

    // Collar
    let collarPath = NSBezierPath(
        roundedRect: NSRect(x: -50, y: -30, width: 100, height: 60),
        xRadius: 18,
        yRadius: 18
    )
    collarPath.fill()

    // Bristles: five rounded rectangles fanning out from the collar
    let bristleCount = 5
    let maxAngle = 32.0
    for i in 0..<bristleCount {
        let angle = -maxAngle + (Double(i) * 2 * maxAngle / Double(bristleCount - 1))

        ctx.saveGraphicsState()
        let bristleTransform = NSAffineTransform()
        bristleTransform.rotate(byDegrees: angle)
        bristleTransform.concat()

        let bristlePath = NSBezierPath(
            roundedRect: NSRect(x: -22, y: -205, width: 44, height: 175),
            xRadius: 22,
            yRadius: 22
        )
        bristlePath.fill()

        ctx.restoreGraphicsState()
    }

    // Sparkle rays at the bristle tip
    white.setStroke()
    let rayConfig: [(angle: Double, length: CGFloat, width: CGFloat)] = [
        (-55, 48, 10),
        (0, 58, 12),
        (55, 48, 10)
    ]
    let rayOrigin = NSPoint(x: 0, y: -235)
    for cfg in rayConfig {
        let rad = cfg.angle * .pi / 180
        let start = NSPoint(
            x: rayOrigin.x + cos(rad) * 32,
            y: rayOrigin.y + sin(rad) * 32
        )
        let end = NSPoint(
            x: rayOrigin.x + cos(rad) * (32 + cfg.length),
            y: rayOrigin.y + sin(rad) * (32 + cfg.length)
        )
        let ray = NSBezierPath()
        ray.move(to: start)
        ray.line(to: end)
        ray.lineWidth = cfg.width
        ray.lineCapStyle = .round
        ray.stroke()
    }

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
