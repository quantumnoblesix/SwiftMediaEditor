//
//  Transforms.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// Rotation applied to the whole canvas. Stores a single signed angle in
/// degrees so that free-form rotation and the 90°/180° presets are the same
/// thing — presets are just helpers that snap or step the angle.
public struct RotationState: Codable, Equatable, Sendable {
    /// Total rotation in degrees, clockwise-positive.
    public var degrees: Double

    public init(degrees: Double = 0) {
        self.degrees = degrees
    }

    public static let none = RotationState(degrees: 0)

    /// Rotation in radians, convenient for building affine transforms.
    public var radians: Double { degrees * .pi / 180 }

    /// Steps the rotation by a quarter turn clockwise (the 90° preset).
    public mutating func rotateClockwise90() {
        degrees = (degrees + 90).truncatingRemainder(dividingBy: 360)
    }

    /// Steps the rotation by a half turn (the 180° preset).
    public mutating func rotate180() {
        degrees = (degrees + 180).truncatingRemainder(dividingBy: 360)
    }
}

/// Mirroring applied to the canvas. Horizontal and vertical flips are
/// independent toggles; applying both is equivalent to a 180° rotation.
public struct FlipState: Codable, Equatable, Sendable {
    public var horizontal: Bool
    public var vertical: Bool

    public init(horizontal: Bool = false, vertical: Bool = false) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public static let none = FlipState()
}

/// A constraint on the crop rectangle's aspect ratio.
public enum AspectPreset: Codable, Equatable, Sendable {
    /// The source's own ratio — whatever the frame being cropped already is.
    /// Unlike the fixed presets its number depends on the media (and on any 90°
    /// rotation applied in the crop tool), so the crop UI resolves it.
    case original
    case free
    case square
    /// An arbitrary ratio such as 16:9 or 4:3.
    case ratio(width: Double, height: Double)

    /// The numeric width-over-height ratio, or `nil` when the preset doesn't fix
    /// one: `.free` is unconstrained, and `.original` is media-dependent.
    public var value: Double? {
        switch self {
        case .free, .original: return nil
        case .square: return 1
        case let .ratio(w, h): return h == 0 ? nil : w / h
        }
    }
}

/// The region kept, plus the aspect-ratio constraint the crop UI was using. The
/// rectangle is normalized (top-left origin) to the *oriented* image — i.e. the
/// frame after flip and rotation are applied — so it matches what the user sees
/// while cropping.
public struct CropState: Codable, Equatable, Sendable {
    public var rect: NormalizedRect
    public var aspect: AspectPreset

    public init(rect: NormalizedRect = .full, aspect: AspectPreset = .free) {
        self.rect = rect
        self.aspect = aspect
    }
}

/// The kept time range of a video, in seconds. Kept as `Double` rather than
/// `CMTime` so the model stays free of any AVFoundation/CoreMedia dependency;
/// the video composer converts to `CMTime` at render time.
public struct TrimRange: Codable, Equatable, Sendable {
    /// Start offset from the beginning of the asset, in seconds.
    public var start: Double
    /// Duration of the kept range, in seconds.
    public var duration: Double

    public init(start: Double, duration: Double) {
        self.start = start
        self.duration = duration
    }

    public var end: Double { start + duration }
}
