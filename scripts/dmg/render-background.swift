// SPDX-License-Identifier: GPL-2.0-or-later
//
// Renders the installer window background at 1x and 2x (Finder picks the Retina one).
// Usage: swift render-background.swift <logo.png> <output-dir>
import AppKit
import Foundation

let logo = NSImage(contentsOfFile: CommandLine.arguments[1])!
let output = URL(fileURLWithPath: CommandLine.arguments[2])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let width: CGFloat = 720
let height: CGFloat = 460
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}
// A light window: Finder always draws file-name labels in black over a custom background
// (it treats the window as light mode), so the art is light and the labels need nothing behind them.
// Colours come from the icon: its cream tile, navy and mint links.
let creamTop = rgb(0xf7, 0xf2, 0xe6)
let creamBottom = rgb(0xec, 0xe4, 0xd1)
let navy = rgb(0x14, 0x1a, 0x40)
let slate = rgb(0x5b, 0x62, 0x88)
let mint = rgb(0x2f, 0x9e, 0x76)
let glowBlue = rgb(96, 118, 214)
let glowMint = rgb(85, 181, 143)

func render(scale: Int) throws {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width) * scale,
        pixelsHigh: Int(height) * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    bitmap.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: creamTop, ending: creamBottom)!.draw(in: bounds, angle: -90)

    // Soft glows: blue behind the mark, mint low behind the drop target.
    NSGradient(colors: [glowBlue.withAlphaComponent(0.10), glowBlue.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 360, y: height - 70), radius: 0,
              toCenter: NSPoint(x: 360, y: height - 70), radius: 300, options: [])
    NSGradient(colors: [glowMint.withAlphaComponent(0.10), glowMint.withAlphaComponent(0)])!
        .draw(fromCenter: NSPoint(x: 520, y: height - 270), radius: 0,
              toCenter: NSPoint(x: 520, y: height - 270), radius: 220, options: [])

    func text(_ string: NSAttributedString, x: CGFloat, y: CGFloat, centered: Bool = false) {
        let measured = string.size()
        string.draw(at: NSPoint(x: centered ? x - measured.width / 2 : x, y: height - y - measured.height))
    }
    func plain(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular,
               color: NSColor = navy, kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .kern: kern,
        ])
    }

    // Faint concentric rings, like two linked screens' ripples.
    for radius in stride(from: 214.0, through: 74.0, by: -28.0) {
        let circle = NSBezierPath(ovalIn: NSRect(x: 360 - radius, y: height - 64 - radius,
                                               width: radius * 2, height: radius * 2))
        navy.withAlphaComponent(0.05).setStroke(); circle.lineWidth = 0.6; circle.stroke()
    }

    // Brand mark: the app icon and the two-tone wordmark, centred together.
    let word = NSMutableAttributedString(attributedString: plain("Link", size: 24, weight: .bold, kern: -0.4))
    word.append(plain("Lite", size: 24, weight: .bold, color: mint, kern: -0.4))
    let mark: CGFloat = 46, gap: CGFloat = 8
    let groupWidth = mark + gap + word.size().width
    let groupX = 360 - groupWidth / 2
    logo.draw(in: NSRect(x: groupX, y: height - 40 - mark, width: mark, height: mark),
              from: .zero, operation: .sourceOver, fraction: 1)
    text(word, x: groupX + mark + gap, y: 50)

    text(plain("Your monitors, without the weight.", size: 32, weight: .semibold, kern: -0.6),
         x: 360, y: 112, centered: true)
    text(plain("Drag LinkLite into Applications to get started.", size: 15, color: slate),
         x: 360, y: 158, centered: true)

    // Finder places the real draggable icons over these wells.
    for center: CGFloat in [200, 520] {
        // Tall enough to hold Finder's label (13 pt, about 30 pt below the icon's centre + 52).
        let well = NSBezierPath(roundedRect: NSRect(x: center - 74, y: height - 380,
                                                  width: 148, height: 184), xRadius: 34, yRadius: 34)
        NSColor.white.withAlphaComponent(0.45).setFill(); well.fill()
        navy.withAlphaComponent(0.08).setStroke(); well.lineWidth = 0.75; well.stroke()
    }
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 333, y: height - 270))
    arrow.line(to: NSPoint(x: 385, y: height - 270))
    arrow.move(to: NSPoint(x: 375, y: height - 260))
    arrow.line(to: NSPoint(x: 385, y: height - 270))
    arrow.line(to: NSPoint(x: 375, y: height - 280))
    arrow.lineWidth = 1.8; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    mint.withAlphaComponent(0.9).setStroke(); arrow.stroke()

    let rule = NSBezierPath()
    rule.move(to: NSPoint(x: 40, y: 60)); rule.line(to: NSPoint(x: 680, y: 60))
    navy.withAlphaComponent(0.10).setStroke(); rule.lineWidth = 0.5; rule.stroke()
    let footer = slate.withAlphaComponent(0.85)
    text(plain("Made by Matthew Ball", size: 11, color: footer), x: 40, y: 420)
    let platform = plain("macOS 14+  ·  Apple silicon", size: 11, color: footer)
    text(platform, x: 680 - platform.size().width, y: 420)

    NSGraphicsContext.restoreGraphicsState()
    let name = scale == 1 ? "background.png" : "background@2x.png"
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

try render(scale: 1)
try render(scale: 2)
