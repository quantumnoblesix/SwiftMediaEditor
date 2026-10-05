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
/// asks via `preferredTrashCenter` or `trashCenterProvider`, else at the bottom
/// of the media — and
/// releasing the sticker on the bin removes it.
@MainActor
final class OverlayContainerView: UIView {

    weak var delegate: OverlayContainerDelegate?

    /// The rect (in this view's coordinates) where the image is displayed.
    var imageFrame: CGRect = .zero {
        didSet {
            guard imageFrame != oldValue else { return }
            // The layer's bounds start where its frame does, so everything in it
            // keeps using this view's coordinates.
            canvasLayer.frame = imageFrame
            canvasLayer.bounds.origin = imageFrame.origin
            stickers.forEach { $0.applyLayout(canvasFrame: imageFrame) }
            drawingView.frame = imageFrame
            drawingCanvas?.frame = imageFrame
        }
    }

    /// Holds the stickers and the drawing over `imageFrame`, and clips them to
    /// it: a sticker the crop has cut away stays in the recipe — widen the crop
    /// and it's back — but shouldn't float over the letterboxing. A plain
    /// rectangular clip rather than a mask, which would cost an offscreen pass
    /// every frame over a playing video.
    ///
    /// Touches outside `imageFrame` never reach a sticker, but still land on
    /// this view, so taps and pinches in the letterboxing keep working.
    private let canvasLayer = UIView()

    /// Whether to clip to `imageFrame`. Relaxed while a sticker is dragged, so
    /// it stays in view on its way to the delete bin.
    var clipsToCanvas = true {
        didSet { updateCanvasClip() }
    }

