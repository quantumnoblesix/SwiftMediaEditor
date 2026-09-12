//
//  EditorChromeTests.swift
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
import Testing
import MediaEditorCore
@testable import MediaEditorUIKit

/// Records what the editor asks of a host-supplied toolbar.
@MainActor
private final class SpyToolbar: MediaEditorToolbarProviding {
    private(set) var offeredActions: [EditorAction] = []
    private(set) var updateCount = 0
    let view = UIView()
    var hidesInToolMode = true

    func makeToolbar(for actions: [EditorAction],
                     editor: MediaEditorViewController) -> UIView? {
        offeredActions = actions
        return view
    }

    func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController) {
        updateCount += 1
    }

    func hidesToolbarInToolMode(_ toolbar: UIView) -> Bool { hidesInToolMode }
}

@MainActor
@Suite("Editor chrome customization")
struct EditorChromeTests {

    private func photo() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.blue.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
    }

    // MARK: - Which actions are offered

    @Test("A photo offers the photo tools and never the audio toggle")
    func photoActions() {
        let editor = MediaEditorViewController(item: .photo(photo()))
        let actions = editor.toolbarActions
        #expect(actions.contains(.crop))
        #expect(actions.contains(.filters))
        #expect(actions.contains(.drawing))
        #expect(actions.contains(.addText))
        #expect(!actions.contains(.toggleAudio))
        // Undo/redo live in the top bar, not the tool row.
        #expect(!actions.contains(.undo))
        #expect(!actions.contains(.redo))
    }

    @Test("A video offers the audio toggle and the pencil, but not filters")
    func videoActions() {
        let url = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.mov")
        let editor = MediaEditorViewController(item: .video(url))
        let actions = editor.toolbarActions
        #expect(actions.contains(.toggleAudio))
        #expect(actions.contains(.crop))
        #expect(actions.contains(.drawing))
        #expect(actions.contains(.addText))
        #expect(!actions.contains(.filters))
    }

    @Test("Configuration narrows the offered actions")
    func configurationFiltersActions() {
        var config = EditorConfiguration()
        config.tools = [.crop]
        let editor = MediaEditorViewController(item: .photo(photo()), configuration: config)
        #expect(editor.toolbarActions == [.crop])
    }

    @Test("Rotate and flip surface in the main row only when crop is off")
    func rotateFlipPromotedWithoutCrop() {
        var config = EditorConfiguration()
        config.tools = [.rotate, .flip]
        let editor = MediaEditorViewController(item: .photo(photo()), configuration: config)
        #expect(editor.toolbarActions.contains(.rotate))
        #expect(editor.toolbarActions.contains(.flipHorizontal))

        config.tools = [.crop, .rotate, .flip]
        let withCrop = MediaEditorViewController(item: .photo(photo()), configuration: config)
        #expect(!withCrop.toolbarActions.contains(.rotate))
        #expect(withCrop.toolbarActions.contains(.crop))
    }

    // MARK: - Replacing the toolbar

    @Test("A provider's view replaces the built-in bar")
    func providerSuppliesToolbar() {
        let spy = SpyToolbar()
        let editor = MediaEditorViewController(item: .photo(photo()), toolbarProvider: spy)
        editor.loadViewIfNeeded()

        #expect(spy.view.superview === editor.view)
        #expect(spy.offeredActions == editor.toolbarActions)
        // Built once, then handed the initial state.
        #expect(spy.updateCount >= 1)
    }

    @Test("Returning nil keeps the built-in bar")
    func providerCanDeclineToolbar() {
        final class Declining: MediaEditorToolbarProviding {
            func makeToolbar(for actions: [EditorAction],
                             editor: MediaEditorViewController) -> UIView? { nil }
        }
        let declining = Declining()
        let editor = MediaEditorViewController(item: .photo(photo()), toolbarProvider: declining)
        editor.loadViewIfNeeded()
        // The stock glass bar is in the hierarchy instead.
        #expect(editor.view.subviews.contains { $0 is UIVisualEffectView })
    }

    @Test("Undo and redo stay drivable even though the row omits them")
    func historyActionsRemainAvailable() {
        let editor = MediaEditorViewController(item: .photo(photo()))
        editor.loadViewIfNeeded()
        #expect(!editor.toolbarActions.contains(.undo))
        #expect(!editor.isEnabled(.undo))

        editor.perform(.rotate)
        #expect(editor.isEnabled(.undo))
        editor.perform(.undo)
        #expect(editor.recipe.rotation.degrees == 0)
    }

    @Test("State changes reach the custom toolbar")
    func stateChangesNotifyProvider() {
        let spy = SpyToolbar()
        let editor = MediaEditorViewController(item: .photo(photo()), toolbarProvider: spy)
        editor.loadViewIfNeeded()
        let before = spy.updateCount

        #expect(!editor.isEnabled(.undo))
        var next = editor.recipe
        next.rotation = RotationState(degrees: 90)
        editor.apply(next)

        #expect(editor.isEnabled(.undo))
        #expect(spy.updateCount > before, "applying an edit should refresh the toolbar")
    }

    @Test("A custom row can stay visible while a tool is open")
    func customToolbarCanOptOutOfHiding() {
        let spy = SpyToolbar()
        spy.hidesInToolMode = false
        let editor = MediaEditorViewController(item: .photo(photo()), toolbarProvider: spy)
        editor.loadViewIfNeeded()

        editor.enterCropMode()
        #expect(!spy.view.isHidden)

        let hiding = SpyToolbar()
        let other = MediaEditorViewController(item: .photo(photo()), toolbarProvider: hiding)
        other.loadViewIfNeeded()
        other.enterCropMode()
        #expect(hiding.view.isHidden)
    }

    // MARK: - Chrome layering

    @Test("Chrome stays above the preview's sticker layer, or its taps are swallowed")
    func chromeSitsAbovePreview() throws {
        let editor = MediaEditorViewController(item: .photo(photo()))
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        // The sticker layer covers the whole preview rect and claims every touch
        // inside it, so anything interactive must be ordered after it.
        let stickerLayer = try #require(editor.view.subviews.first { $0 is OverlayContainerView })
        let undo = try #require(button(labeled: L10n.undo, in: editor.view),
                                "undo button should exist in the chrome")
        let undoRoot = try #require(
            sequence(first: undo as UIView, next: { $0.superview })
                .first { $0.superview === editor.view },
            "undo should live under a direct child of the editor's view")

        let order = editor.view.subviews
        let stickerIndex = try #require(order.firstIndex(of: stickerLayer))
        let undoIndex = try #require(order.firstIndex(of: undoRoot))
        #expect(undoIndex > stickerIndex,
                "the history pill overlaps the preview, so it must be layered above the sticker view")
    }

    /// Depth-first search for a button by its accessibility label, which the
    /// appearance sets from the action.
    private func button(labeled label: String, in view: UIView) -> UIButton? {
        if let button = view as? UIButton, button.accessibilityLabel == label { return button }
        for subview in view.subviews {
            if let found = button(labeled: label, in: subview) { return found }
        }
        return nil
    }

    // MARK: - Driving the editor

    @Test("perform routes actions the same way the built-in chrome does")
    func performRunsActions() {
        let editor = MediaEditorViewController(item: .photo(photo()))
        editor.loadViewIfNeeded()

        editor.perform(.rotate)
        #expect(editor.recipe.rotation.degrees == 90)

        editor.perform(.flipHorizontal)
        #expect(editor.recipe.flip.horizontal)

        editor.perform(.undo)
        #expect(!editor.recipe.flip.horizontal)

        editor.perform(.redo)
        #expect(editor.recipe.flip.horizontal)
    }

    @Test("isActive reflects the open tool")
    func isActiveTracksMode() {
        let editor = MediaEditorViewController(item: .photo(photo()))
        editor.loadViewIfNeeded()
        #expect(!editor.isActive(.crop))
        editor.enterCropMode()
        #expect(editor.isActive(.crop))
    }

    @Test("The audio toggle is disabled without an audio track")
    func audioToggleNeedsATrack() {
        let editor = MediaEditorViewController(item: .photo(photo()))
        #expect(!editor.isEnabled(.toggleAudio))
    }

    // MARK: - Lifetime

    @Test("The editor deallocates even though a display link is running")
    func editorDoesNotLeakBehindDisplayLink() async {
        weak var leaked: MediaEditorViewController?
        do {
            let editor = MediaEditorViewController(
                item: .video(URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")))
            editor.loadViewIfNeeded()      // starts the display link
            leaked = editor
        }
        // The asset load is async; give it a turn to finish and let go.
        await Task.yield()

        // A CADisplayLink retains its target and the run loop retains the link,
        // so aiming one at the editor would keep it — and its AVPlayer — alive
        // for the life of the process.
        #expect(leaked == nil, "the display link must not retain the editor")
    }

    @Test("The display-link proxy forwards ticks and stops once its target is gone")
    func proxyForwardsAndStops() {
        let proxy = DisplayLinkProxy()
        var ticks = 0
        proxy.onTick = { ticks += 1; return true }

        let live = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        proxy.tick(live)
        #expect(ticks == 1, "a live target should receive the tick")
        live.invalidate()

        // Reporting `false` stands in for a deallocated editor: the proxy must
        // invalidate the link so the run loop stops driving it.
        let dead = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        dead.add(to: .main, forMode: .common)
        proxy.onTick = { false }
        proxy.tick(dead)
        #expect(ticks == 1, "no further work should run for a dead target")
    }

    // MARK: - Tool configuration

    @Test("Leaving .trim out of the configuration hides the filmstrip")
    func trimToolGatesTheScrubber() {
        let url = URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")

        var withoutTrim = EditorConfiguration()
        withoutTrim.videoTools = EditorTools.allVideo.subtracting(.trim)
        let plain = MediaEditorViewController(item: .video(url), configuration: withoutTrim)
        plain.loadViewIfNeeded()
        #expect(!plain.view.subviews.contains { $0 is TrimScrubberView })

        let full = MediaEditorViewController(item: .video(url))
        full.loadViewIfNeeded()
        #expect(full.view.subviews.contains { $0 is TrimScrubberView })
    }

    @Test("Photos and videos each get the tool row configured for them")
    func toolsPerMediaKind() {
        var config = EditorConfiguration()
        config.photoTools = [.drawing, .filters]
        config.videoTools = [.crop, .audio]

        let photoEditor = MediaEditorViewController(item: .photo(photo()), configuration: config)
        #expect(photoEditor.toolbarActions == [.filters, .drawing])

        let videoEditor = MediaEditorViewController(
            item: .video(URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")), configuration: config)
        #expect(videoEditor.toolbarActions == [.crop, .toggleAudio],
                "drawing is on for photos only, so the video row leaves it out")
        videoEditor.loadViewIfNeeded()
        #expect(!videoEditor.view.subviews.contains { $0 is TrimScrubberView },
                "trim wasn't chosen for videos")
    }

    // MARK: - Preview cost

    /// A source far larger than any preview, to make downscaling observable.
    private func largePhoto() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000)).image { ctx in
            UIColor.orange.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        }
    }

    @Test("The preview renders at display size, not source size")
    func previewIsDownscaled() throws {
        let editor = MediaEditorViewController(item: .photo(largePhoto()))
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        let preview = try #require(editor.view.subviews.compactMap { $0 as? UIImageView }.first?.image)
        // Whatever the screen scale, a 3000px source must not reach the view
        // whole — that is ~24 MB of RGBA re-created on every single edit.
        #expect(preview.size.width < 3000,
                "preview should be downscaled, got \(preview.size)")
        // The aspect ratio has to survive, or the crop overlay maths breaks.
        #expect(abs(preview.size.width / preview.size.height - 1.5) < 0.01)
    }

    @Test("Moving an overlay doesn't re-render the base image")
    func overlayEditsSkipTheRender() {
        var base = EditRecipe()
        base.rotation = RotationState(degrees: 90)

        var movedSticker = base
        movedSticker.overlays = [Overlay(content: .text(TextStyle(string: "hi")), zIndex: 0)]
        #expect(!movedSticker.rendersDifferently(from: base),
                "overlays composite as live views, so the bitmap is unchanged")

        var cropped = base
        cropped.crop = CropState(rect: .init(x: 0, y: 0, width: 0.5, height: 0.5))
        #expect(cropped.rendersDifferently(from: base))

        var filtered = base
        filtered.filter = .noir
        #expect(filtered.rendersDifferently(from: base))
    }

    // MARK: - Playback cost

    @Test("The display link idles while the video is parked")
    func displayLinkPausesWhenStopped() {
        let editor = MediaEditorViewController(
            item: .video(URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")))
        editor.loadViewIfNeeded()

        // Nothing is playing, so no per-frame work should be scheduled.
        #expect(!editor.isVideoPlaying)
        editor.syncTransport(animated: false)
        #expect(editor.displayLinkIsPaused == true,
                "a parked video should not be waking the app every frame")
    }

    // MARK: - Delete bin placement

    /// The bin's centre and armed bottom edge, in the editor view's coordinates.
    private func binPlacement(in editor: MediaEditorViewController) throws -> (center: CGPoint, armedBottom: CGFloat) {
        let container = try #require(editor.view.subviews.first { $0 is OverlayContainerView } as? OverlayContainerView)
        let center = editor.view.convert(container.trashCenter, from: container)
        // Measured at the armed size, the largest the bin gets.
        return (center, center.y + StickerTrashView.diameter * 1.3 / 2)
    }

    @Test("For a photo the delete bin sits just above the tool row")
    func binSitsAboveToolRow() throws {
        let editor = MediaEditorViewController(item: .photo(photo()))
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        let crop = try #require(button(labeled: L10n.cropTitle, in: editor.view))
        let toolRow = try #require(
            sequence(first: crop as UIView, next: { $0.superview }).first { $0.superview === editor.view })
        let bin = try binPlacement(in: editor)

        #expect(bin.armedBottom <= toolRow.frame.minY, "the tool row is layered above the bin, so it must never overlap it")
        #expect(toolRow.frame.minY - bin.armedBottom < 40, "the bin should sit near the tool row")
        #expect(abs(bin.center.x - editor.view.bounds.midX) < 1)
    }

    @Test("For a trimmable video the delete bin sits just above the filmstrip")
    func binSitsAboveFilmstrip() throws {
        let editor = MediaEditorViewController(
            item: .video(URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")))
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.view.layoutIfNeeded()

        let filmstrip = try #require(editor.view.subviews.first { $0 is TrimScrubberView })
        let bin = try binPlacement(in: editor)

        let readout = try #require(editor.view.subviews.first { $0 is PlaybackTimeLabel })

        #expect(bin.armedBottom <= filmstrip.frame.minY, "the filmstrip is layered above the bin, so it must never overlap it")
        #expect(bin.armedBottom <= readout.frame.minY, "nor may it cover the time readout on top of the filmstrip")
        #expect(filmstrip.frame.minY - bin.armedBottom < 40)
    }

    // MARK: - Appearance

    @Test("Appearance overrides the glyph for an action")
    func appearanceOverridesSymbols() {
        var appearance = EditorAppearance()
        #expect(appearance.symbolName(for: .crop) == EditorAction.crop.defaultSymbolName)
        appearance.symbols[.crop] = "scissors"
        #expect(appearance.symbolName(for: .crop) == "scissors")
    }

    @Test("The per-button styling hook runs after the defaults")
    func appearanceStylingHookRuns() {
        var appearance = EditorAppearance()
        var styled: [EditorAction] = []
        appearance.styleToolButton = { button, action in
            styled.append(action)
            button.tintColor = .magenta
        }
        let button = UIButton(type: .system)
        appearance.styleToolButton(button, action: .undo)
        #expect(styled == [.undo])
        #expect(button.tintColor == .magenta, "the hook should win over the default tint")
    }

    @Test("Opting out of Liquid Glass falls back to the blur material")
    func canOptOutOfLiquidGlass() {
        var appearance = EditorAppearance()
        appearance.prefersLiquidGlass = false
        #expect(!appearance.usesLiquidGlass)
        let bar = appearance.makeBarBackground(cornerRadius: 12)
        #expect(bar.effect is UIBlurEffect)
        #expect(bar.layer.cornerRadius == 12)
    }
}

#endif
