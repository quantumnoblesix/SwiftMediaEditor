//
//  PhotoRenderer.swift
//  MediaEditorCore
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import CoreImage
import CoreGraphics

/// Applies the geometric part of an `EditRecipe` (crop → rotation → flip) to a
/// still image using Core Image.
///
/// This renderer is deliberately UI-free: it knows nothing about text fonts or
/// PencilKit. Overlay and freehand-drawing compositing requires UIKit
/// rasterization and is layered on top in `MediaEditorUIKit`, which rasterizes
/// each overlay to a `CIImage` and composites it over this renderer's output.
public struct PhotoRenderer: Sendable {
    /// A reusable Core Image context. `CIContext` is thread-safe and expensive
    /// to create, so callers should keep one renderer around.
    private let context: CIContext

    public init(context: CIContext = CIContext(options: [.useSoftwareRenderer: false])) {
        self.context = context
    }

    /// Applies crop, rotation, and flip to `image`, returning a new `CIImage`
    /// whose extent origin is normalized back to `(0, 0)`.
    ///
    /// The input is assumed to be orientation-normalized (EXIF baked to `.up`)
    /// by the caller before reaching here.
    public func applyGeometry(to image: CIImage, recipe: EditRecipe) -> CIImage {
        var result = image

        // 1. Flip. Mirror around the image center for each enabled axis.
        if recipe.flip.horizontal || recipe.flip.vertical {
            let e = result.extent
            let sx: CGFloat = recipe.flip.horizontal ? -1 : 1
            let sy: CGFloat = recipe.flip.vertical ? -1 : 1
            var t = CGAffineTransform(translationX: e.midX, y: e.midY)
            t = t.scaledBy(x: sx, y: sy)
            t = t.translatedBy(x: -e.midX, y: -e.midY)
            result = result.transformed(by: t)
        }

        // 2. Rotation. Recipe degrees are clockwise-positive; Core Graphics
        //    rotations are counter-clockwise-positive, so negate.
        if recipe.rotation.degrees != 0 {
            let e = result.extent
            var t = CGAffineTransform(translationX: e.midX, y: e.midY)
            t = t.rotated(by: -recipe.rotation.radians)
            t = t.translatedBy(x: -e.midX, y: -e.midY)
            result = result.transformed(by: t)
        }

        // Normalize the extent origin to zero so the crop rect, which is
        // expressed in the *oriented* display space, maps directly.
        result = result.transformed(by: CGAffineTransform(translationX: -result.extent.origin.x,
                                                          y: -result.extent.origin.y))

        // 3. Crop. The recipe's rect is normalized with a top-left origin in the
        //    oriented (post flip/rotation) space; CIImage uses a bottom-left
        //    origin, so flip Y.
        if let crop = recipe.crop {
            let e = result.extent
            let w = crop.rect.size.width * e.width
            let h = crop.rect.size.height * e.height
            let x = crop.rect.origin.x * e.width
            let yTop = crop.rect.origin.y * e.height
            let y = e.height - yTop - h
            result = result.cropped(to: CGRect(x: x, y: y, width: w, height: h))
            result = result.transformed(by: CGAffineTransform(translationX: -result.extent.origin.x,
                                                               y: -result.extent.origin.y))
        }

        return result
    }

    /// Renders geometry + color filter of `recipe` applied to `cgImage` into a
    /// new `CGImage`. Returns `nil` if rasterization fails.
    ///
    /// - Note: Overlays and drawing are *not* applied here — see the type doc.
    public func renderGeometry(cgImage: CGImage, recipe: EditRecipe) -> CGImage? {
        let input = CIImage(cgImage: cgImage)
        var output = applyGeometry(to: input, recipe: recipe)
        output = applyFilter(recipe.filter, to: output)
        return context.createCGImage(output, from: output.extent)
    }

    /// Applies a `PhotoFilter` to a Core Image image, preserving its extent.
    public func applyFilter(_ filter: PhotoFilter, to image: CIImage) -> CIImage {
        let output: CIImage?
        switch filter {
        case .none:
            return image
        case .vivid:
            output = ciFilter("CIVibrance", on: image) { $0.setValue(1.0, forKey: "inputAmount") }
        case .mono:
            output = ciFilter("CIPhotoEffectMono", on: image)
        case .noir:
            output = ciFilter("CIPhotoEffectNoir", on: image)
        case .fade:
            output = ciFilter("CIPhotoEffectFade", on: image)
        case .chrome:
            output = ciFilter("CIPhotoEffectChrome", on: image)
        case .sepia:
            output = ciFilter("CISepiaTone", on: image) { $0.setValue(0.9, forKey: kCIInputIntensityKey) }
        case .invert:
            output = ciFilter("CIColorInvert", on: image)
        }
        return (output ?? image).cropped(to: image.extent)
    }

    private func ciFilter(_ name: String, on image: CIImage,
                          configure: ((CIFilter) -> Void)? = nil) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        configure?(filter)
        return filter.outputImage
    }
}