    /// Called for a horizontal swipe that starts on empty canvas — a session
    /// pages between its items with it. Setting it adds the recognizers.
    var onSwipe: ((UISwipeGestureRecognizer.Direction) -> Void)? {
        didSet {
            guard onSwipe != nil, swipeRecognizers.isEmpty else { return }
            for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
                let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
                swipe.direction = direction
                swipe.delegate = self
                addGestureRecognizer(swipe)
                swipeRecognizers.append(swipe)
            }
        }
    }
    private var swipeRecognizers: [UISwipeGestureRecognizer] = []

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        onSwipe?(gesture.direction)
    }

    /// Whether the stickers are clipped to the media right now.
    var isClippingToCanvas: Bool { canvasLayer.clipsToBounds }

    /// The stickers and the drawing, bottom to top — for tests.
    var layeredViews: [UIView] { canvasLayer.subviews }

    private func updateCanvasClip() {
        canvasLayer.clipsToBounds = clipsToCanvas && draggedSticker == nil
    }

    private var stickers: [StickerView] = []
    private(set) weak var selected: StickerView?

    /// The recipe's strokes, stretched over `imageFrame` and stacked at
    /// `drawingZIndex` among the stickers (see `Overlay.sitsAboveDrawing(at:)`).
    let drawingView: UIImageView = {
        let view = UIImageView()
        view.contentMode = .scaleToFill
        view.isUserInteractionEnabled = false
        return view
    }()
    /// The live canvas while the pencil tool is open. It takes the drawing's
    /// place in the stack, so strokes go down over the picture stickers and
    /// under the text.
    private(set) weak var drawingCanvas: UIView?
    /// Where the drawing stacks among the stickers — the recipe's
    /// `DrawingData.zIndex`.
    var drawingZIndex: Int = .min {
        didSet { if drawingZIndex != oldValue { arrangeLayers() } }
    }

    /// Styles the delete bin. Set by the editor before the first drag.
    var appearance: EditorAppearance?
    /// Where the host wants the bin, in this view's coordinates — the editor puts
    /// it just above its bottom controls. It may lie outside `bounds`: stickers
    /// aren't clamped to the canvas, and the editor doesn't clip this view.
    /// `nil` falls back to the bottom-centre of the displayed media.
    var preferredTrashCenter: CGPoint?
    /// Asked for the bin's place whenever it's needed, for a host whose chrome
    /// moves after layout — a bar the keyboard lifts, or one whose height only
    /// settles later. Consulted when `preferredTrashCenter` is `nil`; returning
    /// `nil` falls back to the bottom-centre of the media.
    var trashCenterProvider: (() -> CGPoint?)?
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
        canvasLayer.clipsToBounds = true
        addSubview(canvasLayer)
        canvasLayer.addSubview(drawingView)
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
        return hit === canvasLayer ? self : hit
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
            canvasLayer.addSubview(sticker)
            sticker.applyLayout(canvasFrame: imageFrame)
            return sticker
        }
        if let id = previouslySelected {
            select(stickers.first { $0.overlay.id == id })
        }
        arrangeLayers()
    }

    /// Restacks the subviews: the stickers under the drawing, the drawing (or
    /// the live canvas), the stickers over it, then the delete bin. Within each
    /// side the selected sticker comes last, so the one being moved stays on top
    /// of its neighbours without crossing the strokes.
    ///
    /// While the pencil is open the canvas goes over every picture sticker —
    /// the new strokes will, once applied.
    private func arrangeLayers() {
        func ordered(_ group: [StickerView]) -> [StickerView] {
            group.filter { $0 !== selected } + group.filter { $0 === selected }
        }
        let z = drawingCanvas == nil ? drawingZIndex : .max
        let below = stickers.filter { !$0.overlay.sitsAboveDrawing(at: z) }
        let above = stickers.filter { $0.overlay.sitsAboveDrawing(at: z) }
        let drawingLayer: UIView = drawingCanvas ?? drawingView
        for view in ordered(below) + [drawingLayer] + ordered(above) {
            canvasLayer.bringSubviewToFront(view)
        }
        if let trashView { bringSubviewToFront(trashView) }
    }

    // MARK: - Drawing

    /// Seats `canvas` over the picture stickers and under the text for the
    /// pencil tool. Stickers stay
    /// visible but stop taking touches — the text ones sit above the canvas and
    /// would otherwise swallow strokes that start on them.
    func beginDrawing(with canvas: UIView) {
        deselect()
        drawingCanvas = canvas
        canvas.frame = imageFrame
        canvasLayer.addSubview(canvas)
        drawingView.isHidden = true            // the canvas shows the strokes itself
        stickers.forEach { $0.isUserInteractionEnabled = false }
        gestureRecognizers?.forEach { $0.isEnabled = false }
        arrangeLayers()
    }

    /// Takes the canvas out and hands the stickers their touches back.
    func endDrawing() {
        drawingCanvas?.removeFromSuperview()
        drawingCanvas = nil
        drawingView.isHidden = false
        stickers.forEach { $0.isUserInteractionEnabled = true }
        gestureRecognizers?.forEach { $0.isEnabled = true }
        arrangeLayers()
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
        arrangeLayers()
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
        if let provided = trashCenterProvider?() { return provided }
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
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseIn],
                       animations: {
                           sticker.center = target
                           sticker.transform = sticker.transform.scaledBy(x: 0.05, y: 0.05)
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

    // A swipe pages between items only from empty canvas: one that starts on a
    // sticker is that sticker's drag.
    nonisolated func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                       shouldReceive touch: UITouch) -> Bool {
        MainActor.assumeIsolated {
            guard gestureRecognizer is UISwipeGestureRecognizer else { return true }
            return touch.view === self || touch.view === canvasLayer
        }
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
    }

    func stickerViewDidRequestTextEdit(_ sticker: StickerView) {
        delegate?.overlayContainer(self, requestsTextEditFor: sticker.overlay.id)
    }

    func stickerView(_ sticker: StickerView, didDragTo location: CGPoint) {
        let bin = trash()
        if draggedSticker !== sticker {
            draggedSticker = sticker
            updateCanvasClip()
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
        // Clip again once the bin — and a sticker dropped into it — have gone:
        // both animate outside the canvas.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.updateCanvasClip()
        }
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
