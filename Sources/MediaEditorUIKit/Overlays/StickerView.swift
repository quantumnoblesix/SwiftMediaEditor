//
//  StickerView.swift
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

@MainActor
protocol StickerViewDelegate: AnyObject {
    /// A gesture finished — commit the change to undo history.
    func stickerViewDidCommit(_ sticker: StickerView)
    /// The sticker was tapped and should become the selection.
    func stickerViewDidSelect(_ sticker: StickerView)
    /// The sticker asked to be removed — through its VoiceOver Delete action,
    /// since sighted users drag it onto the bin instead.
    func stickerViewDidRequestDelete(_ sticker: StickerView)
    /// A text sticker was double-tapped to re-edit its string.
    func stickerViewDidRequestTextEdit(_ sticker: StickerView)
    /// A move drag is in progress; `location` is the finger, in the superview's
    /// coordinates. Not sent for resize drags, which don't relocate the sticker.
    func stickerView(_ sticker: StickerView, didDragTo location: CGPoint)
    /// A move drag ended at `location`. Return `true` if the drop was consumed —
    /// the sticker was released on the bin and deleted — so the move isn't also
    /// committed to history. A `cancelled` drag must never count as a drop.
    func stickerView(_ sticker: StickerView, didEndDragAt location: CGPoint, cancelled: Bool) -> Bool
}

/// The interactive on-screen representation of a single `Overlay`. Owns its
/// overlay model; gestures mutate the normalized transform and reposition the
/// view. The image content (for image overlays) is supplied at init.
@MainActor
final class StickerView: UIView {

    /// Fraction of canvas width used as an image overlay's base (scale = 1) width.
    static let imageBaseWidthFraction: CGFloat = 0.4

    weak var delegate: StickerViewDelegate?

    /// The model this view represents. Kept in sync by gestures.
    private(set) var overlay: Overlay
    /// Image for `.image` overlays.
    private let image: UIImage?
    /// The rect (in the superview's coordinates) where the canvas is displayed.
    private var canvasFrame: CGRect = .zero

    var isSelected: Bool = false {
        didSet { updateChrome() }
    }

    private let contentView: UIView
    private let borderLayer = CAShapeLayer()
    /// Bottom-right handle: drag to scale + rotate (visual only; the body pan
    /// gesture handles the drag so it doesn't fight the move gesture).
    private let resizeHandle = UIImageView()

    private enum Grab { case move, resize }
    private var activeGrab: Grab = .move
    private var resizeStartScale = 1.0
    private var resizeStartRotation = 0.0
    private var resizeStartAngle = 0.0
    private var resizeStartDistance = 1.0

    // MARK: - Init

    init(overlay: Overlay, image: UIImage?) {
        self.overlay = overlay
        self.image = image
        switch overlay.content {
        case .text:
            let label = UILabel()
            label.numberOfLines = 0
            self.contentView = label
        case .image:
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFit
            self.contentView = view
        }
        super.init(frame: .zero)

        addSubview(contentView)

        borderLayer.fillColor = UIColor.clear.cgColor
        borderLayer.strokeColor = UIColor.white.cgColor
        borderLayer.lineDashPattern = [6, 4]
        borderLayer.isHidden = true
        layer.addSublayer(borderLayer)

        let handleConfig = UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
        resizeHandle.image = UIImage(systemName: "arrow.up.left.and.arrow.down.right.circle.fill",
                                     withConfiguration: handleConfig)
        resizeHandle.tintColor = .white
        resizeHandle.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        resizeHandle.layer.cornerRadius = 14
        resizeHandle.clipsToBounds = true
        resizeHandle.isHidden = true
        resizeHandle.isUserInteractionEnabled = false   // the body pan handles it
        addSubview(resizeHandle)

        setupAccessibility()
        setupGestures()
    }

    /// Deletion is a drag onto the bin, which VoiceOver can't perform — and the
    /// sticker has no on-screen delete control to fall back on. So the sticker is
    /// one accessibility element, announced by its content, offering Delete as a
    /// custom action (swipe up or down to reach it).
    private func setupAccessibility() {
        isAccessibilityElement = true
        switch overlay.content {
        case let .text(style): accessibilityLabel = style.string
        case .image:           accessibilityLabel = L10n.addPhoto
        }
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: L10n.delete) { [weak self] _ in
                // Accessibility actions are delivered on the main thread.
                MainActor.assumeIsolated {
                    guard let self else { return false }
                    self.delegate?.stickerViewDidRequestDelete(self)
                    return true
                }
            },
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Layout against a canvas

    /// Recomputes the view's frame, transform, and content for the current
    /// canvas frame. Call on layout changes and after geometry edits.
    func applyLayout(canvasFrame: CGRect) {
        self.canvasFrame = canvasFrame
        let base = baseSize(in: canvasFrame)

        // Configure content at base (scale = 1) size; the transform scales it.
        bounds = CGRect(origin: .zero, size: base)
        contentView.frame = bounds
        if let label = contentView as? UILabel, case let .text(style) = overlay.content {
            label.attributedText = NSAttributedString(string: style.string,
                                                       attributes: style.attributes(canvasHeight: canvasFrame.height))
            label.textAlignment = style.alignment.nsTextAlignment
        }

        let scale = max(0.05, CGFloat(overlay.transform.scale))
        transform = CGAffineTransform(scaleX: scale, y: scale)
            .rotated(by: CGFloat(overlay.transform.rotation))
        center = CGPoint(
            x: canvasFrame.minX + CGFloat(overlay.transform.center.x) * canvasFrame.width,
            y: canvasFrame.minY + CGFloat(overlay.transform.center.y) * canvasFrame.height
        )
        updateChrome()
    }

