//
//  VideoComposerTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Testing
@testable import MediaEditorCore

@Suite("VideoComposer geometry")
struct VideoComposerTests {

    private let composer = VideoComposer()
    private let oriented = CGSize(width: 320, height: 240)

    private func renderSize(_ recipe: EditRecipe) -> CGSize {
        composer.geometryTransform(recipe: recipe, preferred: .identity, orientedSize: oriented).renderSize
    }

    private func approx(_ a: CGFloat, _ b: CGFloat, tol: CGFloat = 0.5) -> Bool { abs(a - b) <= tol }

    @Test("Identity keeps the oriented size")
    func identity() {
        #expect(renderSize(.identity) == CGSize(width: 320, height: 240))
    }

    @Test("90° rotation swaps width and height")
    func rotate90() {
        #expect(renderSize(EditRecipe(rotation: RotationState(degrees: 90))) == CGSize(width: 240, height: 320))
    }

    @Test("180° rotation keeps dimensions")
    func rotate180() {
        #expect(renderSize(EditRecipe(rotation: RotationState(degrees: 180))) == CGSize(width: 320, height: 240))
    }

    @Test("Crop scales the render size")
    func crop() {
        let recipe = EditRecipe(crop: CropState(rect: .init(x: 0, y: 0, width: 0.5, height: 0.5)))
        #expect(renderSize(recipe) == CGSize(width: 160, height: 120))
    }

    @Test("Crop is measured in the rotated space")
    func cropAfterRotation() {
        // 320×240 rotated 90° → 240×320; crop the top half → 240×160.
        let recipe = EditRecipe(
            crop: CropState(rect: .init(x: 0, y: 0, width: 1, height: 0.5)),
            rotation: RotationState(degrees: 90)
        )
        #expect(renderSize(recipe) == CGSize(width: 240, height: 160))
    }

    // MARK: - Export resolution ceiling

    @Test("No ceiling keeps the source resolution")
    func uncappedKeepsRenderSize() {
        let geometry = (transform: CGAffineTransform.identity, renderSize: CGSize(width: 3840, height: 2160))
        #expect(composer.scaled(geometry, toFit: nil).renderSize == CGSize(width: 3840, height: 2160))
    }

    @Test("A ceiling shrinks the longest side and keeps the aspect ratio")
    func capShrinksToFit() {
        let geometry = (transform: CGAffineTransform.identity, renderSize: CGSize(width: 3840, height: 2160))
        let capped = composer.scaled(geometry, toFit: 1920).renderSize
        #expect(capped == CGSize(width: 1920, height: 1080))
    }

    @Test("A ceiling above the source is a no-op")
    func capLargerThanSourceDoesNothing() {
        let geometry = (transform: CGAffineTransform.identity, renderSize: CGSize(width: 640, height: 480))
        #expect(composer.scaled(geometry, toFit: 4096).renderSize == CGSize(width: 640, height: 480))
    }

    @Test("Render dimensions are always even, which the video encoders require")
    func renderSizeIsEven() {
        // 1001x667 capped to 500 would land on odd numbers without rounding.
        let geometry = (transform: CGAffineTransform.identity, renderSize: CGSize(width: 1001, height: 667))
        for cap in [CGFloat?.none, 500, 333] {
            let size = composer.scaled(geometry, toFit: cap).renderSize
            #expect(Int(size.width) % 2 == 0, "width \(size.width) must be even")
            #expect(Int(size.height) % 2 == 0, "height \(size.height) must be even")
        }
    }

    @Test("The transform scales with the render size, so the frame still fills it")
    func cappedTransformStillFillsTheFrame() {
        let geometry = (transform: CGAffineTransform.identity, renderSize: CGSize(width: 4000, height: 2000))
        let (transform, size) = composer.scaled(geometry, toFit: 1000)
        let mapped = CGRect(x: 0, y: 0, width: 4000, height: 2000).applying(transform)
        #expect(approx(mapped.width, size.width, tol: 1))
        #expect(approx(mapped.height, size.height, tol: 1))
    }

    @Test("Transform maps the oriented frame onto the render frame")
    func transformFillsRenderFrame() {
        let recipe = EditRecipe(rotation: RotationState(degrees: 90))
        let (transform, size) = composer.geometryTransform(recipe: recipe, preferred: .identity, orientedSize: oriented)
        // The source content rect, transformed, should cover exactly the render frame.
        let mapped = CGRect(origin: .zero, size: oriented).applying(transform)
        #expect(approx(mapped.minX, 0))
        #expect(approx(mapped.minY, 0))
        #expect(approx(mapped.width, size.width))
        #expect(approx(mapped.height, size.height))
    }

    @Test("Flip preserves the oriented size")
    func flipKeepsSize() {
        #expect(renderSize(EditRecipe(flip: FlipState(horizontal: true))) == CGSize(width: 320, height: 240))
    }
}
