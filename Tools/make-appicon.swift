#!/usr/bin/env swift
//
//  Renders the three iOS app icons (#111).
//
//  Committed rather than run once and forgotten: an icon is a thing you want
//  to nudge — a heavier bar, a different accent — and a PNG nobody can
//  regenerate turns a five-minute change into a redraw.
//
//  Usage:  swift Tools/make-appicon.swift <output-directory>
//
import AppKit

/// A barbell, loaded. Chosen for legibility at 40pt on a Home Screen rather
/// than for detail: two plates a side, a thick bar, and nothing else. At icon
/// size a silhouette survives and an illustration does not.
func drawIcon(size: CGFloat, background: NSColor, mark: NSColor, into ctx: CGContext) {
    ctx.setFillColor(background.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))

    let unit = size / 1024
    ctx.setFillColor(mark.cgColor)

    // The bar.
    let barHeight = 46 * unit
    ctx.fill(CGRect(x: 150 * unit, y: (512 * unit) - barHeight / 2,
                    width: 724 * unit, height: barHeight))

    // Plates: inner pair tall, outer pair shorter — the shape a loaded bar
    // actually has, and what keeps it readable when the bar itself is a
    // hairline at small sizes.
    func plate(x: CGFloat, height: CGFloat, width: CGFloat) {
        let rect = CGRect(x: x * unit, y: (512 * unit) - (height * unit) / 2,
                          width: width * unit, height: height * unit)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 18 * unit,
                           cornerHeight: 18 * unit, transform: nil))
        ctx.fillPath()
    }
    plate(x: 286, height: 420, width: 74)   // inner left
    plate(x: 190, height: 268, width: 66)   // outer left
    plate(x: 664, height: 420, width: 74)   // inner right
    plate(x: 768, height: 268, width: 66)   // outer right
}

func write(_ name: String, background: NSColor, mark: NSColor, to directory: String) {
    let side = 1024
    guard let ctx = CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("could not make a bitmap context") }

    drawIcon(size: CGFloat(side), background: background, mark: mark, into: ctx)

    guard let image = ctx.makeImage() else { fatalError("could not render") }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode png")
    }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try! png.write(to: url)
    print("wrote \(url.lastPathComponent)")
}

let directory = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}

// Standard: the accent colour, mark knocked out in white.
write("AppIcon.png", background: srgb(0.706, 0.318, 0.161), mark: .white, to: directory)

// Dark: a near-black ground so the tile does not glow on a dark Home Screen,
// with the lighter accent variant carrying the mark.
write("AppIcon-Dark.png", background: srgb(0.106, 0.075, 0.063),
      mark: srgb(0.918, 0.545, 0.322), to: directory)

// Tinted: grayscale by contract — iOS applies the user's tint itself, so any
// colour here would fight it.
write("AppIcon-Tinted.png", background: .black, mark: .white, to: directory)
