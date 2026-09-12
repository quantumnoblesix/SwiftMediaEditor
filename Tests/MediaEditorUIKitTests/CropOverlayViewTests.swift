//
//  CropOverlayViewTests.swift
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

import CoreGraphics
import Testing
@testable import MediaEditorUIKit
import MediaEditorCore

@MainActor
@Suite("CropOverlayView")
struct CropOverlayViewTests {

    private func makeView(imageFrame: CGRect) -> CropOverlayView {
        let view = CropOverlayView(frame: CGRect(origin: .zero, size: imageFrame.size))
        view.imageFrame = imageFrame
        return view
    }

    private func approxEqual(_ a: Double, _ b: Double, tol: Double = 0.001) -> Bool {
        abs(a - b) <= tol
    }

    @Test("setCrop / normalizedCropRect round-trip")
    func normalizedRoundTrip() {
        let view = makeView(imageFrame: CGRect(x: 10, y: 20, width: 200, height: 400))
        view.setCrop(normalized: .init(x: 0.25, y: 0.1, width: 0.5, height: 0.5))
        let n = view.normalizedCropRect()
        #expect(approxEqual(n.origin.x, 0.25))
        #expect(approxEqual(n.origin.y, 0.1))
        #expect(approxEqual(n.size.width, 0.5))
        #expect(approxEqual(n.size.height, 0.5))
    }

    @Test("reset covers the whole image")
    func resetIsFull() {
        let view = makeView(imageFrame: CGRect(x: 10, y: 20, width: 200, height: 400))
        view.setCrop(normalized: .init(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        view.reset()
        #expect(view.isEffectivelyFull)
    }

    @Test("square aspect produces a 1:1 crop centered in the frame")
    func squareAspect() {
        let view = makeView(imageFrame: CGRect(x: 10, y: 20, width: 200, height: 400))
        view.aspect = .square
        let r = view.cropRect
        #expect(approxEqual(Double(r.width), Double(r.height)))
        // Largest square fits the 200-wide frame → 200×200, centered vertically.
        #expect(approxEqual(Double(r.width), 200))
        #expect(approxEqual(Double(r.midX), 110))
        #expect(approxEqual(Double(r.midY), 220))
        // Stays inside the image frame.
        #expect(r.minY >= 20 && r.maxY <= 420)
    }

    @Test("16:9 aspect keeps ratio and fits inside the frame")
    func ratioAspect() {
        let view = makeView(imageFrame: CGRect(x: 0, y: 0, width: 200, height: 400))
        view.aspect = .ratio(width: 16, height: 9)
        let r = view.cropRect
        #expect(approxEqual(Double(r.width / r.height), 16.0 / 9.0, tol: 0.01))
        #expect(r.minX >= 0 && r.maxX <= 200)
        #expect(r.minY >= 0 && r.maxY <= 400)
    }

    @Test("crop rect never escapes the image frame")
    func staysWithinFrame() {
        let view = makeView(imageFrame: CGRect(x: 10, y: 20, width: 200, height: 400))
        // Ask for a crop larger than the frame; it must be clamped.
        view.setCrop(normalized: .init(x: -0.5, y: -0.5, width: 2, height: 2))
        let r = view.cropRect
        #expect(r.minX >= 10 && r.minY >= 20)
        #expect(r.maxX <= 210 && r.maxY <= 420)
    }
}

#endif
