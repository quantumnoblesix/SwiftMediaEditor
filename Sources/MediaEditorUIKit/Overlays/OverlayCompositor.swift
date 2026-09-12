//
//  OverlayCompositor.swift
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

/// Bakes overlays onto a fully-rendered base image at output resolution. The
/// same normalized transforms and text metrics used on screen are re-evaluated
/// against the pixel-sized canvas here, so text renders crisp at full size and
/// positions match the preview.
@MainActor
public struct OverlayCompositor {

    public init() {}

    /// Draws `overlays` (ascending `zIndex`) over `base`. `images` supplies the
    /// content for image overlays, keyed by `ImageRef.id`.
    public func composite(base: UIImage, overlays: [Overlay], images: [UUID: UIImage]) -> UIImage {
        guard !overlays.isEmpty else { return base }

        let canvas = CGSize(width: base.size.width, height: base.size.height)
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = base.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: canvas, format: format)

        return renderer.image { context in
            base.draw(in: CGRect(origin: .zero, size: canvas))
            draw(overlays, in: context.cgContext, canvas: canvas, images: images)
        }
    }

    /// Draws `overlays` (ascending `zIndex`) into `cg`, whose drawable area is
    /// `canvas`. Text goes through UIKit string drawing, so `cg` must also be the
    /// current UIKit context — as it is inside a `UIGraphicsImageRenderer`.
    func draw(_ overlays: [Overlay], in cg: CGContext, canvas: CGSize, images: [UUID: UIImage]) {
        for overlay in overlays.sorted(by: { $0.zIndex < $1.zIndex }) {
            draw(overlay: overlay, in: cg, canvas: canvas, images: images)
        }
    }

    private func draw(overlay: Overlay, in cg: CGContext, canvas: CGSize, images: [UUID: UIImage]) {
        let center = CGPoint(x: CGFloat(overlay.transform.center.x) * canvas.width,
                             y: CGFloat(overlay.transform.center.y) * canvas.height)
        let scale = max(0.05, CGFloat(overlay.transform.scale))

        cg.saveGState()
        cg.translateBy(x: center.x, y: center.y)
        cg.rotate(by: CGFloat(overlay.transform.rotation))
        cg.scaleBy(x: scale, y: scale)

        switch overlay.content {
        case let .text(style):
            let size = style.intrinsicSize(canvasHeight: canvas.height)
            let rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            if let bg = style.backgroundColor {
                cg.setFillColor(bg.uiColor.cgColor)
                UIBezierPath(roundedRect: rect, cornerRadius: size.height * 0.15).fill()
            }
            let attributed = NSAttributedString(string: style.string,
                                                attributes: style.attributes(canvasHeight: canvas.height))
            attributed.draw(in: rect)

        case let .image(ref):
            guard let image = images[ref.id] else { break }
            let aspect = image.size.width / max(1, image.size.height)
            let width = StickerView.imageBaseWidthFraction * canvas.width
            let size = CGSize(width: width, height: width / max(0.01, aspect))
            image.draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }

        cg.restoreGState()
    }
}

#endif
