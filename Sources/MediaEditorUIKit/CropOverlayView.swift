//
//  CropOverlayView.swift
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

/// Interactive crop overlay: a dimmed mask outside the crop rectangle, a
/// rule-of-thirds grid, and draggable corner handles. Drag a corner to resize
/// (respecting the aspect lock), or drag inside to reposition. The crop stays
/// within `imageFrame` — the rect where the image is actually displayed.
@MainActor
final class CropOverlayView: UIView {

    /// The rect, in this view's coordinates, where the image is displayed
    /// (aspect-fit). The crop is constrained to this frame.
    var imageFrame: CGRect = .zero {
        didSet {
            if cropRect == .zero { cropRect = clampRect }
            clampToImageFrame()
        }
    }

    /// The area the crop is allowed to occupy. Defaults to `imageFrame`, but when
    /// the image is straightened this is the smaller inscribed rectangle so the
    /// crop never includes empty corners. Normalization is always relative to
    /// `imageFrame`; only clamping uses this.
    var allowedRect: CGRect = .zero {
        didSet { clampToImageFrame() }
    }

    /// The rect the crop is clamped within.
    private var clampRect: CGRect {
        allowedRect == .zero ? imageFrame : allowedRect
    }

    /// The current crop rectangle, in this view's coordinates.
    private(set) var cropRect: CGRect = .zero {
        didSet { setNeedsDisplay() }
    }

    /// The active aspect-ratio constraint. Setting it re-fits the crop rect.
    var aspect: AspectPreset = .free {
        didSet { fitToAspect() }
    }

    /// The ratio the crop is locked to, or `nil` when it is unconstrained.
    ///
    /// `.original` has no fixed number: it means "the frame being cropped", so it
    /// resolves from `imageFrame` — which is the source *after* any 90° rotation,
    /// so the lock follows the media the way the user sees it.
    private var lockedRatio: Double? {
        if case .original = aspect {
            guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
            return Double(imageFrame.width / imageFrame.height)
        }
        return aspect.value
    }

    private let handleHitRadius: CGFloat = 32
    private let minCropSide: CGFloat = 48

    private enum Grab { case none, move, topLeft, topRight, bottomLeft, bottomRight }
    private var grab: Grab = .none
    private var grabStartCrop: CGRect = .zero
    private var grabStartPoint: CGPoint = .zero

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        // The frame is one adjustable element for VoiceOver: swipe up or down to
        // grow or shrink it, and use the actions to move it.
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = L10n.cropArea
        accessibilityCustomActions = [
            moveAction(L10n.moveUp, dx: 0, dy: -1),
            moveAction(L10n.moveDown, dx: 0, dy: 1),
            moveAction(L10n.moveLeft, dx: -1, dy: 0),
            moveAction(L10n.moveRight, dx: 1, dy: 0),
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Public API

    /// Initializes the crop rect from a normalized (top-left origin) rect
    /// expressed relative to `imageFrame`. Requires `imageFrame` to be set first.
    func setCrop(normalized rect: NormalizedRect) {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return }
        cropRect = CGRect(
            x: imageFrame.minX + rect.origin.x * imageFrame.width,
            y: imageFrame.minY + rect.origin.y * imageFrame.height,
            width: rect.size.width * imageFrame.width,
            height: rect.size.height * imageFrame.height
        )
        clampToImageFrame()
    }

    /// Resets the crop to the full allowed area, honoring the current aspect lock.
    func reset() {
        cropRect = clampRect
        fitToAspect()
    }

