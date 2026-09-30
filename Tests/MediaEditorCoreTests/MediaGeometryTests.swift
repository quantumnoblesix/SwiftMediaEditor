//
//  MediaGeometryTests.swift
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

@Suite("Carrying edits across a geometry change")
struct MediaGeometryTests {

    private let source = CGSize(width: 400, height: 200)

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    private func sticker(at x: Double, _ y: Double, text: Bool = true, rotation: Double = 0) -> Overlay {
        Overlay(content: text ? .text(TextStyle(string: "Hi")) : .image(ImageRef()),
                transform: NormalizedTransform(center: NormalizedPoint(x: x, y: y), scale: 1, rotation: rotation))
    }

    @Test("With no geometry the output frame is the source")
    func identity() {
        let geometry = MediaGeometry(recipe: .identity, sourceSize: source)
        #expect(geometry.outputSize == source)
        #expect(CGPoint(x: 30, y: 40).applying(geometry.sourceToOutput) == CGPoint(x: 30, y: 40))
    }

    @Test("Uncropping keeps a sticker on its spot of the media, at the same size")
    func uncropKeepsPlace() throws {
        let cropped = EditRecipe(crop: CropState(rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
                                 overlays: [sticker(at: 0.5, 0.5)])
        let whole = EditRecipe().carryingOverlays(from: cropped, sourceSize: source)
        let moved = try #require(whole.overlays.first)
        #expect(near(moved.transform.center.x, 0.75) && near(moved.transform.center.y, 0.75),
                "the middle of the bottom-right quarter")
        #expect(near(moved.transform.scale, 0.5), "same size on the media, half the frame's height")
    }

    @Test("Cropping a sticker out keeps it, just off the frame")
    func croppedOutIsKept() throws {
        let whole = EditRecipe(overlays: [sticker(at: 0.1, 0.1)])
        var cropped = EditRecipe(crop: CropState(rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)))
        cropped = cropped.carryingOverlays(from: whole, sourceSize: source)
        let moved = try #require(cropped.overlays.first)
        #expect(moved.transform.center.x < 0 && moved.transform.center.y < 0)
    }

    @Test("Rotating the media turns a sticker with it")
    func rotationCarries() throws {
        let flat = EditRecipe(overlays: [sticker(at: 0.25, 0.5, text: false)])
        let turned = EditRecipe(rotation: RotationState(degrees: 90)).carryingOverlays(from: flat, sourceSize: source)
        let moved = try #require(turned.overlays.first)
        // A point left of centre ends up above it after a clockwise quarter turn.
        #expect(near(moved.transform.center.x, 0.5) && near(moved.transform.center.y, 0.25))
        #expect(near(moved.transform.rotation, .pi / 2))
        // Pictures are sized against the frame's width, which went 400 → 200.
        #expect(near(moved.transform.scale, 2))
    }

    @Test("A flip mirrors where a sticker sits and its tilt, but keeps it upright")
    func flipMirrorsPosition() throws {
        let plain = EditRecipe(overlays: [sticker(at: 0.2, 0.3, rotation: 0.4)])
        let flipped = EditRecipe(flip: FlipState(horizontal: true, vertical: false))
            .carryingOverlays(from: plain, sourceSize: source)
        let moved = try #require(flipped.overlays.first)
        #expect(near(moved.transform.center.x, 0.8) && near(moved.transform.center.y, 0.3))
        #expect(near(cos(moved.transform.rotation), cos(-0.4)) && near(sin(moved.transform.rotation), sin(-0.4)),
                "the tilt mirrors, and the text stays upright")

        let upsideDown = EditRecipe(flip: FlipState(horizontal: false, vertical: true))
            .carryingOverlays(from: EditRecipe(overlays: [sticker(at: 0.2, 0.3)]), sourceSize: source)
        #expect(near(cos(try #require(upsideDown.overlays.first).transform.rotation), 1),
                "a vertical flip doesn't stand text on its head")
        #expect(near(moved.transform.scale, 1))
    }

    @Test("A round trip puts every sticker back where it was")
    func roundTrip() throws {
        let start = EditRecipe(overlays: [sticker(at: 0.3, 0.7, rotation: 0.2), sticker(at: 0.9, 0.1, text: false)])
        var edited = EditRecipe(crop: CropState(rect: NormalizedRect(x: 0.1, y: 0.2, width: 0.6, height: 0.5)),
                                rotation: RotationState(degrees: 12),
                                flip: FlipState(horizontal: true, vertical: false))
        edited = edited.carryingOverlays(from: start, sourceSize: source)
        let back = EditRecipe().carryingOverlays(from: edited, sourceSize: source)
        for (a, b) in zip(start.overlays, back.overlays) {
            #expect(near(a.transform.center.x, b.transform.center.x) && near(a.transform.center.y, b.transform.center.y))
            #expect(near(a.transform.scale, b.transform.scale))
            #expect(near(cos(a.transform.rotation), cos(b.transform.rotation))
                    && near(sin(a.transform.rotation), sin(b.transform.rotation)))
        }
    }
}
