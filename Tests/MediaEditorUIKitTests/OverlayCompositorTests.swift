//
//  OverlayCompositorTests.swift
//  MediaEditorUIKitTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// The turnkey editor UI is UIKit-based, so it builds for iOS and Mac
// Catalyst. On platforms without UIKit this file compiles to nothing and
// hosts use `MediaEditorCore` directly.
#if canImport(UIKit)

import UIKit
import Testing
@testable import MediaEditorUIKit
import MediaEditorCore

@MainActor
@Suite("OverlayCompositor")
struct OverlayCompositorTests {

    private let compositor = OverlayCompositor()

    private func solidImage(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// Counts pixels that are clearly not near-black.
    private func nonBlackPixelCount(_ image: UIImage) -> Int {
        guard let cg = image.cgImage else { return 0 }
        let w = cg.width, h = cg.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var count = 0
        for i in stride(from: 0, to: data.count, by: 4) where data[i] > 60 || data[i+1] > 60 || data[i+2] > 60 {
            count += 1
        }
        return count
    }

    @Test("No overlays returns the base image unchanged")
    func noOverlaysPassthrough() {
        let base = solidImage(.black, size: CGSize(width: 80, height: 80))
        let out = compositor.composite(base: base, overlays: [], images: [:])
        #expect(out === base)
    }

    @Test("Text overlay draws visible pixels over the base")
    func textOverlayDraws() {
        let base = solidImage(.black, size: CGSize(width: 200, height: 200))
        #expect(nonBlackPixelCount(base) == 0)

        let overlay = Overlay(
            content: .text(TextStyle(string: "HELLO", fontSizeFraction: 0.2, color: .white)),
            transform: .init(center: .center, scale: 1, rotation: 0)
        )
        let out = compositor.composite(base: base, overlays: [overlay], images: [:])
        #expect(out.size == base.size)
        #expect(nonBlackPixelCount(out) > 50)  // white glyphs now present
    }

    @Test("Image overlay is composited onto the base")
    func imageOverlayDraws() {
        let base = solidImage(.black, size: CGSize(width: 200, height: 200))
        let ref = ImageRef(id: UUID(), data: nil)
        let overlay = Overlay(content: .image(ref), transform: .identity)
        let sticker = solidImage(.white, size: CGSize(width: 100, height: 100))

        let out = compositor.composite(base: base, overlays: [overlay], images: [ref.id: sticker])
        #expect(nonBlackPixelCount(out) > 100)
    }

    @Test("Overlays render in ascending z-index order")
    func zOrderRespected() {
        // A big red sticker under a big white sticker → center should be white.
        let base = solidImage(.black, size: CGSize(width: 100, height: 100))
        let redRef = ImageRef(id: UUID())
        let whiteRef = ImageRef(id: UUID())
        let red = solidImage(.red, size: CGSize(width: 100, height: 100))
        let white = solidImage(.white, size: CGSize(width: 100, height: 100))
        let overlays = [
            Overlay(content: .image(whiteRef), transform: .identity, zIndex: 1),
            Overlay(content: .image(redRef), transform: .identity, zIndex: 0),
        ]
        let out = compositor.composite(base: base, overlays: overlays,
                                       images: [redRef.id: red, whiteRef.id: white])
        // Sample the center pixel — the white (higher z) should win.
        let cg = out.cgImage!
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: -cg.width/2, y: -cg.height/2, width: cg.width, height: cg.height))
        #expect(px[0] > 200 && px[1] > 200 && px[2] > 200)
    }
}

@Suite("Overlay UIKit support")
struct OverlaySupportTests {

    @Test("RGBAColor round-trips through UIColor")
    @MainActor
    func colorRoundTrip() {
        let original = RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        let restored = RGBAColor(original.uiColor)
        #expect(abs(restored.red - 0.2) < 0.01)
        #expect(abs(restored.green - 0.4) < 0.01)
        #expect(abs(restored.blue - 0.6) < 0.01)
        #expect(abs(restored.alpha - 0.8) < 0.01)
    }

    @Test("Text intrinsic size grows with canvas height")
    @MainActor
    func intrinsicSizeScales() {
        let style = TextStyle(string: "Hello", fontSizeFraction: 0.1)
        let small = style.intrinsicSize(canvasHeight: 200)
        let large = style.intrinsicSize(canvasHeight: 800)
        #expect(large.height > small.height)
        #expect(large.width > small.width)
    }
}

#endif
