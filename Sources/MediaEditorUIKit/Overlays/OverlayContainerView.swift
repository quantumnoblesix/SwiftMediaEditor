//
//  OverlayContainerView.swift
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
protocol OverlayContainerDelegate: AnyObject {
    /// The overlays changed and should be committed to undo history.
    func overlayContainerDidCommit(_ container: OverlayContainerView)
    /// A text sticker requested re-editing.
    func overlayContainer(_ container: OverlayContainerView, requestsTextEditFor id: UUID)
    /// A tap landed on the canvas rather than on a sticker. `hadSelection` is
    /// true when the tap's job was clearing a selection, which lets the host
    /// tell "dismiss the selection" apart from a plain tap on the media.
    func overlayContainer(_ container: OverlayContainerView, didTapCanvasWithSelection hadSelection: Bool)
    /// A sticker started (`true`) or stopped (`false`) being moved. The delete
    /// bin is on screen in between, so the host can clear chrome out of its way.
    func overlayContainer(_ container: OverlayContainerView, isDraggingSticker dragging: Bool)
}

/// Hosts the interactive sticker views over the displayed image. Positions each
/// sticker against `imageFrame` (the canvas), routes selection, and reports
/// committed changes back for undo history.
///
/// While a sticker is being moved it also shows a delete bin — wherever the host
/// asks via `preferredTrashCenter`, else at the bottom of the media — and
/// releasing the sticker on the bin removes it.
@MainActor
final class OverlayContainerView: UIView {

    weak var delegate: OverlayContainerDelegate?

    /// The rect (in this view's coordinates) where the image is displayed.
    var imageFrame: CGRect = .zero {
        didSet { stickers.forEach { $0.applyLayout(canvasFrame: imageFrame) } }
    }

    private var stickers: [StickerView] = []
    private(set) weak var selected: StickerView?

    /// Styles the delete bin. Set by the editor before the first drag.
    var appearance: EditorAppearance?
    /// Where the host wants the bin, in this view's coordinates — the editor puts
    /// it just above its bottom controls. It may lie outside `bounds`: stickers
    /// aren't clamped to the canvas, and the editor doesn't clip this view.
    /// `nil` falls back to the bottom-centre of the displayed media.
    var preferredTrashCenter: CGPoint?
    /// The drop target shown while a sticker is moving; built on first use.
    private var trashView: StickerTrashView?
    /// The sticker currently being moved, if any.
    private weak var draggedSticker: StickerView?
    /// Whether the finger is over the bin, so releasing would delete.
    private(set) var isTrashArmed = false
    private let armFeedback = UIImpactFeedbackGenerator(style: .medium)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        // Pinch / rotate anywhere transform the selected sticker, so scaling a
        // small sticker doesn't require landing both fingers on it.
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        for gesture in [pinch, rotate] as [UIGestureRecognizer] {
            gesture.delegate = self
            addGestureRecognizer(gesture)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // Only intercept touches that land on a sticker; let the rest pass through
    // (except the background tap above, which deselects).
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? self : hit
    }

    // MARK: - Building

    /// Rebuilds all sticker views from the overlays. Used on structural changes
    /// (add / remove). `images` supplies content for image overlays by ref id.
    func reload(overlays: [Overlay], images: [UUID: UIImage]) {
        let previouslySelected = selected?.overlay.id
        stickers.forEach { $0.removeFromSuperview() }
        stickers = overlays.sorted { $0.zIndex < $1.zIndex }.map { overlay in
            let image: UIImage? = {
                if case let .image(ref) = overlay.content { return images[ref.id] }
                return nil
            }()
            let sticker = StickerView(overlay: overlay, image: image)
            sticker.delegate = self
            addSubview(sticker)
            sticker.applyLayout(canvasFrame: imageFrame)
            return sticker
        }
        if let id = previouslySelected {
            select(stickers.first { $0.overlay.id == id })
        }
    }

    /// The current overlays, reflecting any live gesture edits.
    func currentOverlays() -> [Overlay] {
        stickers.map { $0.overlay }
    }

    func select(_ sticker: StickerView?) {
        guard selected !== sticker else { return }
        selected?.isSelected = false
        selected = sticker
        sticker?.isSelected = true
        if let sticker { bringSubviewToFront(sticker) }
    }

    func deselect() { select(nil) }

    /// Selects the top-most sticker, if any (used for demos / UI tests).
    func selectFirst() { select(stickers.last) }

    @objc private func backgroundTapped() {
        let hadSelection = selected != nil
        deselect()
        delegate?.overlayContainer(self, didTapCanvasWithSelection: hadSelection)
    }

    // MARK: - Delete bin

    /// Where the bin sits: the host's `preferredTrashCenter`, or failing that the
    /// bottom-centre of the displayed media, which is always on the canvas being
    /// dragged over.
    var trashCenter: CGPoint {
        if let preferredTrashCenter { return preferredTrashCenter }
        let area = imageFrame.isEmpty ? bounds : imageFrame
        let radius = StickerTrashView.diameter / 2
        return CGPoint(x: area.midX, y: max(area.minY + radius, area.maxY - radius - 16))
    }

    /// Whether the bin is on screen.
    var isTrashVisible: Bool { trashView?.isShown ?? false }

