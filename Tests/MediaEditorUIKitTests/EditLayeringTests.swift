//
//  EditLayeringTests.swift
//  MediaEditorUIKitTests
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
import AVFoundation
import Testing
import MediaEditorCore
@testable import MediaEditorUIKit

/// A short stroke across the middle of a `size` canvas.
@MainActor
private func middleStroke(in size: CGSize, color: UIColor = .red) -> PKDrawing {
    let ink = PKInk(.pen, color: color)
    let points = (0...10).map { i -> PKStrokePoint in
        PKStrokePoint(
            location: CGPoint(x: size.width * (0.2 + 0.06 * CGFloat(i)), y: size.height * 0.5),
            timeOffset: TimeInterval(i) * 0.01,
            size: CGSize(width: 12, height: 12),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
    return PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
}

/// A solid square, for a picture sticker whose pixels are easy to spot.
@MainActor
private func swatch(_ color: UIColor) -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { ctx in
        color.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
    }
}

/// The RGB of `image` at `point`, in top-left-origin pixels.
private func rgb(of image: CGImage, at point: CGPoint) -> (r: UInt8, g: UInt8, b: UInt8) {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let i = (Int(point.y) * width + Int(point.x)) * 4
    return (bytes[i], bytes[i + 1], bytes[i + 2])
}

@MainActor
@Suite("Stacking the drawing among the stickers")
struct EditLayeringTests {

    private let pictureID = UUID()

    private func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300)).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
    }

    private func picture(zIndex: Int) -> Overlay {
        Overlay(content: .image(ImageRef(id: pictureID, data: swatch(.blue).pngData())),
                transform: NormalizedTransform(center: NormalizedPoint(x: 0.5, y: 0.5)), zIndex: zIndex)
    }

    private func caption(zIndex: Int) -> Overlay {
        Overlay(content: .text(TextStyle(string: "Hi")), zIndex: zIndex)
    }

    private func laidOut(_ editor: MediaEditorViewController) -> MediaEditorViewController {
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()
        return editor
    }

    private func container(of editor: MediaEditorViewController) throws -> OverlayContainerView {
        try #require(editor.view.subviews.first { $0 is OverlayContainerView } as? OverlayContainerView)
    }

    private func stackIndex(of content: (OverlayContent) -> Bool, in container: OverlayContainerView) throws -> Int {
        try #require(container.subviews.firstIndex { ($0 as? StickerView).map { content($0.overlay.content) } ?? false })
    }

    private func isPicture(_ content: OverlayContent) -> Bool {
        if case .image = content { return true }
        return false
    }

    private func isText(_ content: OverlayContent) -> Bool {
        if case .text = content { return true }
        return false
    }

    private func isHiddenOnScreen(_ view: UIView) -> Bool {
        sequence(first: view, next: { $0.superview }).contains { $0.isHidden }
    }

    private func visibleButton(titled title: String, in root: UIView) -> UIButton? {
        if let button = root as? UIButton, !isHiddenOnScreen(button) {
            let titles = [button.configuration?.title, button.title(for: .normal), button.accessibilityLabel]
            if titles.contains(title) { return button }
        }
        for subview in root.subviews {
            if let found = visibleButton(titled: title, in: subview) { return found }
        }
        return nil
    }

    /// Runs `button`'s touch-up-inside actions — there's no host app for
    /// `sendActions(for:)` to route through.
    private func tap(_ button: UIButton) {
        for target in button.allTargets {
            for action in button.actions(forTarget: target.base, forControlEvent: .touchUpInside) ?? [] {
                _ = (target.base as? NSObject)?.perform(NSSelectorFromString(action), with: button)
            }
        }
    }

    // MARK: - The model

    @Test("A picture sticker placed before the strokes sits under them, a later one over them")
    func picturesStackByWhenTheyWerePlaced() {
        let recipe = EditRecipe(drawing: DrawingData(data: Data(), canvasWidth: 1, canvasHeight: 1, zIndex: 5),
                                overlays: [picture(zIndex: 7), caption(zIndex: 1), picture(zIndex: 3)])
        let layers = recipe.overlayLayers
        #expect(layers.belowDrawing.map(\.zIndex) == [3])
        #expect(layers.aboveDrawing.map(\.zIndex) == [1, 7], "text is always above, in zIndex order")
        #expect(recipe.nextZIndex == 8)
    }

    @Test("A recipe saved before drawings had a stacking position keeps them under every sticker")
    func legacyDrawingDecodesUnderStickers() throws {
        let json = #"{"data":"AQID","canvasWidth":320,"canvasHeight":480}"#
        let drawing = try JSONDecoder().decode(DrawingData.self, from: Data(json.utf8))
        #expect(drawing.zIndex == .min)
        let recipe = EditRecipe(drawing: drawing, overlays: [picture(zIndex: 0)])
        #expect(recipe.overlayLayers.belowDrawing.isEmpty)
    }

    // MARK: - Export

    @Test("The export stacks a picture sticker under or over the strokes as the recipe says")
    func exportFollowsStacking() throws {
        let renderer = VideoArtworkRenderer()
        let size = CGSize(width: 400, height: 300)
        let images = [pictureID: swatch(.blue)]
        let centre = CGPoint(x: 200, y: 150)

        let over = DrawingData(data: middleStroke(in: size).dataRepresentation(),
                               canvasWidth: 400, canvasHeight: 300, zIndex: 5)
        let strokesOnTop = try #require(renderer.render(drawing: over, overlays: [picture(zIndex: 0)],
                                                        images: images, size: size))
        let top = rgb(of: strokesOnTop, at: centre)
        #expect(top.r > 200 && top.b < 60, "a sticker placed before the strokes is drawn under them")

        let stickerOnTop = try #require(renderer.render(drawing: over, overlays: [picture(zIndex: 9)],
                                                        images: images, size: size))
        let covered = rgb(of: stickerOnTop, at: centre)
        #expect(covered.b > 200 && covered.r < 60, "a sticker placed after them covers them")
    }

    // MARK: - The pencil tool

    @Test("The pencil draws over picture stickers and under text, with every edit in view")
    func canvasSitsBetweenLayers() throws {
        let editor = laidOut(MediaEditorViewController(
            item: .photo(photo()), recipe: EditRecipe(overlays: [picture(zIndex: 0), caption(zIndex: 1)])))
        let stickers = try container(of: editor)
        editor.enterDrawingMode()

        let canvas = try #require(stickers.subviews.firstIndex { $0 is PKCanvasView })
        #expect(try stackIndex(of: isPicture, in: stickers) < canvas)
        #expect(try stackIndex(of: isText, in: stickers) > canvas)
        #expect(!stickers.isHidden)
        #expect(stickers.subviews.compactMap { $0 as? StickerView }.allSatisfy { !$0.isUserInteractionEnabled },
                "a text sticker over the canvas mustn't swallow strokes")
    }

    @Test("New strokes go over the stickers already placed; a sticker added later goes over them")
    func appliedStrokesRestack() throws {
        let editor = laidOut(MediaEditorViewController(
            item: .photo(photo()), recipe: EditRecipe(overlays: [picture(zIndex: 0), caption(zIndex: 1)])))
        editor.enterDrawingMode()
        let canvas = try #require(try container(of: editor).subviews.first { $0 is PKCanvasView } as? PKCanvasView)
        canvas.drawing = middleStroke(in: canvas.bounds.size)
        tap(try #require(visibleButton(titled: L10n.done, in: editor.view)))

        let drawing = try #require(editor.recipe.drawing)
        #expect(drawing.zIndex > 1, "above everything placed so far")
        #expect(editor.recipe.overlayLayers.belowDrawing.count == 1)
        #expect(!editor.drawingLayerView.isHidden && editor.drawingLayerView.image != nil)

        // Reopening and closing without a stroke leaves the stacking alone.
        editor.enterDrawingMode()
        tap(try #require(visibleButton(titled: L10n.done, in: editor.view)))
        #expect(editor.recipe.drawing?.zIndex == drawing.zIndex)

        var next = editor.recipe
        next.overlays.append(picture(zIndex: next.nextZIndex))
        editor.apply(next)
        #expect(editor.recipe.overlayLayers.aboveDrawing.contains { $0.zIndex > drawing.zIndex && isPicture($0.content) })
    }

    // MARK: - The crop tool

    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-3 }

    @Test("Crop shows the edits on the whole media, where they are on it, not on the crop frame")
    func cropKeepsEditsOnTheMedia() throws {
        let crop = CropState(rect: NormalizedRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        let editor = laidOut(MediaEditorViewController(
            item: .photo(photo()), recipe: EditRecipe(crop: crop, overlays: [caption(zIndex: 0)])))
        let stickers = try container(of: editor)
        editor.enterCropMode()
        editor.view.layoutIfNeeded()

        #expect(!stickers.isHidden && stickers.alpha == 1)
        #expect(!stickers.isUserInteractionEnabled, "they're for looking at, not editing")
        #expect(stickers.mask == nil, "the crop overlay's dimming shows what's cut, so nothing is clipped")
        // Centred in the kept quarter, which is the whole frame's bottom-right.
        let shown = try #require(stickers.currentOverlays().first)
        #expect(near(shown.transform.center.x, 0.75) && near(shown.transform.center.y, 0.75))
        let preview = try #require(editor.view.subviews.compactMap { $0 as? UIImageView }.first)
        let displayed = AVMakeRect(aspectRatio: try #require(preview.image).size, insideRect: preview.bounds)
        #expect(stickers.imageFrame == displayed, "laid over the whole frame")

        // Dragging the frame hides them until the finger lifts, and leaves them put.
        let frame = try #require(editor.view.subviews.first { $0 is CropOverlayView } as? CropOverlayView)
        frame.onAdjustmentBegan?()
        #expect(stickers.alpha == 0)
        frame.onAdjustmentEnded?()
        #expect(stickers.alpha == 1)
        #expect(near(try #require(stickers.currentOverlays().first).transform.center.x, 0.75))

        // A quarter turn carries them round with the media.
        tap(try #require(visibleButton(titled: L10n.rotate, in: editor.view)))
        let turned = try #require(stickers.currentOverlays().first)
        #expect(stickers.alpha == 1)
        #expect(near(turned.transform.center.x, 0.25) && near(turned.transform.center.y, 0.75))
        #expect(near(turned.transform.rotation, .pi / 2))

        tap(try #require(visibleButton(titled: L10n.cancel, in: editor.view)))
        #expect(stickers.alpha == 1 && stickers.isUserInteractionEnabled)
        #expect(try #require(stickers.currentOverlays().first) == editor.recipe.overlays.first,
                "cancelling puts back the recipe's own layout")
    }

    @Test("Applying a new crop keeps the edits on the same spot of the media")
    func applyingCropCarriesEdits() throws {
        let editor = laidOut(MediaEditorViewController(
            item: .photo(photo()), recipe: EditRecipe(overlays: [caption(zIndex: 0)])))
        editor.enterCropMode()
        tap(try #require(visibleButton(titled: L10n.rotate, in: editor.view)))
        tap(try #require(visibleButton(titled: L10n.apply, in: editor.view)))

        #expect(editor.recipe.rotation.degrees == 90)
        let carried = try #require(editor.recipe.overlays.first)
        #expect(near(carried.transform.rotation, .pi / 2), "turned with the photo")

        editor.perform(.undo)
        #expect(editor.recipe.overlays.first?.transform == caption(zIndex: 0).transform,
                "undo restores the layout along with the geometry")
    }

    @Test("Outside crop mode, whatever the crop cut away is clipped from view")
    func clippedToTheMedia() throws {
        let editor = laidOut(MediaEditorViewController(item: .photo(photo())))
        let stickers = try container(of: editor)
        #expect(stickers.mask != nil)
        #expect(stickers.mask?.frame == stickers.imageFrame)
    }

    // MARK: - Undo / redo

    @Test("Undo and redo appear with the first edit, and step aside while a tool is open")
    func historyAppearsAfterFirstEdit() throws {
        let editor = laidOut(MediaEditorViewController(item: .photo(photo())))
        let undo = try #require(findButton(L10n.undo, in: editor.view))
        #expect(isHiddenOnScreen(undo), "nothing to undo yet")

        editor.perform(.rotate)
        #expect(!isHiddenOnScreen(undo))

        editor.enterCropMode()
        #expect(isHiddenOnScreen(undo), "the crop tool has its own Cancel")
        tap(try #require(visibleButton(titled: L10n.cancel, in: editor.view)))
        #expect(!isHiddenOnScreen(undo))

        editor.perform(.undo)
        #expect(!isHiddenOnScreen(undo), "redo is still on offer")
    }

    private func findButton(_ label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        for subview in view.subviews {
            if let found = findButton(label, in: subview) { return found }
        }
        return nil
    }
}

#endif
