//
//  SessionTests.swift
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
import UIKit.UIGestureRecognizerSubclass
import AVFoundation
import Testing
import SwiftUI
import MediaEditorCore
@testable import MediaEditorUIKit

/// A solid photo of the given colour and size.
@MainActor
private func photo(_ color: UIColor = .blue, size: CGSize = CGSize(width: 400, height: 300)) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
        color.setFill()
        ctx.fill(CGRect(origin: .zero, size: size))
    }
}

/// Writes `image` as a PNG file and returns its URL.
@MainActor
private func photoFile(_ image: UIImage) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaEditor-\(UUID().uuidString).png")
    try #require(image.pngData()).write(to: url)
    return url
}

/// A pinch whose state, centroid and touches a test sets.
private final class ScriptedPinch: UIPinchGestureRecognizer {
    var scriptedState: UIGestureRecognizer.State = .began
    override var state: UIGestureRecognizer.State {
        get { scriptedState }
        set { scriptedState = newValue }
    }
    override func location(in view: UIView?) -> CGPoint { CGPoint(x: 200, y: 400) }
    override var numberOfTouches: Int { 2 }
}

@MainActor
@Suite("Multi-item sessions")
struct SessionTests {

    /// Windows keeping laid-out editors on screen for the test's duration.
    private static var windows: [UIWindow] = []

    private func laidOut(_ editor: MediaEditorViewController) -> MediaEditorViewController {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = editor
        window.isHidden = false
        Self.windows.append(window)
        editor.view.layoutIfNeeded()
        return editor
    }

    private func session(_ items: [MediaEditorItem], configuration: EditorConfiguration = .default,
                         appearance: EditorAppearance = .messaging,
                         accessory: UIView? = nil) -> MediaEditorViewController {
        laidOut(MediaEditorViewController(items: items, configuration: configuration,
                                          appearance: appearance, bottomAccessory: accessory))
    }

    private func rotated(_ recipe: EditRecipe = .identity) -> EditRecipe {
        var next = recipe
        next.rotation.rotateClockwise90()
        return next
    }

    /// Calls `finish()` and waits for the session's result.
    private func finishing(_ editor: MediaEditorViewController) async -> MediaEditorSessionResult {
        await withCheckedContinuation { continuation in
            editor.onSessionFinish = { continuation.resume(returning: $0) }
            editor.finish()
        }
    }

    // MARK: - The single-item editor is unchanged

