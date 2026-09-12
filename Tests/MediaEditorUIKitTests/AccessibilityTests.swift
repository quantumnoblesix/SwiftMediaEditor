//
//  AccessibilityTests.swift
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
import AVFoundation
import Testing
import MediaEditorCore
@testable import MediaEditorUIKit

private let fakeVideo = URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")

@MainActor
private func samplePhoto() -> UIImage {
    let format = UIGraphicsImageRendererFormat.preferred()
    format.scale = 1
    return UIGraphicsImageRenderer(size: CGSize(width: 400, height: 300), format: format).image { context in
        UIColor.orange.setFill()
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    }
}

@MainActor
private func laidOut(_ editor: MediaEditorViewController) -> MediaEditorViewController {
    editor.loadViewIfNeeded()
    editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
    editor.view.setNeedsLayout()
    editor.view.layoutIfNeeded()
    return editor
}

@MainActor
private func allViews<T: UIView>(_ type: T.Type, in root: UIView) -> [T] {
    var found: [T] = []
    if let match = root as? T { found.append(match) }
    for subview in root.subviews { found += allViews(type, in: subview) }
    return found
}

/// Whether `view` and everything above it are on screen.
@MainActor
private func isOnScreen(_ view: UIView) -> Bool {
    var current: UIView? = view
    while let candidate = current {
        if candidate.isHidden || candidate.alpha < 0.01 { return false }
        current = candidate.superview
    }
    return true
}

/// What VoiceOver would call `control`: its label, or else the title it shows.
/// UIKit derives a button's label from its title only once VoiceOver has loaded
/// its accessibility support, which a test run never does.
@MainActor
private func spokenName(of control: UIControl) -> String? {
    if let label = control.accessibilityLabel, !label.isEmpty { return label }
    guard let button = control as? UIButton else { return nil }
    return [button.configuration?.title, button.title(for: .normal), button.currentAttributedTitle?.string]
        .compactMap { $0 }
        .first { !$0.isEmpty }
}

/// Runs `button`'s touch-up-inside actions directly; `sendActions(for:)` needs a
/// host app to route through.
@MainActor
private func tap(_ button: UIButton) {
    for target in button.allTargets {
        for action in button.actions(forTarget: target.base, forControlEvent: .touchUpInside) ?? [] {
            _ = (target.base as? NSObject)?.perform(NSSelectorFromString(action), with: button)
        }
    }
}

/// Performs the custom action named `name` on `element`, as VoiceOver would.
@MainActor
@discardableResult
private func perform(_ name: String, on element: NSObject) -> Bool {
    guard let action = element.accessibilityCustomActions?.first(where: { $0.name == name }) else { return false }
    return action.actionHandler?(action) ?? false
}

@MainActor
private func close(_ a: NormalizedRect, _ b: NormalizedRect) -> Bool {
    abs(a.origin.x - b.origin.x) < 0.001 && abs(a.origin.y - b.origin.y) < 0.001
        && abs(a.size.width - b.size.width) < 0.001 && abs(a.size.height - b.size.height) < 0.001
}

// MARK: - Spies

@MainActor
private final class DialSpy: RotationDialDelegate {
    var changes: [Double] = []
    var commits = 0
    func rotationDial(_ dial: RotationDialView, didChangeTo degrees: Double) { changes.append(degrees) }
    func rotationDialDidCommit(_ dial: RotationDialView) { commits += 1 }
}

@MainActor
private final class TrimSpy: TrimScrubberDelegate {
    var edges: [TrimScrubberView.Edge] = []
    var commits = 0
    var scrubs: [Double] = []
    func trimScrubber(_ scrubber: TrimScrubberView, didChangeTrimFrom start: Double, to end: Double,
                      movingEdge edge: TrimScrubberView.Edge) { edges.append(edge) }
    func trimScrubberDidCommit(_ scrubber: TrimScrubberView) { commits += 1 }
    func trimScrubber(_ scrubber: TrimScrubberView, didScrubTo time: Double) { scrubs.append(time) }
}

