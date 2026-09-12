//
//  CropGeometryTests.swift
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

@Suite("CropGeometry")
struct CropGeometryTests {

    private func approx(_ a: Double, _ b: Double, tol: Double = 0.5) -> Bool { abs(a - b) <= tol }

    @Test("Bounding size is unchanged at 0°")
    func boundsAtZero() {
        let s = CropGeometry.rotatedBoundingSize(width: 400, height: 300, angle: 0)
        #expect(approx(s.width, 400))
        #expect(approx(s.height, 300))
    }

    @Test("Bounding size swaps at 90°")
    func boundsAt90() {
        let s = CropGeometry.rotatedBoundingSize(width: 400, height: 300, angle: .pi / 2)
        #expect(approx(s.width, 300))
        #expect(approx(s.height, 400))
    }

    @Test("Bounding size grows at 45°")
    func boundsAt45() {
        let s = CropGeometry.rotatedBoundingSize(width: 400, height: 400, angle: .pi / 4)
        // A 400 square rotated 45° has a bounding box of 400√2 ≈ 565.7.
        #expect(approx(s.width, 565.7, tol: 1))
        #expect(approx(s.height, 565.7, tol: 1))
    }

    @Test("Inscribed rect is the full rect at 0°")
    func inscribedAtZero() {
        let s = CropGeometry.maxInscribedRect(width: 400, height: 300, angle: 0)
        #expect(approx(s.width, 400))
        #expect(approx(s.height, 300))
    }

    @Test("Inscribed rect stays inside the source and shrinks when rotated")
    func inscribedShrinks() {
        let angle = 10.0 * .pi / 180
        let s = CropGeometry.maxInscribedRect(width: 400, height: 300, angle: angle)
        #expect(s.width > 0 && s.height > 0)
        #expect(s.width <= 400 && s.height <= 300)
        // A 10° straighten must lose some area.
        #expect(s.width < 400)
    }

    @Test("Inscribed fraction is a clean 1×1 at 0° and <1 when rotated")
    func inscribedFraction() {
        let full = CropGeometry.inscribedFraction(width: 400, height: 300, angle: 0)
        #expect(approx(full.width, 1))
        #expect(approx(full.height, 1))

        let rotated = CropGeometry.inscribedFraction(width: 400, height: 300, angle: .pi / 12)
        #expect(rotated.width < 1 && rotated.width > 0)
        #expect(rotated.height < 1 && rotated.height > 0)
    }
}
