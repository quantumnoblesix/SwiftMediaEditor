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

    /// Whether this overlay sits above a drawing stacked at `drawingZIndex`.
    ///
    /// Text and emoji always do, so captions stay readable over the strokes.
    /// A picture sticker does when it was placed after the drawing was last
    /// applied — a higher `zIndex` — so the pencil marks up the stickers already
    /// on the media, while a sticker added later lands on top of the strokes.
    public func sitsAboveDrawing(at drawingZIndex: Int) -> Bool {
        if case .text = content { return true }
        return zIndex > drawingZIndex
    }
}

public extension EditRecipe {
    /// The overlays split around the drawing, each half in stacking order.
    /// Every renderer draws `belowDrawing`, then the strokes, then
    /// `aboveDrawing`, so the preview and the export agree.
    var overlayLayers: (belowDrawing: [Overlay], aboveDrawing: [Overlay]) {
        let sorted = overlays.sorted { $0.zIndex < $1.zIndex }
        guard let drawing else { return ([], sorted) }
        return (sorted.filter { !$0.sitsAboveDrawing(at: drawing.zIndex) },
                sorted.filter { $0.sitsAboveDrawing(at: drawing.zIndex) })
    }

    /// The `zIndex` for something placed now: above every overlay and the
    /// drawing.
    var nextZIndex: Int {
        max(overlays.map(\.zIndex).max() ?? -1, drawing?.zIndex ?? -1) + 1
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
    /// Where the strokes stack among the overlays — see
    /// `Overlay.sitsAboveDrawing(at:)`. The editor sets it above every overlay
    /// each time the strokes change. The default, `Int.min`, keeps the drawing
    /// under every picture sticker, which is how recipes saved before this
    /// property existed render.
    public var zIndex: Int

    public init(data: Data, canvasWidth: Double, canvasHeight: Double, zIndex: Int = .min) {
        self.data = data
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
        self.zIndex = zIndex
    }

    private enum CodingKeys: String, CodingKey {
        case data, canvasWidth, canvasHeight, zIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        data = try c.decode(Data.self, forKey: .data)
        canvasWidth = try c.decode(Double.self, forKey: .canvasWidth)
        canvasHeight = try c.decode(Double.self, forKey: .canvasHeight)
        zIndex = try c.decodeIfPresent(Int.self, forKey: .zIndex) ?? .min
    }

    /// Leaves `zIndex` out while it's the legacy default, so recipes without a
    /// stacking position encode exactly as they did — and never carry `Int.min`
    /// into JSON consumers that read numbers as doubles.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(data, forKey: .data)
        try c.encode(canvasWidth, forKey: .canvasWidth)
        try c.encode(canvasHeight, forKey: .canvasHeight)
        if zIndex != .min { try c.encode(zIndex, forKey: .zIndex) }
    }
}