@MainActor
private final class StickerSpy: StickerViewDelegate {
    var commits = 0
    var deletes = 0
    var textEdits = 0
    func stickerViewDidCommit(_ sticker: StickerView) { commits += 1 }
    func stickerViewDidSelect(_ sticker: StickerView) {}
    func stickerViewDidRequestDelete(_ sticker: StickerView) { deletes += 1 }
    func stickerViewDidRequestTextEdit(_ sticker: StickerView) { textEdits += 1 }
    func stickerView(_ sticker: StickerView, didDragTo location: CGPoint) {}
    func stickerView(_ sticker: StickerView, didEndDragAt location: CGPoint, cancelled: Bool) -> Bool { false }
}

// MARK: - Editor chrome

@MainActor
@Suite("Accessibility: editor chrome")
struct EditorChromeAccessibilityTests {

    private func unnamedControls(in editor: MediaEditorViewController) -> [UIControl] {
        allViews(UIControl.self, in: editor.view)
            .filter { isOnScreen($0) && $0.isUserInteractionEnabled && spokenName(of: $0) == nil }
    }

    @Test("Every control on screen has a name, in the main editor and in crop")
    func controlsAreNamed() {
        let photoEditor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        #expect(unnamedControls(in: photoEditor).isEmpty, "unnamed: \(unnamedControls(in: photoEditor))")

        photoEditor.enterCropMode()
        #expect(photoEditor.isActive(.crop))
        #expect(unnamedControls(in: photoEditor).isEmpty, "unnamed in crop: \(unnamedControls(in: photoEditor))")

        let videoEditor = laidOut(MediaEditorViewController(item: .video(fakeVideo)))
        #expect(unnamedControls(in: videoEditor).isEmpty, "unnamed: \(unnamedControls(in: videoEditor))")
    }

    @Test("The chosen aspect ratio reads as selected, and follows a new choice")
    func aspectSelection() throws {
        let editor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        editor.enterCropMode()
        let buttons = allViews(UIButton.self, in: editor.view).filter(isOnScreen)
        let original = try #require(buttons.first { spokenName(of: $0) == L10n.aspectOriginal })
        let square = try #require(buttons.first { spokenName(of: $0) == "1:1" })
        #expect(original.accessibilityTraits.contains(.selected), "a fresh crop starts on Original")
        #expect(!square.accessibilityTraits.contains(.selected))

        tap(square)
        #expect(square.accessibilityTraits.contains(.selected))
        #expect(!original.accessibilityTraits.contains(.selected))
    }

    @Test("An open tool's title is a heading VoiceOver can land on")
    func toolTitlesAreHeadings() throws {
        let editor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        editor.enterCropMode()
        let title = try #require(allViews(UILabel.self, in: editor.view)
            .first { $0.text == L10n.cropTitle && isOnScreen($0) })
        #expect(title.accessibilityTraits.contains(.header))
    }

    @Test("The escape gesture backs out of a tool, but never out of the editor")
    func escapeCancelsTools() {
        let editor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        #expect(!editor.accessibilityPerformEscape(), "escaping the editor itself would discard every edit")
        editor.enterCropMode()
        #expect(editor.accessibilityPerformEscape())
        #expect(!editor.isActive(.crop))
    }

    @Test("The two-finger double-tap plays or pauses a video, and leaves a photo alone")
    func magicTap() {
        let photoEditor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        #expect(!photoEditor.accessibilityPerformMagicTap())
        let videoEditor = laidOut(MediaEditorViewController(item: .video(fakeVideo)))
        #expect(videoEditor.accessibilityPerformMagicTap())
    }

    @Test("The photo keeps its colours under Smart Invert")
    func mediaIgnoresSmartInvert() {
        let editor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        let preview = allViews(UIImageView.self, in: editor.view)
            .first { $0.image != nil && isOnScreen($0) && $0.bounds.width > 100 }
        #expect(preview?.accessibilityIgnoresInvertColors == true)
    }

    @Test("Bar titles stop growing at accessibility sizes and show in the large content viewer")
    func barTitlesAreCapped() {
        let button = UIButton(type: .system)
        EditorAppearance().styleBarButton(button, title: L10n.cancel, role: .dismissing)
        #expect(button.showsLargeContentViewer)
        #expect(button.largeContentTitle == L10n.cancel)
        if let transformer = button.configuration?.titleTextAttributesTransformer {
            var huge = AttributeContainer()
            huge.uiKit.font = .systemFont(ofSize: 53)
            let capped = transformer(huge).uiKit.font?.pointSize ?? .infinity
            #expect(capped <= EditorAppearance.barTitleMaximumPointSize)
        } else {
            let size = button.titleLabel?.font.pointSize ?? .infinity
            #expect(size <= EditorAppearance.barTitleMaximumPointSize)
        }
    }

    @Test("Icon buttons show in the large content viewer at accessibility text sizes")
    func largeContentViewer() {
        let editor = laidOut(MediaEditorViewController(item: .photo(samplePhoto())))
        #expect(editor.view.interactions.contains { $0 is UILargeContentViewerInteraction })
        let iconButtons = allViews(UIButton.self, in: editor.view)
            .filter { isOnScreen($0) && $0.image(for: .normal) != nil }
        #expect(!iconButtons.isEmpty)
        for button in iconButtons {
            #expect(button.showsLargeContentViewer, "\(spokenName(of: button) ?? "?") has no large content view")
            #expect(!(button.largeContentTitle ?? "").isEmpty)
        }
    }
}

