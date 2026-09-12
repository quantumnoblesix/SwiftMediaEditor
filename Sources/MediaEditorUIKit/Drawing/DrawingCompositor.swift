//
//  DrawingCompositor.swift
//  MediaEditorUIKit
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// The turnkey editor UI is UIKit-based, so it builds for iOS and Mac
// Catalyst. On platforms without UIKit this file compiles to nothing and
// hosts use `MediaEditorCore` directly.
#if canImport(UIKit)

import UIKit
import PencilKit
import MediaEditorCore

/// Bakes a PencilKit drawing onto a base image, scaling the strokes from their
/// authoring canvas to the base image's resolution.
@MainActor
public struct DrawingCompositor {

    public init() {}

    /// Draws `drawing` over `base`. Returns `base` unchanged if the drawing is
    /// empty or cannot be decoded.
    public func composite(base: UIImage, drawing: DrawingData) -> UIImage {
        // base is a scale-1 pixel image; map authoring points → output pixels.
        let outputSize = CGSize(width: base.size.width * base.scale,
                                height: base.size.height * base.scale)
        guard let strokeImage = strokeImage(for: drawing, outputSize: outputSize) else { return base }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: outputSize, format: format).image { _ in
            base.draw(in: CGRect(origin: .zero, size: outputSize))
            strokeImage.draw(in: CGRect(origin: .zero, size: outputSize))
        }
    }

    /// The strokes alone, rasterized for an output `outputSize` pixels across —
    /// draw the result into that rect. `nil` if the drawing is empty or can't be
    /// decoded.
    func strokeImage(for drawing: DrawingData, outputSize: CGSize) -> UIImage? {
        guard drawing.canvasWidth > 0, drawing.canvasHeight > 0,
              let pkDrawing = try? PKDrawing(data: drawing.data),
              !pkDrawing.bounds.isNull else {
            return nil
        }
        let authoringRect = CGRect(x: 0, y: 0, width: drawing.canvasWidth, height: drawing.canvasHeight)
        return pkDrawing.image(from: authoringRect, scale: outputSize.width / CGFloat(drawing.canvasWidth))
    }
}

#endif
