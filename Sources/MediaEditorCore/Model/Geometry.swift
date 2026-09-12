//
//  Geometry.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// A point expressed in normalized canvas coordinates, where `(0, 0)` is the
/// top-left of the canvas and `(1, 1)` is the bottom-right. Storing geometry
/// normalized makes a recipe resolution-independent: the same values apply to a
/// small on-screen preview and to a full-resolution export.
public struct NormalizedPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let center = NormalizedPoint(x: 0.5, y: 0.5)
}

/// A size in normalized canvas units (fractions of width/height in `0...1`).
public struct NormalizedSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let full = NormalizedSize(width: 1, height: 1)
}

/// A rectangle in normalized canvas coordinates.
public struct NormalizedRect: Codable, Equatable, Sendable {
    public var origin: NormalizedPoint
    public var size: NormalizedSize

    public init(origin: NormalizedPoint, size: NormalizedSize) {
        self.origin = origin
        self.size = size
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(origin: .init(x: x, y: y), size: .init(width: width, height: height))
    }

    /// The full canvas: `(0, 0)` origin with unit size.
    public static let full = NormalizedRect(x: 0, y: 0, width: 1, height: 1)
}

/// Placement of an overlay relative to the canvas: a normalized center plus a
/// scale (relative to the canvas) and a rotation in radians. This is enough to
/// reconstruct an affine transform at any output resolution.
public struct NormalizedTransform: Codable, Equatable, Sendable {
    /// Center of the overlay in normalized canvas coordinates.
    public var center: NormalizedPoint
    /// Scale factor relative to the overlay's intrinsic, layout-time size.
    public var scale: Double
    /// Rotation in radians, applied around the overlay's center.
    public var rotation: Double

    public init(center: NormalizedPoint = .center, scale: Double = 1, rotation: Double = 0) {
        self.center = center
        self.scale = scale
        self.rotation = rotation
    }

    public static let identity = NormalizedTransform()
}