// MARK: - Video transport

@MainActor
@Suite("Accessibility: video transport")
struct TransportAccessibilityTests {

    @Test("The play button stays within reach through playback while VoiceOver runs")
    func playButtonStaysReachable() {
        defer { EditorAccessibility.assistiveTechnologyOverride = nil }
        let button = PlayPauseButton(appearance: EditorAppearance())

        EditorAccessibility.assistiveTechnologyOverride = false
        button.setPlaying(true, animated: false)
        #expect(button.alpha == 0, "without VoiceOver it gets out of the way")

        EditorAccessibility.assistiveTechnologyOverride = true
        button.setPlaying(true, animated: false)
        #expect(button.alpha == 1)
        #expect(button.isUserInteractionEnabled)
        #expect(button.accessibilityLabel == L10n.pause)
    }

    @Test("Play starts a media session, so VoiceOver doesn't talk over the video")
    func playTraits() {
        let button = PlayPauseButton(appearance: EditorAppearance())
        #expect(button.accessibilityTraits.contains(.startsMediaSession))
        button.setPlaying(true, animated: false)
        #expect(!button.accessibilityTraits.contains(.startsMediaSession))
        #expect(button.accessibilityTraits.contains(.button))
    }

    @Test("The time readout speaks durations instead of reading out colons")
    func timeReadout() {
        let label = PlaybackTimeLabel(appearance: EditorAppearance())
        label.locale = Locale(identifier: "en_US")
        label.configure(duration: 10)
        label.show(current: 2.5, total: 10)
        #expect(label.accessibilityLabel == L10n.playbackTime)
        let value = label.accessibilityValue ?? ""
        #expect(value.contains("2.5") && value.contains("10"), "got \(value)")
        #expect(!value.contains(":"))
        #expect(PlaybackTimeLabel.spokenTime(65.3, locale: Locale(identifier: "en_US")).contains("minute"))
    }
}

// MARK: - Adjustable controls

@MainActor
@Suite("Accessibility: adjustable controls")
struct AdjustableControlAccessibilityTests {

    @Test("The straighten dial steps a whole degree at a time and commits each step")
    func straightenDial() {
        let dial = RotationDialView()
        let spy = DialSpy()
        dial.delegate = spy
        #expect(dial.isAccessibilityElement)
        #expect(dial.accessibilityTraits.contains(.adjustable))
        #expect(dial.accessibilityLabel == L10n.straighten)

        dial.accessibilityIncrement()
        #expect(dial.degrees == 1)
        #expect(dial.accessibilityValue == "1°")
        dial.accessibilityDecrement()
        dial.accessibilityDecrement()
        #expect(dial.degrees == -1)
        #expect(spy.changes == [1, 0, -1])
        #expect(spy.commits == 3)

        dial.setDegrees(45)
        dial.accessibilityIncrement()
        #expect(dial.degrees == 45, "the dial stops at its range")
        #expect(spy.commits == 3, "a step that can't move reports nothing")
    }

