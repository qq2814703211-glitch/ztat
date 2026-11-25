#!/usr/bin/env swift
// SPDX-License-Identifier: GPL-3.0-or-later
// Generates ztat's bespoke macOS AppIcon.icns using CoreGraphics + AppKit + iconutil (zero Xcode/actool required).

import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: generate-icon.swift <output-AppIcon.icns>\n", stderr)
    exit(2)
}

let outputICNS = URL(fileURLWithPath: CommandLine.arguments[1])
let fm = FileManager.default
let tmpDir = fm.temporaryDirectory.appendingPathComponent("ztat-iconset-\(UUID().uuidString)", isDirectory: true)
let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: tmpDir) }

func renderIcon(pixelSize: Int) -> CGImage {
    let s = CGFloat(pixelSize)
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    // macOS Big Sur / Tahoe standard safe inset (~9.8% margin, continuous squircle)
    let inset = s * 0.095
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft ambient shadow
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -s * 0.022),
        blur: s * 0.042,
        color: CGColor(red: 0.02, green: 0.04, blue: 0.12, alpha: 0.42)
    )
    ctx.addPath(squircle)
    ctx.setFillColor(CGColor(red: 0.07, green: 0.11, blue: 0.22, alpha: 1.0))
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle for internal liquid-glass layered gradient
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()

    let bgColors = [
        CGColor(red: 0.05, green: 0.09, blue: 0.20, alpha: 1.0),
        CGColor(red: 0.09, green: 0.19, blue: 0.36, alpha: 1.0),
        CGColor(red: 0.11, green: 0.33, blue: 0.49, alpha: 1.0)
    ] as CFArray
    let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0])!
    ctx.drawLinearGradient(
        bgGrad,
        start: CGPoint(x: rect.minX, y: rect.minY),
        end: CGPoint(x: rect.maxX, y: rect.maxY),
        options: []
    )

    // Luminous top-left cyan/emerald glass orb glow
    let glowColors = [
        CGColor(red: 0.28, green: 0.88, blue: 0.94, alpha: 0.42),
        CGColor(red: 0.25, green: 0.65, blue: 0.98, alpha: 0.12),
        CGColor(red: 0.20, green: 0.45, blue: 0.95, alpha: 0.0)
    ] as CFArray
    let glowGrad = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 0.48, 1.0])!
    ctx.drawRadialGradient(
        glowGrad,
        startCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22),
        startRadius: 0,
        endCenter: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY - rect.height * 0.22),
        endRadius: rect.width * 0.72,
        options: []
    )

    // Subtle bottom-right violet-indigo depth aura
    let warmColors = [
        CGColor(red: 0.45, green: 0.36, blue: 0.98, alpha: 0.32),
        CGColor(red: 0.32, green: 0.24, blue: 0.80, alpha: 0.0)
    ] as CFArray
    let warmGrad = CGGradient(colorsSpace: colorSpace, colors: warmColors, locations: [0.0, 1.0])!
    ctx.drawRadialGradient(
        warmGrad,
        startCenter: CGPoint(x: rect.maxX - rect.width * 0.20, y: rect.minY + rect.height * 0.20),
        startRadius: 0,
        endCenter: CGPoint(x: rect.maxX - rect.width * 0.20, y: rect.minY + rect.height * 0.20),
        endRadius: rect.width * 0.58,
        options: []
    )

    // Top specular glass sheen
    let sheenRect = CGRect(x: rect.minX - rect.width * 0.1, y: rect.midY + rect.height * 0.06, width: rect.width * 1.2, height: rect.height * 0.55)
    ctx.saveGState()
    ctx.addEllipse(in: sheenRect)
    ctx.clip()
    let sheenGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.18),
            CGColor(red: 1, green: 1, blue: 1, alpha: 0.02)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        sheenGrad,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.midY),
        options: []
    )
    ctx.restoreGState()

    // Central geometric emblem: unified tri-arc status ring + crisp 'Z' telemetry lightning stroke
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let ringR = rect.width * 0.295
    let strokeW = max(1.2, rect.width * 0.056)

    // Three precision status arcs (Status Trio + Stats + PowerGuard unity)
    let arcSpecs: [(CGFloat, CGFloat, CGColor)] = [
        (0.18 * .pi, 0.80 * .pi, CGColor(red: 0.44, green: 0.96, blue: 0.92, alpha: 0.95)), // cyan-mint
        (0.92 * .pi, 1.48 * .pi, CGColor(red: 0.58, green: 0.78, blue: 1.00, alpha: 0.92)), // sky
        (1.60 * .pi, 2.06 * .pi, CGColor(red: 0.76, green: 0.66, blue: 1.00, alpha: 0.92))  // lavender
    ]
    ctx.setLineCap(.round)
    ctx.setLineWidth(strokeW)
    for (startA, endA, color) in arcSpecs {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: s * 0.028, color: color)
        ctx.addArc(center: center, radius: ringR, startAngle: startA, endAngle: endA, clockwise: false)
        ctx.setStrokeColor(color)
        ctx.strokePath()
        ctx.restoreGState()
    }

    // Inner glass disc behind the 'Z' mark
    let innerR = rect.width * 0.195
    ctx.saveGState()
    ctx.addArc(center: center, radius: innerR, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.12))
    ctx.fillPath()
    ctx.addArc(center: center, radius: innerR, startAngle: 0, endAngle: 2 * .pi, clockwise: false)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.setLineWidth(max(0.8, s * 0.008))
    ctx.strokePath()
    ctx.restoreGState()

    // Crisp luminous 'Z' monogram in the core
    let zHalf = rect.width * 0.095
    let zPath = CGMutablePath()
    zPath.move(to: CGPoint(x: center.x - zHalf, y: center.y + zHalf * 0.92))
    zPath.addLine(to: CGPoint(x: center.x + zHalf, y: center.y + zHalf * 0.92))
    zPath.addLine(to: CGPoint(x: center.x - zHalf, y: center.y - zHalf * 0.92))
    zPath.addLine(to: CGPoint(x: center.x + zHalf, y: center.y - zHalf * 0.92))

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
    ctx.addPath(zPath)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.98))
    ctx.setLineWidth(max(1.4, rect.width * 0.052))
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()

    // Outer glass rim highlight
    ctx.addPath(squircle)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.28))
    ctx.setLineWidth(max(1.0, s * 0.012))
    ctx.strokePath()

    ctx.restoreGState()
    return ctx.makeImage()!
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in sizes {
    let img = renderIcon(pixelSize: px)
    let rep = NSBitmapImageRep(cgImage: img)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed encoding \(filename)\n", stderr)
        exit(1)
    }
    try png.write(to: iconsetDir.appendingPathComponent(filename))
}

try fm.createDirectory(at: outputICNS.deletingLastPathComponent(), withIntermediateDirectories: true)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outputICNS.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(proc.terminationStatus)
}
print("Generated \(outputICNS.path)")
