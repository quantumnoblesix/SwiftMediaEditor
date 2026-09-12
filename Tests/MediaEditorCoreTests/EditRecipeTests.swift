//
//  EditRecipeTests.swift
//  MediaEditorCoreTests
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation
import Testing
@testable import MediaEditorCore

@Suite("EditRecipe")
struct EditRecipeTests {

    @Test("Identity recipe applies no edits")
    func identity() {
        #expect(EditRecipe.identity.isIdentity)
        #expect(EditRecipe().isIdentity)
    }

    @Test("A recipe with any edit is not identity")
    func nonIdentity() {
        var recipe = EditRecipe()
        recipe.flip.horizontal = true
        #expect(!recipe.isIdentity)
    }

    @Test("Round-trips through Codable")
    func codableRoundTrip() throws {
        var recipe = EditRecipe()
        recipe.crop = CropState(rect: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                                aspect: .ratio(width: 16, height: 9))
        recipe.rotation = RotationState(degrees: 90)
        recipe.flip = FlipState(horizontal: true, vertical: false)
        recipe.trim = TrimRange(start: 1.5, duration: 4.0)
        recipe.removeAudio = true
        recipe.overlays = [
            Overlay(content: .text(TextStyle(string: "Hi 👋")), zIndex: 0),
            Overlay(content: .image(ImageRef()), zIndex: 1),
        ]

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
    }

    @Test("A recipe saved before audio removal existed decodes with it off")
    func legacyRecipeDecodesWithoutRemoveAudio() throws {
        let legacy = Data(#"{"rotation":{"degrees":90},"trim":{"start":0,"duration":3}}"#.utf8)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: legacy)
        #expect(decoded.removeAudio == false)
        #expect(decoded.rotation.degrees == 90)
    }

    @Test("Removing the audio is an edit, not the identity")
    func removeAudioIsNotIdentity() {
        var recipe = EditRecipe()
        recipe.removeAudio = true
        #expect(!recipe.isIdentity)
    }

    @Test("The Original aspect preset carries no fixed ratio and round-trips")
    func originalAspectPreset() throws {
        // `.original` means "the source's own ratio", which only the crop UI can
        // resolve — so like `.free` it exposes no number here.
        #expect(AspectPreset.original.value == nil)
        #expect(AspectPreset.original != .free)

        var recipe = EditRecipe()
        recipe.crop = CropState(rect: .init(x: 0.1, y: 0, width: 0.8, height: 0.8), aspect: .original)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded.crop?.aspect == .original)
    }

    @Test("Adding the Original case didn't disturb the other presets' encoding")
    func aspectPresetsStillDecode() throws {
        for preset in [AspectPreset.free, .square, .ratio(width: 16, height: 9)] {
            let data = try JSONEncoder().encode(preset)
            #expect(try JSONDecoder().decode(AspectPreset.self, from: data) == preset)
        }
    }

    @Test("Drawing data round-trips through Codable")
    func drawingRoundTrip() throws {
        var recipe = EditRecipe()
        recipe.drawing = DrawingData(data: Data([1, 2, 3, 4]), canvasWidth: 320, canvasHeight: 480)
        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded.drawing?.data == Data([1, 2, 3, 4]))
        #expect(decoded.drawing?.canvasWidth == 320)
        #expect(decoded.drawing?.canvasHeight == 480)
    }

    @Test("orderedOverlays sorts by zIndex ascending")
    func overlayOrdering() {
        let recipe = EditRecipe(overlays: [
            Overlay(content: .text(TextStyle(string: "top")), zIndex: 5),
            Overlay(content: .text(TextStyle(string: "bottom")), zIndex: 1),
        ])
        let ordered = recipe.orderedOverlays
        #expect(ordered.first?.zIndex == 1)
        #expect(ordered.last?.zIndex == 5)
    }
}

@Suite("Transforms")
struct TransformTests {

    @Test("rotateClockwise90 wraps at 360")
    func rotate90Wraps() {
        var r = RotationState(degrees: 315)
        r.rotateClockwise90()
        #expect(r.degrees == 45)  // 405 mod 360
    }

    @Test("rotate180 toggles half turn")
    func rotate180() {
        var r = RotationState(degrees: 90)
        r.rotate180()
        #expect(r.degrees == 270)
    }

    @Test("AspectPreset exposes numeric ratio")
    func aspectRatios() {
        #expect(AspectPreset.free.value == nil)
        #expect(AspectPreset.square.value == 1)
        #expect(AspectPreset.ratio(width: 16, height: 9).value == 16.0 / 9.0)
    }

    @Test("TrimRange computes end")
    func trimEnd() {
        #expect(TrimRange(start: 2, duration: 3).end == 5)
    }
}