    @Test("The crop frame grows and shrinks with a swipe, and moves through actions")
    func cropFrame() {
        let overlay = CropOverlayView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        overlay.imageFrame = overlay.bounds
        overlay.reset()
        #expect(overlay.accessibilityTraits.contains(.adjustable))
        #expect(overlay.accessibilityLabel == L10n.cropArea)
        #expect(close(overlay.normalizedCropRect(), .full))

        perform(L10n.moveRight, on: overlay)
        #expect(overlay.normalizedCropRect().origin.x == 0, "a full-size crop has nowhere to move")

        overlay.accessibilityDecrement()
        let shrunk = overlay.normalizedCropRect()
        #expect(shrunk.size.width < 1 && shrunk.size.height < 1)
        #expect(abs(shrunk.size.width - shrunk.size.height) < 0.001, "shrinking keeps the frame's shape")

        #expect(perform(L10n.moveRight, on: overlay))
        #expect(overlay.normalizedCropRect().origin.x > shrunk.origin.x)
        #expect((overlay.accessibilityValue ?? "").contains("%"))

        for _ in 0..<5 { overlay.accessibilityIncrement() }
        #expect(close(overlay.normalizedCropRect(), .full), "growing stops at the whole image")
    }

    @Test("The trimmer offers its start, playhead and end as adjustable elements")
    func trimmer() throws {
        let scrubber = TrimScrubberView(appearance: EditorAppearance())
        let spy = TrimSpy()
        scrubber.delegate = spy
        #expect((scrubber.accessibilityElements ?? []).isEmpty, "nothing to adjust before the clip loads")

        scrubber.frame = CGRect(x: 0, y: 0, width: 300, height: 60)
        scrubber.configure(asset: AVURLAsset(url: fakeVideo), duration: 10)
        scrubber.layoutIfNeeded()
        scrubber.updatePlayhead(time: 2)

        let parts = try #require(scrubber.accessibilityElements as? [UIAccessibilityElement])
        #expect(parts.map(\.accessibilityLabel) == [L10n.trimStart, L10n.playbackPosition, L10n.trimEnd] as [String?])
        #expect(parts.allSatisfy { $0.accessibilityTraits.contains(.adjustable) })

        parts[0].accessibilityIncrement()
        #expect(scrubber.trimStart == 0.5)
        parts[2].accessibilityDecrement()
        #expect(scrubber.trimEnd == 9.5)
        #expect(spy.edges == [.start, .end])
        #expect(spy.commits == 2)

        parts[1].accessibilityIncrement()
        #expect(spy.scrubs == [2.5])
        #expect(!(parts[0].accessibilityValue ?? "").isEmpty)
    }

    @Test("Every sticker gesture has a VoiceOver action that edits and commits")
    func stickerActions() {
        let text = StickerView(overlay: Overlay(content: .text(TextStyle(string: "Hi"))), image: nil)
        let spy = StickerSpy()
        text.delegate = spy
        text.applyLayout(canvasFrame: CGRect(x: 0, y: 0, width: 300, height: 300))
        let names = text.accessibilityCustomActions?.map(\.name) ?? []
        for expected in [L10n.editText, L10n.makeBigger, L10n.makeSmaller, L10n.rotateLeft, L10n.rotateRight,
                         L10n.moveUp, L10n.moveDown, L10n.moveLeft, L10n.moveRight, L10n.delete] {
            #expect(names.contains(expected), "missing \(expected)")
        }

        #expect(perform(L10n.makeBigger, on: text))
        #expect(abs(text.overlay.transform.scale - StickerView.accessibilityScaleStep) < 0.0001)
        perform(L10n.rotateRight, on: text)
        #expect(abs(text.overlay.transform.rotation - StickerView.accessibilityRotationStep) < 0.0001)
        perform(L10n.moveRight, on: text)
        #expect(abs(text.overlay.transform.center.x - (0.5 + StickerView.accessibilityMoveStep)) < 0.0001)
        #expect(spy.commits == 3, "each action is its own history step")

        perform(L10n.editText, on: text)
        perform(L10n.delete, on: text)
        #expect(spy.textEdits == 1)
        #expect(spy.deletes == 1)

        let photo = StickerView(overlay: Overlay(content: .image(ImageRef())), image: samplePhoto())
        let photoActions = photo.accessibilityCustomActions?.map(\.name) ?? []
        #expect(!photoActions.contains(L10n.editText), "only text can be re-edited")
        #expect(photo.accessibilityIgnoresInvertColors)
    }
}

