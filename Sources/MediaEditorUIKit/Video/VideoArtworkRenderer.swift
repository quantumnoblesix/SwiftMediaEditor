//
//  VideoArtworkRenderer.swift
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
import MediaEditorCore

/// Renders what a video export lays over its frames: the recipe's drawing, then
/// its overlays, on a transparent canvas the size of the output frame.
///
/// It goes through the same compositors as a photo save, at the same pixel
/// scale, so text size, sticker placement and stroke width follow the same rules
/// for both kinds of media — and match what the editor showed on screen.
@MainActor
struct VideoArtworkRenderer {

    private let drawingCompositor = DrawingCompositor()
    private let overlayCompositor = OverlayCompositor()

    /// The artwork for a frame `size` pixels across, or `nil` when there's
    /// nothing to draw — which keeps the export on AVFoundation's built-in
    /// compositor.
    func render(drawing: DrawingData?, overlays: [Overlay], images: [UUID: UIImage], size: CGSize) -> CGImage? {
        guard size.width >= 1, size.height >= 1 else { return nil }
        let strokes = drawing.flatMap { drawingCompositor.strokeImage(for: $0, outputSize: size) }
        guard strokes != nil || !overlays.isEmpty else { return nil }

        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1                     // `size` is already in pixels
        format.opaque = false
        // A frame-sized buffer adds up at 4K: keep it at 8 bits a channel, which
        // strokes and text don't need more than.
        format.preferredRange = .standard
        let bounds = CGRect(origin: .zero, size: size)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            strokes?.draw(in: bounds)
            overlayCompositor.draw(overlays, in: context.cgContext, canvas: size, images: images)
        }.cgImage
    }
}

#endif
