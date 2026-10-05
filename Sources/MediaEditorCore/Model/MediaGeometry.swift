//
//  MediaGeometry.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import CoreGraphics
import Foundation

/// Where a recipe's output frame sits on the source media.
///
/// Overlays and the drawing are laid out in the output frame — after flip,
/// rotation and crop — so a change to that geometry would drag them along with
/// the frame. This maps between the two spaces, measured in source pixels on
/// both sides, so edits can be carried across a geometry change and stay on
/// the same part of the picture. The math matches `VideoComposer`'s geometry
/// transform and `PhotoRenderer`: flip, then rotate clockwise about the centre,
/// then crop the rotated bounding box.
public struct MediaGeometry: Sendable {

    /// The output frame's size, in source pixels.
    public let outputSize: CGSize
    /// Maps a point on the source media to the same point in the output frame,
    /// both in source pixels with a top-left origin.
    public let sourceToOutput: CGAffineTransform

    /// - Parameters:
    ///   - recipe: supplies the flip, rotation and crop.
    ///   - sourceSize: the oriented source's size — any unit, as long as it's
    ///     the same one for every geometry compared against it.
    public init(recipe: EditRecipe, sourceSize: CGSize) {
        let w = sourceSize.width, h = sourceSize.height
        let bounds = CropGeometry.rotatedBoundingSize(width: Double(w), height: Double(h),
                                                      angle: recipe.rotation.radians)
        let crop = recipe.crop?.rect ?? .full

        var t = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        t = t.concatenating(CGAffineTransform(scaleX: recipe.flip.horizontal ? -1 : 1,
                                              y: recipe.flip.vertical ? -1 : 1))
        // y-down, so a positive angle turns clockwise — the recipe's convention.
        t = t.concatenating(CGAffineTransform(rotationAngle: CGFloat(recipe.rotation.radians)))
        t = t.concatenating(CGAffineTransform(
            translationX: bounds.width / 2 - CGFloat(crop.origin.x) * bounds.width,
            y: bounds.height / 2 - CGFloat(crop.origin.y) * bounds.height))
        sourceToOutput = t
        outputSize = CGSize(width: bounds.width * CGFloat(crop.size.width),
                            height: bounds.height * CGFloat(crop.size.height))
    }

    /// Maps a point in this output frame to the same spot of the media in
    /// `other`'s output frame, both in source pixels.
    public func transform(to other: MediaGeometry) -> CGAffineTransform {
        sourceToOutput.inverted().concatenating(other.sourceToOutput)
    }
}

public extension EditRecipe {

    /// `self`, with the overlays of `old` — laid out for `old`'s geometry —
    /// moved so each stays on the same part of the media under this recipe's
    /// flip, rotation and crop.
    ///
    /// Position, physical size and angle all carry over. A flip mirrors where a
    /// sticker sits but not the sticker itself, so text stays readable. An
    /// overlay the new crop leaves out isn't dropped: it lies off the frame,
    /// clipped from the output, and comes back if the crop is widened again.
    ///
    /// The drawing needs PencilKit to move, so it's left alone here; the UIKit
    /// layer carries it across with the same `MediaGeometry` mapping.
    func carryingOverlays(from old: EditRecipe, sourceSize: CGSize) -> EditRecipe {
        guard sourceSize.width > 0, sourceSize.height > 0 else { return self }
        let before = MediaGeometry(recipe: old, sourceSize: sourceSize)
        let after = MediaGeometry(recipe: self, sourceSize: sourceSize)
        guard before.outputSize.width > 0, before.outputSize.height > 0,
              after.outputSize.width > 0, after.outputSize.height > 0 else { return self }
        let map = before.transform(to: after)
        let turn = rotation.radians - old.rotation.radians

        var next = self
        next.overlays = old.overlays.map {
            $0.carried(by: map, from: before.outputSize, to: after.outputSize, mediaTurn: turn)
        }
        return next
    }
}

extension Overlay {

    /// This overlay moved by `map` — source pixels in a `from`-sized output
    /// frame to source pixels in a `to`-sized one — keeping its size on the
    /// media and its angle relative to it. `mediaTurn` is how far the media's
    /// own rotation changed, in radians.
    func carried(by map: CGAffineTransform, from: CGSize, to: CGSize, mediaTurn: Double) -> Overlay {
        var moved = self
        let point = CGPoint(x: CGFloat(transform.center.x) * from.width,
                            y: CGFloat(transform.center.y) * from.height).applying(map)
        moved.transform.center = NormalizedPoint(x: Double(point.x / to.width), y: Double(point.y / to.height))

        // `map` turns by `turn`, and mirrors when its determinant is negative.
        let turn = atan2(Double(map.b), Double(map.a))
        let mirrored = map.a * map.d - map.b * map.c < 0
        if mirrored {
            // The sticker itself isn't mirrored, so its angle's sense reverses,
            // and it could stand either way up. Take whichever keeps it nearer
            // its old angle plus the media's turn: a flip leaves text upright,
            // a rotation still carries it round.
            let target = transform.rotation + mediaTurn
            let candidates = [turn - transform.rotation, turn - transform.rotation + .pi]
            moved.transform.rotation = candidates.min {
                abs(remainder($0 - target, 2 * .pi)) < abs(remainder($1 - target, 2 * .pi))
            }!
        } else {
            moved.transform.rotation = turn + transform.rotation
        }

        // Sizes are fractions of the frame — text of its height, pictures of
        // its width — so the same physical size is a different fraction of a
        // differently sized frame.
        switch content {
        case .text:  moved.transform.scale = transform.scale * Double(from.height / to.height)
        case .image: moved.transform.scale = transform.scale * Double(from.width / to.width)
        }
        return moved
    }
}
