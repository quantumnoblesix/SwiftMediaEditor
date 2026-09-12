//
//  Overlay.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// An RGBA color with components in `0...1`. Defined here so the model has no
/// dependency on UIKit/SwiftUI color types; the UI layers convert to/from
/// `UIColor`.
public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let clear = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
}

/// Horizontal alignment for multi-line text overlays.
public enum TextAlignment: String, Codable, Sendable {
    case leading
    case center
    case trailing
}

/// Styling for a text overlay. Emoji require no special handling — they are
/// ordinary characters in `string` rendered with the system font.
public struct TextStyle: Codable, Equatable, Sendable {
    public var string: String
    /// A `UIFont` family/face name, or `nil` for the system font.
    public var fontName: String?
    /// Font size expressed as a fraction of the canvas height, so text scales
    /// with output resolution rather than being pinned to screen points.
    public var fontSizeFraction: Double
    public var color: RGBAColor
    public var alignment: TextAlignment
    /// Optional background fill behind the text (label-style).
    public var backgroundColor: RGBAColor?

    public init(
        string: String,
        fontName: String? = nil,
        fontSizeFraction: Double = 0.08,
        color: RGBAColor = .white,
        alignment: TextAlignment = .center,
        backgroundColor: RGBAColor? = nil
    ) {
        self.string = string
        self.fontName = fontName
        self.fontSizeFraction = fontSizeFraction
        self.color = color
        self.alignment = alignment
        self.backgroundColor = backgroundColor
    }
}

/// A reference to an image overlay. The host app supplies the actual image; we
/// reference it by a stable `id` and optionally carry encoded `data` so a
/// recipe can be fully self-contained when persisted.
public struct ImageRef: Codable, Equatable, Sendable {
    public var id: UUID
    /// PNG-encoded image data. Optional so a recipe can instead reference an
    /// image held in a host-managed asset store by `id` alone.
    public var data: Data?

    public init(id: UUID = UUID(), data: Data? = nil) {
        self.id = id
        self.data = data
    }

    /// Compared by identity, not payload.
    ///
    /// The `id` *is* the image's identity — a new one is minted per inserted
    /// image, and `data` is only a carrier for it. Synthesized equality would
    /// `memcmp` multi-megabyte PNGs, and recipes are compared often: undo/redo
    /// pushes and every equality check on `EditRecipe` would walk the bytes.
    public static func == (lhs: ImageRef, rhs: ImageRef) -> Bool {
        lhs.id == rhs.id
    }
}

/// The payload of an overlay. Text and image share the same placement and
/// transform behavior; emoji are represented as `.text`.
public enum OverlayContent: Codable, Equatable, Sendable {
    case text(TextStyle)
    case image(ImageRef)
}

/// A placeable, transformable element layered on top of the media: styled text,
/// an emoji string, or a host-supplied image.
public struct Overlay: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var content: OverlayContent
    public var transform: NormalizedTransform
    /// Stacking order; higher values render on top.
    public var zIndex: Int

    public init(
        id: UUID = UUID(),
        content: OverlayContent,
        transform: NormalizedTransform = .identity,
        zIndex: Int = 0
    ) {
        self.id = id
        self.content = content
        self.transform = transform
        self.zIndex = zIndex
    }
}

/// Freehand drawing produced by PencilKit. Stored as the opaque
/// `PKDrawing.dataRepresentation()` blob so the model needs no PencilKit import.
///
/// The authoring canvas size (in points) is retained so the drawing can be
/// scaled to any output resolution: the export scale is `outputWidth /
/// canvasWidth`. The canvas has the same aspect ratio as the oriented image, so
/// a single uniform scale is exact.
public struct DrawingData: Codable, Equatable, Sendable {
    public var data: Data
    public var canvasWidth: Double
    public var canvasHeight: Double

    public init(data: Data, canvasWidth: Double, canvasHeight: Double) {
        self.data = data
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}