// MARK: - Panels and overlays

@MainActor
@Suite("Accessibility: panels and overlays")
struct PanelAccessibilityTests {

    @Test("Filter thumbnails are named, and the applied one reads as selected")
    func filterBar() {
        let bar = FilterBarView(frame: CGRect(x: 0, y: 0, width: 390, height: 92))
        bar.configure(thumbnails: [(filter: .none, image: samplePhoto()), (filter: .mono, image: samplePhoto())],
                      selected: .mono)
        let buttons = allViews(UIButton.self, in: bar)
        #expect(buttons.map(\.accessibilityLabel) == [L10n.filterName(.none), L10n.filterName(.mono)] as [String?])
        #expect(buttons.count == 2 && !buttons[0].accessibilityTraits.contains(.selected))
        #expect(buttons.count == 2 && buttons[1].accessibilityTraits.contains(.selected))
        let thumbnails = allViews(UIImageView.self, in: bar).filter { $0.image != nil }
        #expect(!thumbnails.isEmpty && thumbnails.allSatisfy(\.accessibilityIgnoresInvertColors))
    }

    @Test("The text editor keeps VoiceOver inside, names every colour, and marks the current one")
    func textEditor() throws {
        let editor = TextEditorViewController(style: TextStyle(string: "Hi"), appearance: EditorAppearance()) { _ in }
        editor.loadViewIfNeeded()
        #expect(editor.view.accessibilityViewIsModal)
        #expect(allViews(UITextView.self, in: editor.view).first?.accessibilityLabel == L10n.textField)

        let buttons = allViews(UIButton.self, in: editor.view)
        let colorNames = [L10n.colorWhite, L10n.colorBlack, L10n.colorRed,
                          L10n.colorYellow, L10n.colorBlue, L10n.colorGreen]
        let swatches = buttons.filter { colorNames.contains($0.accessibilityLabel ?? "") }
        #expect(swatches.count == 6)
        let white = try #require(swatches.first { $0.accessibilityLabel == L10n.colorWhite })
        #expect(white.accessibilityTraits.contains(.selected), "white is the default text colour")
        #expect(swatches.filter { $0.accessibilityTraits.contains(.selected) }.count == 1)

        let red = try #require(swatches.first { $0.accessibilityLabel == L10n.colorRed })
        tap(red)
        #expect(red.accessibilityTraits.contains(.selected))
        #expect(!white.accessibilityTraits.contains(.selected))

        // Drawn at 32 points, touchable across 44.
        let more = try #require(buttons.first { $0.accessibilityLabel == L10n.moreColors })
        red.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        more.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        #expect(red.point(inside: CGPoint(x: -5, y: 16), with: nil))
        #expect(more.point(inside: CGPoint(x: 16, y: 37), with: nil))
        #expect(!red.point(inside: CGPoint(x: -8, y: 16), with: nil))
    }

    @Test("The export panel holds VoiceOver and keeps its progress fresh")
    func exportPanel() {
        let panel = ExportProgressView(appearance: EditorAppearance())
        #expect(panel.accessibilityViewIsModal)
        #expect(allViews(UILabel.self, in: panel).contains { $0.accessibilityTraits.contains(.updatesFrequently) })
    }

    @Test("With Reduce Motion the delete bin fades and fills but never swells")
    func reduceMotionBin() {
        defer { EditorAccessibility.reduceMotionOverride = nil }
        EditorAccessibility.reduceMotionOverride = true
        let calm = StickerTrashView(appearance: EditorAppearance())
        calm.setVisible(true, animated: false)
        calm.setArmed(true, animated: false)
        #expect(calm.transform == .identity)

        EditorAccessibility.reduceMotionOverride = false
        let lively = StickerTrashView(appearance: EditorAppearance())
        lively.setVisible(true, animated: false)
        lively.setArmed(true, animated: false)
        #expect(lively.transform.a > 1.2, "armed, it swells as usual")
    }
}

#endif