    /// The crop rect normalized (top-left origin) relative to `imageFrame`.
    func normalizedCropRect() -> NormalizedRect {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return .full }
        return NormalizedRect(
            x: Double((cropRect.minX - imageFrame.minX) / imageFrame.width),
            y: Double((cropRect.minY - imageFrame.minY) / imageFrame.height),
            width: Double(cropRect.width / imageFrame.width),
            height: Double(cropRect.height / imageFrame.height)
        )
    }

    /// Whether the crop effectively covers the whole image (within a tolerance).
    var isEffectivelyFull: Bool {
        let n = normalizedCropRect()
        return n.origin.x < 0.005 && n.origin.y < 0.005 &&
               n.size.width > 0.995 && n.size.height > 0.995
    }

    // MARK: - Aspect

    /// Fits the largest rect of the locked ratio inside `imageFrame`, centered on
    /// the current crop's center. No-op for `.free`.
    private func fitToAspect() {
        let bounds = clampRect
        guard bounds.width > 0 else { setNeedsDisplay(); return }
        guard let ratio = lockedRatio else { setNeedsDisplay(); return }
        var w = bounds.width
        var h = w / ratio
        if h > bounds.height {
            h = bounds.height
            w = h * ratio
        }
        let center = cropRect == .zero ? CGPoint(x: bounds.midX, y: bounds.midY)
                                       : CGPoint(x: cropRect.midX, y: cropRect.midY)
        var rect = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
        rect = clamp(rect, keepingSizeWithin: bounds)
        cropRect = rect
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            grab = hitTestGrab(at: point)
            grabStartCrop = cropRect
            grabStartPoint = point
        case .changed:
            guard grab != .none else { return }
            if grab == .move {
                let dx = point.x - grabStartPoint.x
                let dy = point.y - grabStartPoint.y
                var moved = grabStartCrop.offsetBy(dx: dx, dy: dy)
                let bounds = clampRect
                moved.origin.x = min(max(moved.origin.x, bounds.minX), bounds.maxX - moved.width)
                moved.origin.y = min(max(moved.origin.y, bounds.minY), bounds.maxY - moved.height)
                cropRect = moved
            } else {
                resize(corner: grab, to: point)
            }
        case .ended, .cancelled, .failed:
            grab = .none
        default:
            break
        }
    }

    private func hitTestGrab(at p: CGPoint) -> Grab {
        let corners: [(Grab, CGPoint)] = [
            (.topLeft, CGPoint(x: cropRect.minX, y: cropRect.minY)),
            (.topRight, CGPoint(x: cropRect.maxX, y: cropRect.minY)),
            (.bottomLeft, CGPoint(x: cropRect.minX, y: cropRect.maxY)),
            (.bottomRight, CGPoint(x: cropRect.maxX, y: cropRect.maxY)),
        ]
        for (grab, corner) in corners where hypot(p.x - corner.x, p.y - corner.y) <= handleHitRadius {
            return grab
        }
        return cropRect.contains(p) ? .move : .none
    }

    /// Resizes by moving one corner, keeping the opposite corner fixed. When an
    /// aspect ratio is locked the height is derived from the width and clamped so
    /// the rect stays within `imageFrame`.
    private func resize(corner: Grab, to rawPoint: CGPoint) {
        let bounds = clampRect
        let p = CGPoint(
            x: min(max(rawPoint.x, bounds.minX), bounds.maxX),
            y: min(max(rawPoint.y, bounds.minY), bounds.maxY)
        )
        // Fixed opposite corner.
        let fixed: CGPoint
        switch corner {
        case .topLeft:     fixed = CGPoint(x: grabStartCrop.maxX, y: grabStartCrop.maxY)
        case .topRight:    fixed = CGPoint(x: grabStartCrop.minX, y: grabStartCrop.maxY)
        case .bottomLeft:  fixed = CGPoint(x: grabStartCrop.maxX, y: grabStartCrop.minY)
        case .bottomRight: fixed = CGPoint(x: grabStartCrop.minX, y: grabStartCrop.minY)
        default: return
        }

        let signX: CGFloat = p.x >= fixed.x ? 1 : -1
        let signY: CGFloat = p.y >= fixed.y ? 1 : -1
        var w = abs(p.x - fixed.x)
        var h = abs(p.y - fixed.y)

        if let ratio = lockedRatio {
            // Width-driven, then clamp so the derived height fits the frame.
            h = w / ratio
            let maxH = signY >= 0 ? (bounds.maxY - fixed.y) : (fixed.y - bounds.minY)
            let maxW = signX >= 0 ? (bounds.maxX - fixed.x) : (fixed.x - bounds.minX)
            if h > maxH { h = maxH; w = h * ratio }
            if w > maxW { w = maxW; h = w / ratio }
            w = max(w, minCropSide)
            h = w / ratio
        } else {
            w = max(w, minCropSide)
            h = max(h, minCropSide)
        }

        let newCorner = CGPoint(x: fixed.x + signX * w, y: fixed.y + signY * h)
        var rect = CGRect(
            x: min(fixed.x, newCorner.x),
            y: min(fixed.y, newCorner.y),
            width: w,
            height: h
        )
        rect = clamp(rect, keepingSizeWithin: bounds)
        cropRect = rect
    }

    // MARK: - Accessibility

    /// How far one VoiceOver step resizes or moves the frame, as a fraction of
    /// the area it may occupy.
    private let accessibilityStep: CGFloat = 0.1

    override var accessibilityValue: String? {
        get {
            let crop = normalizedCropRect()
            return L10n.cropSize(widthPercent: Int((crop.size.width * 100).rounded()),
                                 heightPercent: Int((crop.size.height * 100).rounded()))
        }
        set {}
    }

    /// The crop itself rather than the whole overlay, so VoiceOver outlines what
    /// it adjusts.
    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(cropRect, in: self) }
        set {}
    }

    override func accessibilityIncrement() { resizeForAccessibility(growing: true) }
    override func accessibilityDecrement() { resizeForAccessibility(growing: false) }

    /// Grows or shrinks the crop about its centre by one step. Width and height
    /// scale together, so its shape — and any locked ratio — holds, and it stays
    /// inside the allowed area and above the minimum size.
    func resizeForAccessibility(growing: Bool) {
        let bounds = clampRect
        guard bounds.width > 0, bounds.height > 0, cropRect.width > 0, cropRect.height > 0 else { return }
        let factor = growing ? 1 + accessibilityStep : 1 / (1 + accessibilityStep)
        let scaled = CGSize(width: cropRect.width * factor, height: cropRect.height * factor)
        let fit = min(1, bounds.width / scaled.width, bounds.height / scaled.height)
        let lift = max(1, minCropSide / (scaled.width * fit), minCropSide / (scaled.height * fit))
        let size = CGSize(width: scaled.width * fit * lift, height: scaled.height * fit * lift)
        let center = CGPoint(x: cropRect.midX, y: cropRect.midY)
        cropRect = clamp(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                width: size.width, height: size.height),
                         keepingSizeWithin: bounds)
    }

    /// Moves the crop one step, clamped to the allowed area.
    func moveForAccessibility(dx: CGFloat, dy: CGFloat) {
        let bounds = clampRect
        guard bounds.width > 0, bounds.height > 0 else { return }
        let moved = cropRect.offsetBy(dx: dx * bounds.width * accessibilityStep,
                                      dy: dy * bounds.height * accessibilityStep)
        cropRect = clamp(moved, keepingSizeWithin: bounds)
        // Keep VoiceOver on the frame as it moves, and read out where it is now.
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    private func moveAction(_ name: String, dx: CGFloat, dy: CGFloat) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            // Accessibility actions are delivered on the main thread.
            MainActor.assumeIsolated {
                guard let self else { return false }
                self.moveForAccessibility(dx: dx, dy: dy)
                return true
            }
        }
    }

    // MARK: - Clamping

    private func clampToImageFrame() {
        guard imageFrame.width > 0 else { return }
        cropRect = clamp(cropRect, keepingSizeWithin: clampRect)
    }

    /// Keeps `rect` inside `bounds`, shrinking it if it is larger.
    private func clamp(_ rect: CGRect, keepingSizeWithin bounds: CGRect) -> CGRect {
        var r = rect
        r.size.width = min(r.width, bounds.width)
        r.size.height = min(r.height, bounds.height)
        r.origin.x = min(max(r.origin.x, bounds.minX), bounds.maxX - r.width)
        r.origin.y = min(max(r.origin.y, bounds.minY), bounds.maxY - r.height)
        return r
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), cropRect != .zero else { return }

        // Dim everything outside the crop rect (even-odd fill).
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        let mask = UIBezierPath(rect: bounds)
        mask.append(UIBezierPath(rect: cropRect))
        mask.usesEvenOddFillRule = true
        mask.fill()

        // Rule-of-thirds grid.
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.4).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1...2 {
            let x = cropRect.minX + cropRect.width * CGFloat(i) / 3
            let y = cropRect.minY + cropRect.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: cropRect.minY)); ctx.addLine(to: CGPoint(x: x, y: cropRect.maxY))
            ctx.move(to: CGPoint(x: cropRect.minX, y: y)); ctx.addLine(to: CGPoint(x: cropRect.maxX, y: y))
        }
        ctx.strokePath()

        // Border.
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(cropRect)

        // Corner handles (L-shaped).
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(3)
        let len: CGFloat = 20
        let corners = [
            (CGPoint(x: cropRect.minX, y: cropRect.minY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: cropRect.maxX, y: cropRect.minY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: 1)),
            (CGPoint(x: cropRect.minX, y: cropRect.maxY), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: -1)),
            (CGPoint(x: cropRect.maxX, y: cropRect.maxY), CGVector(dx: -1, dy: 0), CGVector(dx: 0, dy: -1)),
        ]
        for (c, h, v) in corners {
            ctx.move(to: CGPoint(x: c.x + h.dx * len, y: c.y + h.dy * len))
            ctx.addLine(to: c)
            ctx.addLine(to: CGPoint(x: c.x + v.dx * len, y: c.y + v.dy * len))
        }
        ctx.strokePath()
    }
}

#endif
