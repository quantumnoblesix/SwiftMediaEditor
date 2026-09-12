//
//  EditRecipe.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import Foundation

/// The complete, non-destructive description of an edit session.
///
/// A recipe is a pure value: it never holds the original media, only the
/// transforms to apply to it. Rendering is `originalMedia + EditRecipe -> output`,
/// which keeps the photo and video pipelines symmetric, makes undo/redo a matter
/// of swapping recipes, and lets a host persist a recipe to re-open the editor
/// in its exact prior state.
///
/// Order of operations when applied: `flip -> rotation -> crop -> filter -> drawing -> overlays`.
/// Crop is expressed in the oriented (post flip/rotation) space, so the crop
/// frame matches exactly what the user sees while cropping.
public struct EditRecipe: Codable, Equatable, Sendable {
    /// Region of the source kept. `nil` means the full frame.
    public var crop: CropState?
    public var rotation: RotationState
    public var flip: FlipState
    /// Color filter applied to the whole photo.
    public var filter: PhotoFilter
    /// Freehand drawing, laid over the cropped output frame.
    public var drawing: DrawingData?
    /// Text/emoji/image overlays, applied in ascending `zIndex` order.
    public var overlays: [Overlay]
    /// Kept time range (videos only).
    public var trim: TrimRange?
    /// Drops the audio track from the exported video (videos only). The preview
    /// mutes while this is set; the export writes a video-only file rather than
    /// a silenced audio track.
    public var removeAudio: Bool

    public init(
        crop: CropState? = nil,
        rotation: RotationState = .none,
        flip: FlipState = .none,
        filter: PhotoFilter = .none,
        drawing: DrawingData? = nil,
        overlays: [Overlay] = [],
        trim: TrimRange? = nil,
        removeAudio: Bool = false
    ) {
        self.crop = crop
        self.rotation = rotation
        self.flip = flip
        self.filter = filter
        self.drawing = drawing
        self.overlays = overlays
        self.trim = trim
        self.removeAudio = removeAudio
    }

    // Custom decoding so recipes stay forward/backward compatible: a persisted
    // recipe missing a newer field (e.g. `filter`) still decodes.
    private enum CodingKeys: String, CodingKey {
        case crop, rotation, flip, filter, drawing, overlays, trim, removeAudio
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        crop = try c.decodeIfPresent(CropState.self, forKey: .crop)
        rotation = try c.decodeIfPresent(RotationState.self, forKey: .rotation) ?? .none
        flip = try c.decodeIfPresent(FlipState.self, forKey: .flip) ?? .none
        filter = try c.decodeIfPresent(PhotoFilter.self, forKey: .filter) ?? .none
        drawing = try c.decodeIfPresent(DrawingData.self, forKey: .drawing)
        overlays = try c.decodeIfPresent([Overlay].self, forKey: .overlays) ?? []
        trim = try c.decodeIfPresent(TrimRange.self, forKey: .trim)
        removeAudio = try c.decodeIfPresent(Bool.self, forKey: .removeAudio) ?? false
    }

    /// A recipe that applies no edits.
    public static let identity = EditRecipe()

    /// Whether the recipe would change the source at all.
    public var isIdentity: Bool { self == .identity }

    /// Whether the *rendered base image* differs between the two recipes.
    ///
    /// Overlays are excluded on purpose: they're composited as live views on top
    /// of the render, so moving a sticker changes nothing underneath. Callers
    /// use this to skip a re-render — which for a large photo is tens of
    /// milliseconds and tens of megabytes — on an overlay-only edit. It also
    /// avoids touching overlay image payloads at all.
    public func rendersDifferently(from other: EditRecipe) -> Bool {
        crop != other.crop
            || rotation != other.rotation
            || flip != other.flip
            || filter != other.filter
            || drawing != other.drawing
    }

    /// Overlays sorted bottom-to-top for compositing.
    public var orderedOverlays: [Overlay] {
        overlays.sorted { $0.zIndex < $1.zIndex }
    }
}
