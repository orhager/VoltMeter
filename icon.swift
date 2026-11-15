// Renders AppIcon.iconset: black tile with two lime LED columns (Or's design, 15.11.2026).
// Run: swift icon.swift && iconutil -c icns AppIcon.iconset -o AppIcon.icns
import SwiftUI
import AppKit
import ImageIO

let lime = Color(red: 0.71, green: 0.97, blue: 0.04)   // #B5F70A

struct Icon: View {
    // tile follows the macOS icon grid: 824 pt square centred on 1024
    let tile: CGFloat = 824
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: tile * 0.185, style: .continuous)
                .fill(Color(red: 0.035, green: 0.035, blue: 0.045))
                .overlay(RoundedRectangle(cornerRadius: tile * 0.185, style: .continuous)
                    .strokeBorder(Color(white: 0.24), lineWidth: 9))
                .frame(width: tile, height: tile)
                .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
            Canvas { ctx, size in
                let o = CGPoint(x: (size.width - tile) / 2, y: (size.height - tile) / 2)
                let h = tile * 0.0936, pitch = tile * 0.1156, r = tile * 0.024
                let bottom = tile * 0.784
                func column(x0: CGFloat, x1: CGFloat, count: Int) {
                    for i in 0..<count {
                        let y = bottom - h - CGFloat(i) * pitch
                        let rect = CGRect(x: o.x + tile * x0, y: o.y + y, width: tile * (x1 - x0), height: h)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: r), with: .color(lime))
                    }
                }
                column(x0: 0.271, x1: 0.486, count: 5)
                column(x0: 0.523, x1: 0.732, count: 3)
            }
        }
        .frame(width: 1024, height: 1024)
    }
}

@MainActor func render() {
    let r = ImageRenderer(content: Icon())
    r.scale = 1
    guard let cg = r.cgImage else { fatalError("render failed") }
    let dir = URL(fileURLWithPath: "AppIcon.iconset")
    try? FileManager.default.removeItem(at: dir)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256),
                       ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
        // resample in sRGB so the lime keeps its exact value (NSImage drawing shifted it)
        let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: px, height: px))
        let url = dir.appendingPathComponent("icon_\(name).png") as CFURL
        let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
    }
}
MainActor.assumeIsolated { render() }
