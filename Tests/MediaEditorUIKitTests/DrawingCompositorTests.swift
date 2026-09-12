//
//  DrawingCompositorTests.swift
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
import PencilKit
import Testing
@testable import MediaEditorUIKit
import MediaEditorCore

@MainActor
@Suite("DrawingCompositor")
struct DrawingCompositorTests {

    private let compositor = DrawingCompositor()

    private func solidImage(_ color: UIColor, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

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

    /// A horizontal white stroke across the middle of a `size` canvas.
    private func strokeDrawing(size: CGSize) -> PKDrawing {
        let ink = PKInk(.pen, color: .white)
        let points = (0...20).map { i -> PKStrokePoint in
            PKStrokePoint(
                location: CGPoint(x: 10 + CGFloat(i) * (size.width - 20) / 20, y: size.height / 2),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 10, height: 10),
                opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        let stroke = PKStroke(ink: ink, path: path)
        return PKDrawing(strokes: [stroke])
    }

    @Test("Empty drawing returns the base unchanged")
    func emptyPassthrough() {
        let base = solidImage(.black, size: CGSize(width: 100, height: 100))
        let empty = DrawingData(data: PKDrawing().dataRepresentation(), canvasWidth: 100, canvasHeight: 100)
        let out = compositor.composite(base: base, drawing: empty)
        #expect(out === base)
    }

    @Test("A stroke is drawn onto the base image")
    func strokeDraws() {
        let base = solidImage(.black, size: CGSize(width: 200, height: 200))
        #expect(nonBlackPixelCount(base) == 0)
        let drawing = DrawingData(
            data: strokeDrawing(size: CGSize(width: 200, height: 200)).dataRepresentation(),
            canvasWidth: 200, canvasHeight: 200
        )
        let out = compositor.composite(base: base, drawing: drawing)
        #expect(out.size == base.size)
        #expect(nonBlackPixelCount(out) > 50)
    }

    @Test("Drawing scales from its authoring canvas to a larger output")
    func scalesToOutput() {
        // Authored at 100×100, composited onto a 400×400 base — strokes should
        // scale up and still be visible.
        let base = solidImage(.black, size: CGSize(width: 400, height: 400))
        let drawing = DrawingData(
            data: strokeDrawing(size: CGSize(width: 100, height: 100)).dataRepresentation(),
            canvasWidth: 100, canvasHeight: 100
        )
        let out = compositor.composite(base: base, drawing: drawing)
        #expect(out.size == CGSize(width: 400, height: 400))
        #expect(nonBlackPixelCount(out) > 50)
    }
}

#endif
