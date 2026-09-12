//
//  CropGeometry.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation

/// Pure geometry helpers for the crop + straighten tool.
public enum CropGeometry {

    /// The axis-aligned bounding size of a `width` × `height` rectangle rotated
    /// by `angle` radians.
    public static func rotatedBoundingSize(width: Double, height: Double, angle: Double) -> CGSize {
        let s = abs(sin(angle)), c = abs(cos(angle))
        return CGSize(width: width * c + height * s,
                      height: width * s + height * c)
    }

    /// The largest axis-aligned rectangle (same orientation as the source) that
    /// fits entirely inside a `width` × `height` rectangle rotated by `angle`
    /// radians. Used to keep a straightened crop free of empty corners.
    ///
    /// Based on the classic "rotated rectangle with max area" solution.
    public static func maxInscribedRect(width w: Double, height h: Double, angle: Double) -> CGSize {
        guard w > 0, h > 0 else { return .zero }
        let sinA = abs(sin(angle))
        let cosA = abs(cos(angle))

        let longSide = max(w, h)
        let shortSide = min(w, h)

        if shortSide <= 2 * sinA * cosA * longSide || abs(sinA - cosA) < 1e-10 {
            // Half-constrained: the crop touches the middle of the long side.
            let x = 0.5 * shortSide
            let (rw, rh): (Double, Double) = w >= h
                ? (sinA > 0 ? x / sinA : w, cosA > 0 ? x / cosA : h)
                : (cosA > 0 ? x / cosA : w, sinA > 0 ? x / sinA : h)
            return CGSize(width: min(rw, w), height: min(rh, h))
        } else {
            // Fully constrained by all four sides.
            let cos2 = cosA * cosA - sinA * sinA
            let rw = (w * cosA - h * sinA) / cos2
            let rh = (h * cosA - w * sinA) / cos2
            return CGSize(width: rw, height: rh)
        }
    }

    /// The fraction of the rotated bounding box occupied by the max inscribed
    /// rectangle — i.e. `maxInscribedRect / rotatedBoundingSize`. Multiply by the
    /// on-screen bounding frame to get the clean crop area in view coordinates.
    public static func inscribedFraction(width w: Double, height h: Double, angle: Double) -> CGSize {
        let inscribed = maxInscribedRect(width: w, height: h, angle: angle)
        let bounds = rotatedBoundingSize(width: w, height: h, angle: angle)
        guard bounds.width > 0, bounds.height > 0 else { return CGSize(width: 1, height: 1) }
        return CGSize(width: inscribed.width / bounds.width,
                      height: inscribed.height / bounds.height)
    }
}