    /// Builds the bin on first use, with whatever appearance the host set.
    private func trash() -> StickerTrashView {
        if let trashView { return trashView }
        let bin = StickerTrashView(appearance: appearance ?? EditorAppearance())
        addSubview(bin)
        trashView = bin
        return bin
    }

    /// Whether `location` counts as over the bin. Arming needs the finger closer
    /// than disarming does, so the state doesn't flicker on the edge.
    private func isOverTrash(_ location: CGPoint) -> Bool {
        let reach = StickerTrashView.diameter * (isTrashArmed ? 0.95 : 0.8)
        return hypot(location.x - trashCenter.x, location.y - trashCenter.y) <= reach
    }

    /// Removes `sticker` as a single history step and animates it into the bin.
    private func discard(_ sticker: StickerView) {
        if selected === sticker { selected = nil }
        sticker.isSelected = false
        stickers.removeAll { $0 === sticker }
        // The model changes now, so the recipe is right even if the host reloads
        // before the animation ends; the view only finishes its exit.
        delegate?.overlayContainerDidCommit(self)

        // `applyLayout` no longer runs for a removed sticker, so scaling its
        // transform here is safe. It shrinks *behind* the bin, reading as a drop in.
        let target = trashCenter
        // Reduce Motion keeps the drop to a fade where the sticker was let go.
        let reduceMotion = EditorAccessibility.prefersReducedMotion
        UIView.animate(withDuration: reduceMotion ? 0.2 : 0.25, delay: 0, options: [.curveEaseIn],
                       animations: {
                           if !reduceMotion {
                               sticker.center = target
                               sticker.transform = sticker.transform.scaledBy(x: 0.05, y: 0.05)
                           }
                           sticker.alpha = 0
                       },
                       completion: { _ in sticker.removeFromSuperview() })
    }

    // MARK: - Container-wide transform gestures

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let selected else { return }
        switch gesture.state {
        case .changed:
            selected.scale(by: Double(gesture.scale))
            gesture.scale = 1
        case .ended, .cancelled, .failed:
            selected.commitTransform()
        default:
            break
        }
    }

    @objc private func handleRotate(_ gesture: UIRotationGestureRecognizer) {
        guard let selected else { return }
        switch gesture.state {
        case .changed:
            selected.rotate(by: Double(gesture.rotation))
            gesture.rotation = 0
        case .ended, .cancelled, .failed:
            selected.commitTransform()
        default:
            break
        }
    }
}

extension OverlayContainerView: UIGestureRecognizerDelegate {
    // Pinch + rotate (and the selected sticker's pan) run together.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

extension OverlayContainerView: StickerViewDelegate {
    func stickerViewDidCommit(_ sticker: StickerView) {
        delegate?.overlayContainerDidCommit(self)
    }

    func stickerViewDidSelect(_ sticker: StickerView) {
        select(sticker)
    }

    func stickerViewDidRequestDelete(_ sticker: StickerView) {
        if selected === sticker { selected = nil }
        sticker.removeFromSuperview()
        stickers.removeAll { $0 === sticker }
        delegate?.overlayContainerDidCommit(self)
        // VoiceOver was on the sticker that just went: say so, and let it settle
        // on something else.
        UIAccessibility.post(notification: .layoutChanged, argument: L10n.deleted)
    }

    func stickerViewDidRequestTextEdit(_ sticker: StickerView) {
        delegate?.overlayContainer(self, requestsTextEditFor: sticker.overlay.id)
    }

    func stickerView(_ sticker: StickerView, didDragTo location: CGPoint) {
        let bin = trash()
        if draggedSticker !== sticker {
            draggedSticker = sticker
            bin.center = trashCenter
            // Above the stickers, including the one being dragged, so the bin
            // stays visible under a large sticker.
            bringSubviewToFront(bin)
            bin.setVisible(true, animated: true)
            armFeedback.prepare()
            delegate?.overlayContainer(self, isDraggingSticker: true)
        }

        let armed = isOverTrash(location)
        guard armed != isTrashArmed else { return }
        isTrashArmed = armed
        bin.setArmed(armed, animated: true)
        // `applyLayout` rewrites the sticker's transform every frame of a move,
        // so hover feedback has to be alpha rather than scale.
        UIView.animate(withDuration: 0.18) { sticker.alpha = armed ? 0.45 : 1 }
        if armed { armFeedback.impactOccurred() }
    }

    func stickerView(_ sticker: StickerView, didEndDragAt location: CGPoint, cancelled: Bool) -> Bool {
        let wasDragging = draggedSticker === sticker
        // An interrupted gesture (a call, a system alert) must never delete.
        let dropped = !cancelled && isOverTrash(location)
        draggedSticker = nil
        isTrashArmed = false
        if wasDragging { delegate?.overlayContainer(self, isDraggingSticker: false) }

        guard dropped else {
            trashView?.setVisible(false, animated: true)
            UIView.animate(withDuration: 0.18) { sticker.alpha = 1 }
            return false
        }
        discard(sticker)
        // Let the sticker land before the bin leaves.
        trashView?.setVisible(false, animated: true, delay: 0.18)
        return true
    }
}

#endif