    @Test("A single-item editor never shows a strip and still reports an EditorResult")
    func singleItemUnchanged() throws {
        var result: EditorResult?
        let editor = laidOut(MediaEditorViewController(item: .photo(photo()), onFinish: { result = $0 }))
        #expect(editor.strip == nil)
        #expect(!editor.view.subviews.contains { $0 is ThumbnailStripView })
        editor.finish()
        guard case let .saved(output, recipe) = try #require(result), case .photo = output else {
            Issue.record("expected a saved photo")
            return
        }
        #expect(recipe == .identity)
    }

    // MARK: - Switching

    @Test("Switching away and back restores an item's recipe, stickers and undo history")
    func switchingRestoresEachItem() throws {
        let a = MediaEditorItem(source: .photo(photo(.red)))
        let b = MediaEditorItem(source: .photo(photo(.green)))
        let editor = session([a, b])

        var edited = rotated()
        edited.overlays = [Overlay(content: .text(TextStyle(string: "A")))]
        editor.apply(edited)
        #expect(editor.canUndo)

        editor.select(b.id)
        #expect(editor.selectedItemID == b.id)
        #expect(editor.recipe == .identity)
        #expect(!editor.canUndo, "B has a history of its own")

        editor.select(a.id)
        #expect(editor.recipe == edited)
        #expect(editor.canUndo, "A's history survived the switch")
        editor.undo()
        #expect(editor.recipe == .identity)
        #expect(editor.items[0].recipe == .identity, "items follow undo too")
    }

    @Test("items and onRecipeChange carry committed recipes only — never an open tool's")
    func onlyCommittedRecipesAreReported() throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let b = MediaEditorItem(source: .photo(photo()))
        let editor = session([a, b])
        var reported: [EditRecipe] = []
        editor.onRecipeChange = { _, recipe in reported.append(recipe) }

        editor.enterCropMode()
        #expect(editor.isToolActive)
        #expect(editor.items[0].recipe == .identity)
        #expect(reported.isEmpty, "an open crop isn't a change")

        editor.select(b.id)                            // cancels the crop
        #expect(reported.isEmpty, "loading an item isn't a change either")

        editor.apply(rotated())
        #expect(reported == [rotated()])
        editor.undo()
        editor.redo()
        #expect(reported.count == 3, "undo and redo are changes")
    }

    // MARK: - Removing and adding

    @Test("Removing the selected item selects its neighbour; removing the last cancels")
    func removal() throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let b = MediaEditorItem(source: .photo(photo()))
        let editor = session([a, b])
        var reportedItems: [[UUID]] = []
        var result: MediaEditorSessionResult?
        editor.onItemsChange = { reportedItems.append($0.map(\.id)) }
        editor.onSessionFinish = { result = $0 }

        editor.remove(a.id)
        #expect(editor.selectedItemID == b.id)
        #expect(editor.items.map(\.id) == [b.id])
        #expect(reportedItems == [[b.id]], "the host's array follows the removal")

        editor.remove(b.id)
        guard case .cancelled = try #require(result) else {
            Issue.record("removing every item should cancel")
            return
        }
    }

    @Test("The strip removes an item only on a second tap of the selected thumbnail")
    func removalNeedsTwoTaps() throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let b = MediaEditorItem(source: .photo(photo()))
        let editor = session([a, b])
        let strip = try #require(editor.strip)

        strip.tap(b.id)
        #expect(editor.selectedItemID == b.id, "tapping another thumbnail selects it")
        strip.tap(b.id)
        #expect(strip.armedID == b.id, "the first tap on the selected one only arms it")
        #expect(editor.items.count == 2)
        strip.tap(b.id)
        #expect(editor.items.map(\.id) == [a.id])
    }

    @Test("insert selects the first new item; the + cell appears only with onAddItems")
    func insertion() throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let editor = session([a])
        let strip = try #require(editor.strip)
        #expect(!strip.showsAddCell)
        #expect(strip.isHidden, "one item and no + cell: nothing to show")

        editor.onAddItems = {}
        #expect(strip.showsAddCell)
        #expect(!strip.isHidden, "the + cell has to be reachable")

        let b = MediaEditorItem(source: .photo(photo()))
        let c = MediaEditorItem(source: .photo(photo()))
        editor.insert([b, c])
        #expect(editor.items.map(\.id) == [a.id, b.id, c.id])
        #expect(editor.selectedItemID == b.id)
    }

    @Test("The strip has no background unless the appearance gives it one")
    func stripBackgroundIsOptional() throws {
        let items = [MediaEditorItem(source: .photo(photo())), MediaEditorItem(source: .photo(photo()))]
        #expect(try #require(session(items).strip).backgroundColor == nil)

        var appearance = EditorAppearance.messaging
        appearance.thumbnailStripBackground = .darkGray
        #expect(try #require(session(items, appearance: appearance).strip).backgroundColor == .darkGray)
    }

    @Test("Dragging past halfway turns the page; a short drag springs back")
    func dragPages() async throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let b = MediaEditorItem(source: .photo(photo()))
        let editor = session([a, b])
        let width = editor.view.bounds.width

        editor.beginPaging()
        editor.updatePaging(translation: -width * 0.3)
        editor.endPaging(velocity: 0)
        try await waitUntil { !editor.isPaging }
        #expect(editor.selectedItemID == a.id, "not far enough, nor fast enough")

        editor.beginPaging()
        editor.updatePaging(translation: -width * 0.2)
        editor.endPaging(velocity: -2000)
        try await waitUntil { !editor.isPaging }
        #expect(editor.selectedItemID == b.id, "a flick carries a short drag over")

        editor.beginPaging()
        editor.updatePaging(translation: -width * 0.8)
        editor.endPaging(velocity: 0)
        try await waitUntil { !editor.isPaging }
        #expect(editor.selectedItemID == b.id, "nothing past the last item")

        editor.beginPaging()
        editor.updatePaging(translation: width * 0.6)
        editor.endPaging(velocity: 0)
        try await waitUntil { !editor.isPaging }
        #expect(editor.selectedItemID == a.id)
    }

    @Test("A drag catches a turn still animating, from where its pages are, and can turn straight back")
    func pagingCanBeInterrupted() async throws {
        let a = MediaEditorItem(source: .photo(photo(.red)))
        let b = MediaEditorItem(source: .photo(photo(.green)))
        let c = MediaEditorItem(source: .photo(photo(.blue)))
        let editor = session([a, b, c])
        let width = editor.view.bounds.width

        // A flick to b, caught at once while it's still sliding home.
        editor.beginPaging()
        editor.updatePaging(translation: -width * 0.3)
        editor.endPaging(velocity: -1500)
        // Usually still settling by now; on a loaded machine it may have just
        // landed and be fading out. A drag takes over either way.
        try await Task.sleep(for: .milliseconds(60))
        editor.beginPaging()
        #expect(editor.selectedItemID == b.id, "the caught turn lands at once")
        #expect(editor.isPaging, "and the new drag starts straight away")
        let cover = try #require(editor.view.subviews.first { $0.frame == editor.view.bounds && !$0.isUserInteractionEnabled })
        let track = try #require(cover.subviews.first)
        // Where the animation had got to on screen — which an off-screen test
        // window may report as already home, hence `>=`.
        #expect(track.transform.tx >= 0 && track.transform.tx < width / 2,
                "no jump: b stays where it was on screen")
        #expect(editor.view.subviews.filter { $0.frame == editor.view.bounds && !$0.isUserInteractionEnabled }.count == 1,
                "one cover, not one per turn")

        // …and straight back to a.
        editor.updatePaging(translation: width * 0.7)
        editor.endPaging(velocity: 0)
        try await waitUntil { !editor.isPaging }
        #expect(editor.selectedItemID == a.id)

        // Right after landing, while the turn fades out, a drag starts at once too.
        editor.beginPaging()
        #expect(editor.isPaging)
        #expect(abs(try #require(editor.view.subviews.first { $0.frame == editor.view.bounds && !$0.isUserInteractionEnabled })
            .subviews.first!.transform.tx) < 1)
        editor.endPaging(velocity: 0, cancelled: true)
        try await waitUntil { !editor.isPaging }
    }

    @Test("A page turn lays its track below the chrome and clears it after")
    func pagingTrack() async throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let b = MediaEditorItem(source: .photo(photo()))
        let editor = session([a, b])
        let before = editor.view.subviews.count
        editor.beginPaging()
        #expect(editor.isPaging)
        #expect(editor.view.subviews.count == before + 1)
        let track = try #require(editor.view.subviews.first { !$0.isUserInteractionEnabled && $0.frame == editor.view.bounds })
        let strip = try #require(editor.strip)
        let order = editor.view.subviews
        #expect(try #require(order.firstIndex(of: track)) < #require(order.firstIndex(of: strip)))
        editor.updatePaging(translation: -editor.view.bounds.width * 0.7)
        // The pages move; what covers the live canvas doesn't, so the canvas
        // can't show at the edge they've left.
        #expect(track.frame == editor.view.bounds)
        #expect(track.transform == .identity)
        #expect(try #require(track.subviews.first).transform.tx < 0)
        editor.endPaging(velocity: 0)
        try await waitUntil { editor.view.subviews.count == before }
        #expect(editor.selectedItemID == b.id)
    }

    @Test("Passthrough content with a tiny ideal size can't squash the canvas")
    func passthroughKeepsCanvas() throws {
        // A document viewer's hosting view: a few points ideal, hugging them
        // harder than the bar does — at equal priorities which side gives way
        // is down to Auto Layout, and on device it was the canvas.
        let preview: @MainActor @Sendable () -> UIView = {
            let view = UIHostingController(rootView: Color.clear.frame(width: 10, height: 10)).view!
            view.setContentHuggingPriority(.defaultHigh, for: .vertical)
            return view
        }
        let items = [MediaEditorItem(source: .passthrough(thumbnail: nil, preview: preview)),
                     MediaEditorItem(source: .passthrough(thumbnail: nil, preview: preview))]
        // Like a host's SwiftUI bar: sized only by its intrinsic height,
        // which Auto Layout may stretch at default priorities.
        let accessory = UIHostingController(rootView: Color.clear.frame(height: 100)).view!
        let editor = session(items, accessory: accessory)
        editor.view.layoutIfNeeded()

        let strip = try #require(editor.strip)
        let canvas = try #require(editor.view.subviews.first { $0 is UIImageView && $0.frame.width > 200 })
        #expect(canvas.frame.height > 300, "the canvas fills down towards the strip")
        #expect(strip.frame.minY > editor.view.bounds.midY, "the strip stays at the bottom")
        #expect(abs(accessory.safeAreaLayoutGuide.layoutFrame.height - 100) < 1, "the bar keeps its content height")
    }

    @Test("An incoming video slides in where it will sit, above its controls")
    func incomingVideoLandsInPlace() async throws {
        // Tall, so the box above the controls is what limits it.
        let source = try await VideoFixture.make(width: 200, height: 600, seconds: 1)
        let editor = session([MediaEditorItem(source: .photo(photo())), MediaEditorItem(source: .video(source))])
        let width = editor.view.bounds.width

        editor.beginPaging()
        let track = try #require(editor.view.subviews.first { $0.frame == editor.view.bounds && !$0.isUserInteractionEnabled })
        let page = try #require(track.subviews.first?.subviews.compactMap { $0 as? UIImageView }
            .first { $0.frame.minX > width / 2 })
        // The page's picture is fitted into its frame, as the player will be.
        let incoming = AVMakeRect(aspectRatio: CGSize(width: 200, height: 600),
                                  insideRect: page.frame.offsetBy(dx: -width, dy: 0))
        editor.updatePaging(translation: -width * 0.7)
        editor.endPaging(velocity: 0)
        try await waitUntil { !editor.isPaging && editor.videoOrientedSize != .zero }
        editor.view.layoutIfNeeded()

        let (canvas, _) = try canvas(of: editor)
        let player = try #require(canvas.subviews.first)
        let live = editor.view.convert(player.bounds, from: player)
        #expect(abs(live.minY - incoming.minY) < 1.5, "no jump up or down as the player takes over")
        #expect(abs(live.height - incoming.height) < 1.5)
    }

    // MARK: - Zoom

    private func canvas(of editor: MediaEditorViewController) throws -> (UIImageView, OverlayContainerView) {
        let image = try #require(editor.view.subviews.first { $0 is UIImageView && $0.bounds.width > 200 } as? UIImageView)
        let overlay = try #require(editor.view.subviews.first { $0 is OverlayContainerView } as? OverlayContainerView)
        return (image, overlay)
    }

    @Test("A double tap zooms the media and its edits together, and a second one zooms back out")
    func doubleTapZooms() async throws {
        let editor = session([MediaEditorItem(source: .photo(photo(size: CGSize(width: 4000, height: 3000)))),
                              MediaEditorItem(source: .photo(photo()))])
        let (image, overlay) = try canvas(of: editor)
        let unzoomedPixels = try #require(image.image).size.width

        editor.handleCanvasDoubleTap(at: CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY))
        #expect(editor.isZoomed)
        #expect(image.transform.a == 2.5)
        #expect(overlay.transform == image.transform, "stickers and drawing zoom with the media")
        try await waitUntil { (image.image?.size.width ?? 0) > unzoomedPixels * 2 }   // sharpened in the background
        #expect(!overlay.canvasPan.pagesItems, "a drag pans the zoomed media instead of paging")

        editor.handleCanvasDoubleTap(at: .zero)
        #expect(!editor.isZoomed)
        #expect(image.transform == .identity)
        #expect(overlay.canvasPan.pagesItems)
        #expect(try #require(image.image).size.width == unzoomedPixels, "the unzoomed preview is back at once")
    }

    @Test("A pinch only moves the picture; it's re-rendered once, off the main actor, after")
    func pinchDoesNotRender() async throws {
        let editor = session([MediaEditorItem(source: .photo(photo(size: CGSize(width: 4000, height: 3000))))])
        let (image, overlay) = try canvas(of: editor)
        let unzoomed = try #require(image.image)
        let pinch = ScriptedPinch(target: nil, action: nil)
        overlay.onCanvasPinch?(pinch)
        pinch.scriptedState = .changed
        for _ in 0..<30 {
            pinch.scale = 1.05
            overlay.onCanvasPinch?(pinch)
            editor.view.layoutIfNeeded()       // a pinch lays the views out every frame
            #expect(image.image === unzoomed, "no re-render mid-pinch")
        }
        pinch.scriptedState = .ended
        overlay.onCanvasPinch?(pinch)
        #expect(image.image === unzoomed, "the sharper render doesn't block the main actor")
        try await waitUntil { image.image !== unzoomed }
    }

    @Test("Zoomed in, an edit shows at once at screen size, then sharpens; no zoomed-size source is kept")
    func editWhileZoomed() async throws {
        let editor = session([MediaEditorItem(source: .photo(photo(size: CGSize(width: 4000, height: 3000))))])
        let (image, overlay) = try canvas(of: editor)
        let screenSized = try #require(image.image).size.width
        let source = try #require(editor.previewSourcePixelSize)

        editor.handleCanvasDoubleTap(at: CGPoint(x: overlay.bounds.midX, y: overlay.bounds.midY))
        try await waitUntil { (image.image?.size.width ?? 0) > screenSized * 2 }
        #expect(editor.previewSourcePixelSize == source, "only the rendered picture is zoomed-size")

        var next = editor.recipe
        next.filter = .mono
        editor.apply(next)
        #expect(try #require(image.image).size.width == screenSized, "rendered at screen size, not at the zoom")
        #expect(editor.isZoomed, "the zoom stays")
        try await waitUntil { (image.image?.size.width ?? 0) > screenSized * 2 }   // and sharpens again

        editor.handleCanvasDoubleTap(at: .zero)
        #expect(try #require(image.image).size.width == screenSized, "zoomed out at once, with the edit")
        #expect(editor.previewSourcePixelSize == source)
    }

    @Test("Zoomed media can't be moved past its own edges")
    func zoomStaysOnTheMedia() throws {
        let editor = session([MediaEditorItem(source: .photo(photo(size: CGSize(width: 400, height: 400))))])
        let (image, overlay) = try canvas(of: editor)
        // A tap in the far corner: centring it would pull the media's edge in.
        editor.handleCanvasDoubleTap(at: .zero)
        let zoomed = image.frame
        let preview = CGRect(x: image.center.x - image.bounds.width / 2, y: image.center.y - image.bounds.height / 2,
                             width: image.bounds.width, height: image.bounds.height)
        // A square photo fills the preview's width: zoomed, it still covers it.
        #expect(zoomed.minX <= preview.minX + 0.5)
        #expect(zoomed.maxX >= preview.maxX - 0.5)
        #expect(overlay.transform == image.transform)
    }

    @Test("Switching items, turning a page or opening a tool resets the zoom")
    func zoomResets() async throws {
        let a = MediaEditorItem(source: .photo(photo()))
        let b = MediaEditorItem(source: .photo(photo()))
        let editor = session([a, b])
        let (image, _) = try canvas(of: editor)
        let center = CGPoint(x: image.bounds.midX, y: image.bounds.midY)

        editor.handleCanvasDoubleTap(at: center)
        editor.select(b.id)
        #expect(!editor.isZoomed)
        #expect(image.transform == .identity)

        editor.handleCanvasDoubleTap(at: center)
        editor.beginPaging()
        #expect(!editor.isZoomed)
        editor.endPaging(velocity: 0, cancelled: true)
        try await waitUntil { !editor.isPaging }

        editor.handleCanvasDoubleTap(at: center)
        editor.enterCropMode()
        #expect(!editor.isZoomed)
        #expect(image.transform == .identity)
    }

    // MARK: - Finishing

    @Test(".recipesOnly hands back every recipe at once, rendering nothing")
    func recipesOnly() async throws {
        let a = MediaEditorItem(source: .photo(photo()), recipe: rotated())
        let b = MediaEditorItem(source: .photo(photo()))
        var configuration = EditorConfiguration()
        configuration.finishMode = .recipesOnly
        let editor = session([a, b], configuration: configuration)
        var result: MediaEditorSessionResult?
        editor.onSessionFinish = { result = $0 }
        editor.finish()
        guard case let .saved(results) = try #require(result, "synchronous: nothing to wait for") else {
            Issue.record("expected .saved")
            return
        }
        #expect(results.map(\.item.id) == [a.id, b.id])
        #expect(results.allSatisfy { $0.output == nil })
        #expect(results[0].item.recipe == rotated())
    }

    @Test(".render renders edited items, and leaves identity and passthrough ones to the host")
    func renderMode() async throws {
        let edited = MediaEditorItem(source: .photo(photo(size: CGSize(width: 40, height: 30))), recipe: rotated())
        let untouched = MediaEditorItem(source: .photo(photo()))
        let file = MediaEditorItem(source: .passthrough(thumbnail: nil, preview: { UIView() }))
        let editor = session([edited, untouched, file])

        guard case let .saved(results) = await finishing(editor) else {
            Issue.record("expected .saved")
            return
        }
        guard case let .photo(image) = try #require(results[0].output) else {
            Issue.record("expected a photo")
            return
        }
        #expect(image.size.width == 30 && image.size.height == 40, "rendered with the rotation")
        #expect(results[1].output == nil, "an identity recipe is sent as the original")
        #expect(results[2].output == nil, "passthrough content isn't rendered")
    }

    @Test("Passthrough items have no tools and keep an identity recipe")
    func passthroughHasNoTools() throws {
        let gif = MediaEditorItem(source: .passthrough(thumbnail: nil, preview: { UIView() }))
        let editor = session([gif, MediaEditorItem(source: .photo(photo()))])
        #expect(editor.toolbarActions.isEmpty)
        #expect(!editor.isEnabled(.crop))
        editor.perform(.rotate)
        #expect(editor.recipe == .identity)
    }

    // MARK: - Rendering matches the editor

    @Test("EditRenderer renders a photo exactly as the editor's own save")
    func rendererMatchesEditor() async throws {
        let source = photo(.orange, size: CGSize(width: 120, height: 80))
        var recipe = EditRecipe(crop: CropState(rect: NormalizedRect(x: 0.1, y: 0.1, width: 0.7, height: 0.8)),
                                rotation: RotationState(degrees: 90),
                                flip: FlipState(horizontal: true, vertical: false),
                                filter: .mono)
        let sticker = photo(.red, size: CGSize(width: 20, height: 20))
        recipe.overlays = [
            Overlay(content: .image(ImageRef(data: sticker.pngData())), zIndex: 0),
            Overlay(content: .text(TextStyle(string: "Hi", backgroundColor: .black)),
                    transform: NormalizedTransform(center: NormalizedPoint(x: 0.3, y: 0.7)), zIndex: 1),
        ]

        var saved: UIImage?
        let editor = laidOut(MediaEditorViewController(item: .photo(source), recipe: recipe, onFinish: { result in
            if case let .saved(.photo(image), _) = result { saved = image }
        }))
        editor.finish()
        let fromEditor = try #require(saved?.cgImage)
        let fromRenderer = try #require(try await EditRenderer().renderPhoto(source, recipe: recipe).cgImage)

        #expect(fromEditor.width == fromRenderer.width && fromEditor.height == fromRenderer.height)
        #expect(pixels(of: fromEditor) == pixels(of: fromRenderer), "one code path, one result")
    }

    @Test("EditRenderer looks sticker images up through its resolver")
    func rendererResolvesImagesByID() throws {
        let ref = ImageRef()                           // no data: stored by the host
        let recipe = EditRecipe(overlays: [Overlay(content: .image(ref))])
        #expect(EditRenderer().stickerImages(for: recipe).isEmpty)
        let resolver = EditRenderer(images: { $0.id == ref.id ? photo(.red) : nil })
        #expect(resolver.stickerImages(for: recipe)[ref.id] != nil)
    }

    @Test("Thumbnails never exceed the requested size, and file photos are downsampled")
    func thumbnailsStaySmall() async throws {
        let url = try photoFile(photo(size: CGSize(width: 1200, height: 900)))
        defer { try? FileManager.default.removeItem(at: url) }
        var recipe = EditRecipe(rotation: RotationState(degrees: 12))
        recipe.crop = CropState(rect: NormalizedRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2))
        for item in [MediaEditorItem(source: .photoFile(url), recipe: recipe),
                     MediaEditorItem(source: .photo(photo(size: CGSize(width: 1200, height: 900))))] {
            let thumbnail = try #require(await EditRenderer().thumbnail(for: item, maxPixelSize: 64))
            let longest = max(thumbnail.size.width * thumbnail.scale, thumbnail.size.height * thumbnail.scale)
            #expect(longest <= 64)
        }
    }

    @Test("A file photo is decoded at full size only while it's selected")
    func fileDecodedOnlyWhenSelected() async throws {
        let urls = try [photoFile(photo(.red)), photoFile(photo(.green))]
        defer { urls.forEach { try? FileManager.default.removeItem(at: $0) } }
        let a = MediaEditorItem(source: .photoFile(urls[0]))
        let b = MediaEditorItem(source: .photoFile(urls[1]))
        let editor = session([a, b])
        #expect(!editor.hasFullSizeDecode, "decoded off the main actor, not up front")
        try await waitUntil { editor.hasFullSizeDecode }

        editor.select(b.id)
        #expect(!editor.hasFullSizeDecode, "A's decode is released on the switch")
        try await waitUntil { editor.hasFullSizeDecode }
    }

    // MARK: - Video

    @Test("EditRenderer exports a video as the editor would — trimmed, cropped and silent")
    func rendererExportsVideo() async throws {
        let source = try await VideoFixture.make(width: 160, height: 120, seconds: 2, withAudio: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let recipe = EditRecipe(crop: CropState(rect: NormalizedRect(x: 0, y: 0, width: 0.5, height: 1)),
                                overlays: [Overlay(content: .text(TextStyle(string: "Hi")))],
                                trim: TrimRange(start: 0.5, duration: 1), removeAudio: true)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MediaEditor-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await EditRenderer().exportVideo(at: source, recipe: recipe, to: output)

        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 1) < 0.15)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 80 && size.height == 120)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
    }

    @Test("Cancelling an export throws CancellationError and leaves no file")
    func cancelledExportLeavesNothing() async throws {
        let source = try await VideoFixture.make(width: 640, height: 480, seconds: 4)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("MediaEditor-\(UUID().uuidString).mp4")
        let task = Task { @MainActor in
            try await EditRenderer().exportVideo(at: source, recipe: EditRecipe(rotation: RotationState(degrees: 90)),
                                                 to: output)
        }
        task.cancel()
        do {
            try await task.value
            Issue.record("the export should have been cancelled")
        } catch is CancellationError {
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test("Switching away from a video releases its player; tearDown stops everything")
    func switchingReleasesThePlayer() async throws {
        let source = try await VideoFixture.make(width: 160, height: 120, seconds: 1)
        defer { try? FileManager.default.removeItem(at: source) }
        let video = MediaEditorItem(source: .video(source))
        let picture = MediaEditorItem(source: .photo(photo()))
        let editor = session([video, picture])
        #expect(editor.hasVideoPlayer)

        editor.select(picture.id)
        #expect(!editor.hasVideoPlayer)
        #expect(!editor.isVideoPlaying)
        #expect(editor.toolbarActions.contains(.filters), "the photo's tools are back")

        editor.select(video.id)
        #expect(editor.hasVideoPlayer)
        editor.tearDown()
        #expect(!editor.isVideoPlaying)
        #expect(editor.displayLinkIsPaused == nil, "the display link is gone")
        #expect(!editor.isExporting)
    }

    @Test("Switching from a photo to a video with sound shows its audio toggle")
    func audioToggleAppearsAfterSwitch() async throws {
        let source = try await VideoFixture.make(width: 160, height: 120, seconds: 1, withAudio: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let picture = MediaEditorItem(source: .photo(photo()))
        let video = MediaEditorItem(source: .video(source))
        // Circular buttons: the toggle sits in a backing of its own.
        let editor = session([picture, video], appearance: .messaging)
        editor.select(video.id)
        try await waitUntil { editor.isEnabled(.toggleAudio) }

        let toggle = try #require(button(labeled: L10n.removeAudio, in: editor.view))
        let hidden = sequence(first: toggle as UIView, next: { $0.superview }).contains { $0.isHidden }
        #expect(!hidden, "the toggle, not just an empty backing, is on screen")
    }

    // MARK: - Layout

    @Test("While the keyboard is up, the bar's growth doesn't move the media")
    func layoutFreezesWhileTyping() throws {
        let bar = UIView()
        let height = bar.heightAnchor.constraint(equalToConstant: 60)
        height.isActive = true
        let editor = session([MediaEditorItem(source: .photo(photo())), MediaEditorItem(source: .photo(photo()))],
                             accessory: bar)
        let preview = try #require(editor.view.subviews.first { $0 is OverlayContainerView })
        let resting = preview.frame

        NotificationCenter.default.post(name: UIResponder.keyboardWillShowNotification, object: nil)
        height.constant = 200                       // a list of suggestions grows
        editor.view.layoutIfNeeded()
        #expect(preview.frame == resting, "nothing behind the bar moves while typing")
        #expect(try #require(editor.strip).alpha == 0, "the strip makes way for the bar")

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        editor.view.layoutIfNeeded()
        #expect(preview.frame.maxY < resting.maxY, "back to following the bar once typing ends")
    }

    @Test("Removing an item keeps the strip seated on the bar and the media clear of both")
    func removalKeepsLayout() async throws {
        let url = try photoFile(photo(size: CGSize(width: 1200, height: 900)))
        defer { try? FileManager.default.removeItem(at: url) }
        let bar = UIView()
        bar.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let picture = MediaEditorItem(source: .photo(photo()))
        let file = MediaEditorItem(source: .photoFile(url))
        let document = MediaEditorItem(source: .passthrough(thumbnail: nil, preview: { UIView() }))
        let editor = session([picture, file, document], accessory: bar)
        editor.onAddItems = {}
        editor.select(document.id)
        let strip = try #require(editor.strip)
        let preview = try #require(editor.view.subviews.first { $0 is OverlayContainerView })

        editor.remove(document.id)
        try await waitUntil { editor.hasFullSizeDecode }
        try await Task.sleep(for: .milliseconds(300))     // let the strip's animation settle
        editor.view.layoutIfNeeded()

        #expect(editor.selectedItemID == file.id)
        #expect(abs(strip.frame.maxY - bar.frame.minY) < 1, "the strip rides on the bar")
        #expect(preview.frame.maxY <= strip.frame.minY, "the media stays clear of the strip")
        #expect(strip.alpha == 1 && !strip.isHidden)
    }

    /// A bar sized by its content, like a SwiftUI-hosted one, rather than by a
    /// fixed-height constraint.
    private final class IntrinsicBar: UIView {
        override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: 100) }
    }

    @Test("A large photo never squashes a bar that is sized by its content")
    func largePhotoDoesNotSquashTheBar() async throws {
        let url = try photoFile(photo(size: CGSize(width: 1200, height: 1600)))
        defer { try? FileManager.default.removeItem(at: url) }
        let bar = IntrinsicBar()
        // Equal priorities leave the outcome to Auto Layout's tie-breaking —
        // which is what squashed a SwiftUI caption bar in the example app. One
        // step below the default makes it deterministic: the editor's preview
        // must never compete for height at all.
        bar.setContentCompressionResistancePriority(.defaultHigh - 1, for: .vertical)
        let editor = session([MediaEditorItem(source: .photoFile(url)), MediaEditorItem(source: .photo(photo()))],
                             accessory: bar)
        try await waitUntil { editor.hasFullSizeDecode }
        editor.view.layoutIfNeeded()
        // The decode is 1600 points tall; the preview must give way, not the bar.
        #expect(bar.frame.height == 100)
    }

    // MARK: - Lifetime

    @Test("A session editor deallocates once released")
    func sessionDeallocates() async throws {
        weak var leaked: MediaEditorViewController?
        do {
            let editor = MediaEditorViewController(items: [MediaEditorItem(source: .photo(photo())),
                                                           MediaEditorItem(source: .photo(photo()))])
            editor.onRecipeChange = { _, _ in }
            editor.onItemsChange = { _ in }
            editor.onSelectionChange = { _ in }
            editor.loadViewIfNeeded()
            editor.tearDown()
            leaked = editor
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(leaked == nil)
    }

    // MARK: - Helpers

    private func pixels(of image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
    }

    private func button(labeled label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        for subview in view.subviews {
            if let found = button(labeled: label, in: subview) { return found }
        }
        return nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}

#endif
