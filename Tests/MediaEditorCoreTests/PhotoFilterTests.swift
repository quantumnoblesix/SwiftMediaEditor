//
//  PhotoFilterTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation
import Testing
@testable import MediaEditorCore

@Suite("PhotoFilter")
struct PhotoFilterTests {

    private let renderer = PhotoRenderer()

    /// A small colored test image.
    private func makeImage(width: Int = 20, height: Int = 20) -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    private func firstPixel(_ image: CGImage) -> (r: UInt8, g: UInt8, b: UInt8) {
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (px[0], px[1], px[2])
    }

    @Test("Recipe with a filter round-trips through Codable")
    func codableRoundTrip() throws {
        var recipe = EditRecipe()
        recipe.filter = .noir
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded.filter == .noir)
    }

    @Test("A recipe missing the filter key still decodes (forward compatible)")
    func decodesWithoutFilterKey() throws {
        // Simulates a recipe persisted before `filter` existed.
        let json = #"{"rotation":{"degrees":0},"flip":{"horizontal":false,"vertical":false},"overlays":[]}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(decoded.filter == .none)
    }

    @Test(".none filter keeps the image blue-dominant (unchanged)")
    func noneIsIdentity() {
        let src = makeImage()  // (0.2, 0.6, 0.9) — blue dominant
        let out = renderer.renderGeometry(cgImage: src, recipe: EditRecipe(filter: .none))!
        let p = firstPixel(out)
        #expect(p.b > p.g)
        #expect(p.g > p.r)
    }

    @Test("Invert flips the dominant channel from blue to red")
    func invertChangesColor() {
        let src = makeImage()  // blue dominant
        let out = renderer.renderGeometry(cgImage: src, recipe: EditRecipe(filter: .invert))!
        let p = firstPixel(out)
        // After inverting, the low red (0.2) becomes high and the high blue drops.
        #expect(p.r > p.b)
        #expect(p.r > p.g)
    }

    @Test("Mono desaturates to a gray pixel")
    func monoDesaturates() {
        let src = makeImage()
        let out = renderer.renderGeometry(cgImage: src, recipe: EditRecipe(filter: .mono))!
        let p = firstPixel(out)
        // Mono → R≈G≈B.
        #expect(abs(Int(p.r) - Int(p.g)) < 20)
        #expect(abs(Int(p.g) - Int(p.b)) < 20)
    }

    @Test("Every filter produces an output of the same size")
    func allFiltersPreserveSize() {
        let src = makeImage(width: 32, height: 24)
        for filter in PhotoFilter.allCases {
            let out = renderer.renderGeometry(cgImage: src, recipe: EditRecipe(filter: filter))
            #expect(out?.width == 32)
            #expect(out?.height == 24)
        }
    }
}