    private func baseSize(in canvasFrame: CGRect) -> CGSize {
        switch overlay.content {
        case let .text(style):
            return style.intrinsicSize(canvasHeight: canvasFrame.height)
        case .image:
            let aspect = (image?.size.width ?? 1) / max(1, image?.size.height ?? 1)
            let width = Self.imageBaseWidthFraction * canvasFrame.width
            return CGSize(width: width, height: width / max(0.01, aspect))
        }
    }

    // MARK: - Chrome

    private func updateChrome() {
        borderLayer.isHidden = !isSelected
        resizeHandle.isHidden = !isSelected
        guard isSelected else { return }

        borderLayer.frame = bounds
        borderLayer.path = UIBezierPath(rect: bounds).cgPath
        // Counter-scale so line width and the controls stay visually constant.
        let scale = max(0.05, CGFloat(overlay.transform.scale))
        borderLayer.lineWidth = 1.5 / scale
        let controlSize: CGFloat = 28 / scale

        resizeHandle.bounds = CGRect(x: 0, y: 0, width: controlSize, height: controlSize)
        resizeHandle.layer.cornerRadius = controlSize / 2
        resizeHandle.center = CGPoint(x: bounds.maxX, y: bounds.maxY)  // bottom-right
    }

    // MARK: - Gestures

    private func setupGestures() {
        // Single-finger pan drags the sticker itself. Pinch/rotate are driven by
        // the container so they work anywhere, not only when both fingers land on
        // a (possibly small) sticker.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        for gesture in [pan, tap, doubleTap] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            delegate?.stickerViewDidSelect(self)
            // Grabbing the bottom-right handle (only when already selected)
            // resizes + rotates; anywhere else moves.
            activeGrab = (isSelected && isResizeGrab(gesture.location(in: self))) ? .resize : .move
            if activeGrab == .resize { beginResize(gesture) }
        case .changed:
            if activeGrab == .resize {
                updateResize(gesture)
            } else {
                moveBy(gesture)
            }
        default:
            break
        }
        emit(state: gesture.state, location: superview.map { gesture.location(in: $0) })
    }

    private func isResizeGrab(_ location: CGPoint) -> Bool {
        let corner = CGPoint(x: bounds.maxX, y: bounds.maxY)
        let scale = max(0.05, CGFloat(overlay.transform.scale))
        return hypot(location.x - corner.x, location.y - corner.y) <= 34 / scale
    }

    private func moveBy(_ gesture: UIPanGestureRecognizer) {
        guard canvasFrame.width > 0, let superview else { return }
        let translation = gesture.translation(in: superview)
        gesture.setTranslation(.zero, in: superview)
        overlay.transform.center.x += Double(translation.x / canvasFrame.width)
        overlay.transform.center.y += Double(translation.y / canvasFrame.height)
        applyLayout(canvasFrame: canvasFrame)
    }

    private func beginResize(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let v = vectorFromCenter(gesture.location(in: superview))
        resizeStartScale = overlay.transform.scale
        resizeStartRotation = overlay.transform.rotation
        resizeStartAngle = atan2(v.dy, v.dx)
        resizeStartDistance = max(1, hypot(v.dx, v.dy))
    }

    private func updateResize(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let v = vectorFromCenter(gesture.location(in: superview))
        let distance = hypot(v.dx, v.dy)
        let angle = atan2(v.dy, v.dx)
        overlay.transform.scale = resizeStartScale * Double(distance / resizeStartDistance)
        overlay.transform.rotation = resizeStartRotation + Double(angle - resizeStartAngle)
        applyLayout(canvasFrame: canvasFrame)
    }

    private func vectorFromCenter(_ point: CGPoint) -> CGVector {
        CGVector(dx: point.x - center.x, dy: point.y - center.y)
    }

    // MARK: - Container-driven transforms

    /// Multiplies the sticker's scale (pinch-to-zoom).
    func scale(by factor: Double) {
        overlay.transform.scale *= factor
        applyLayout(canvasFrame: canvasFrame)
    }

    /// Adds to the sticker's rotation (two-finger rotate).
    func rotate(by radians: Double) {
        overlay.transform.rotation += radians
        applyLayout(canvasFrame: canvasFrame)
    }

    /// Commits a container-driven transform to undo history.
    func commitTransform() {
        delegate?.stickerViewDidCommit(self)
    }

    @objc private func handleTap() {
        delegate?.stickerViewDidSelect(self)
    }

    @objc private func handleDoubleTap() {
        if case .text = overlay.content {
            delegate?.stickerViewDidRequestTextEdit(self)
        }
    }

    /// Reports a pan phase to the delegate. Internal so tests can drive the drag
    /// lifecycle without synthesizing touches.
    func emit(state: UIGestureRecognizer.State, location: CGPoint? = nil) {
        delegate?.stickerViewDidSelect(self)
        switch state {
        case .began, .changed:
            if activeGrab == .move, let location {
                delegate?.stickerView(self, didDragTo: location)
            }
        case .ended, .cancelled, .failed:
            if activeGrab == .move, let location,
               delegate?.stickerView(self, didEndDragAt: location, cancelled: state != .ended) == true {
                // Dropped on the bin: the deletion is the history step, so don't
                // also record the move that carried it there.
                return
            }
            delegate?.stickerViewDidCommit(self)
        default:
            break
        }
    }
}

extension StickerView: UIGestureRecognizerDelegate {
    // Allow pan + pinch + rotate to work together.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

#endif
