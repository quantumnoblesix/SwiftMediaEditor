//
//  PhotoRendererTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import CoreGraphics
import Testing
@testable import MediaEditorCore

@Suite("PhotoRenderer geometry")
struct PhotoRendererTests {

    private let renderer = PhotoRenderer()

    // MARK: - Test image helpers

    /// Builds a `width`×`height` RGBA image that is black except for a red block
    /// filling the top-left quadrant — an asymmetric marker so rotation and flips
    /// are observable.
    private func makeMarkedImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // CGContext origin is bottom-left; the "top" is the high-Y half.
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2))
        return ctx.makeImage()!
    }

    /// Samples the RGBA of one pixel, reading top-left-origin coordinates.
    private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let offset = (y * w + x) * 4
        return (data[offset], data[offset + 1], data[offset + 2])
    }

    private func isRed(_ p: (r: UInt8, g: UInt8, b: UInt8)) -> Bool {
        p.r > 200 && p.g < 60 && p.b < 60
    }

    // MARK: - Tests

    @Test("Identity recipe preserves dimensions")
    func identityKeepsSize() {
        let src = makeMarkedImage(width: 40, height: 20)
        let out = renderer.renderGeometry(cgImage: src, recipe: .identity)
        #expect(out?.width == 40)
        #expect(out?.height == 20)
    }

    @Test("90° rotation swaps width and height")
    func rotate90SwapsDimensions() {
        let src = makeMarkedImage(width: 40, height: 20)
        let out = renderer.renderGeometry(cgImage: src, recipe: EditRecipe(rotation: RotationState(degrees: 90)))
        #expect(out?.width == 20)
        #expect(out?.height == 40)
    }

    @Test("Crop to the top-left quadrant quarters the pixel dimensions")
    func cropReducesDimensions() {
        let src = makeMarkedImage(width: 40, height: 20)
        let crop = CropState(rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        let out = renderer.renderGeometry(cgImage: src, recipe: EditRecipe(crop: crop))
        #expect(out?.width == 20)
        #expect(out?.height == 10)
    }

    @Test("Crop is applied in oriented space, after rotation")
    func cropAfterRotation() {
        // 40×20 rotated 90° → 20×40 oriented frame; crop its top half → 20×20.
        let src = makeMarkedImage(width: 40, height: 20)
        let recipe = EditRecipe(
            crop: CropState(rect: .init(x: 0, y: 0, width: 1, height: 0.5)),
            rotation: RotationState(degrees: 90)
        )
        let out = renderer.renderGeometry(cgImage: src, recipe: recipe)
        #expect(out?.width == 20)
        #expect(out?.height == 20)
    }

    @Test("Horizontal flip moves the top-left marker to the top-right")
    func horizontalFlipMirrors() throws {
        let src = makeMarkedImage(width: 40, height: 20)
        // Sanity: source has red at top-left, not top-right.
        #expect(isRed(pixel(src, x: 2, y: 2)))
        #expect(!isRed(pixel(src, x: 37, y: 2)))

        let out = try #require(renderer.renderGeometry(
            cgImage: src, recipe: EditRecipe(flip: FlipState(horizontal: true))))
        // After a horizontal flip the marker is on the top-right.
        #expect(!isRed(pixel(out, x: 2, y: 2)))
        #expect(isRed(pixel(out, x: 37, y: 2)))
    }

    @Test("Vertical flip moves the top-left marker to the bottom-left")
    func verticalFlipMirrors() throws {
        let src = makeMarkedImage(width: 40, height: 20)
        let out = try #require(renderer.renderGeometry(
            cgImage: src, recipe: EditRecipe(flip: FlipState(vertical: true))))
        // Marker moves from top-left to bottom-left.
        #expect(!isRed(pixel(out, x: 2, y: 2)))
        #expect(isRed(pixel(out, x: 2, y: 17)))
    }
}
