//
//  VideoDrawingTests.swift
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
import Testing
import MediaEditorCore
@testable import MediaEditorUIKit

private let fakeVideo = URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")

/// A short horizontal stroke in the top-left of a `size` canvas — off-centre on
/// both axes, so a flipped or mirrored render can't pass for a correct one.
@MainActor
private func topLeftStroke(in size: CGSize) -> PKDrawing {
    let ink = PKInk(.pen, color: .red)
    let points = (0...10).map { i -> PKStrokePoint in
        PKStrokePoint(
            location: CGPoint(x: size.width * (0.1 + 0.03 * CGFloat(i)), y: size.height * 0.1),
            timeOffset: TimeInterval(i) * 0.01,
            size: CGSize(width: 10, height: 10),
            opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
    return PKDrawing(strokes: [PKStroke(ink: ink, path: path)])
}

/// Alpha (0...255) of `image` at each point, in top-left-origin pixels.
private func alpha(of image: CGImage, at points: [CGPoint]) -> [UInt8] {
    let width = image.width, height = image.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    bytes.withUnsafeMutableBytes { buffer in
        // A bitmap context's first row of memory is the top of what's drawn.
        let ctx = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    return points.map { bytes[(Int($0.y) * width + Int($0.x)) * 4 + 3] }
}

@MainActor
@Suite("VideoArtworkRenderer")
struct VideoArtworkRendererTests {

    private let renderer = VideoArtworkRenderer()
    private let frame = CGSize(width: 800, height: 400)

    @Test("Nothing to draw means no artwork, so the export skips the overlay pass")
    func nothingToDraw() {
        #expect(renderer.render(drawing: nil, overlays: [], images: [:], size: frame) == nil)
        let blank = DrawingData(data: PKDrawing().dataRepresentation(), canvasWidth: 200, canvasHeight: 100)
        #expect(renderer.render(drawing: blank, overlays: [], images: [:], size: frame) == nil)
    }

    @Test("Strokes scale from the on-screen canvas to the output frame, upright")
    func strokesScaleToOutput() throws {
        // Drawn on a 200×100 on-screen frame, exported at 800×400.
        let drawing = DrawingData(data: topLeftStroke(in: CGSize(width: 200, height: 100)).dataRepresentation(),
                                  canvasWidth: 200, canvasHeight: 100)
        let artwork = try #require(renderer.render(drawing: drawing, overlays: [], images: [:], size: frame))
        #expect(artwork.width == 800)
        #expect(artwork.height == 400)

        let samples = alpha(of: artwork, at: [
            CGPoint(x: 200, y: 40),     // on the stroke: 25% across, 10% down
            CGPoint(x: 200, y: 360),    // where a vertically flipped render would put it
            CGPoint(x: 600, y: 40),     // where a mirrored one would
        ])
        #expect(samples[0] > 200, "the stroke should be solid where it was drawn")
        #expect(samples[1] == 0)
        #expect(samples[2] == 0)
    }

    @Test("Overlays land where they sit on screen, and the rest stays see-through")
    func overlaysPlaced() throws {
        let label = Overlay(content: .text(TextStyle(string: "HELLO", backgroundColor: .black)),
                            transform: NormalizedTransform(center: NormalizedPoint(x: 0.75, y: 0.75)))
        let artwork = try #require(renderer.render(drawing: nil, overlays: [label], images: [:], size: frame))
        let samples = alpha(of: artwork, at: [
            CGPoint(x: 600, y: 300),    // the label's centre
            CGPoint(x: 200, y: 100),    // the opposite quadrant
        ])
        #expect(samples[0] > 250, "the label's backing plate covers its centre")
        #expect(samples[1] == 0, "the video must show through everywhere else")
    }
}

@MainActor
@Suite("Drawing on video in the editor")
struct VideoDrawingEditorTests {

    /// An editor laid out at phone size with a 16:9 video stood in for — a fake
    /// URL never finishes loading.
    private func laidOutEditor() -> MediaEditorViewController {
        let editor = MediaEditorViewController(item: .video(fakeVideo))
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.videoOrientedSize = CGSize(width: 1920, height: 1080)
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        return editor
    }

    private func first<T: UIView>(_ type: T.Type, in root: UIView) -> T? {
        if let match = root as? T { return match }
        for subview in root.subviews {
            if let found = first(type, in: subview) { return found }
        }
        return nil
    }

    private func isHiddenOnScreen(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let candidate = current {
            if candidate.isHidden { return true }
            current = candidate.superview
        }
        return false
    }

    /// The on-screen button titled `title` — other bars keep theirs, hidden.
    private func visibleButton(titled title: String, in root: UIView) -> UIButton? {
        if let button = root as? UIButton, !isHiddenOnScreen(button) {
            let titles = [button.configuration?.title,
                          button.configuration?.attributedTitle.map { String($0.characters) },
                          button.title(for: .normal),
                          button.accessibilityLabel]
            if titles.contains(title) { return button }
        }
        for subview in root.subviews {
            if let found = visibleButton(titled: title, in: subview) { return found }
        }
        return nil
    }

    /// Runs `button`'s touch-up-inside actions directly. `sendActions(for:)`
    /// routes through `UIApplication`, and a package's test bundle has no host
    /// app to provide one.
    private func tap(_ button: UIButton) {
        for target in button.allTargets {
            for action in button.actions(forTarget: target.base, forControlEvent: .touchUpInside) ?? [] {
                _ = (target.base as? NSObject)?.perform(NSSelectorFromString(action), with: button)
            }
        }
    }

    @Test("Drawing parks playback over the video frame, and the strokes stay on the preview")
    func drawOnVideo() throws {
        let editor = laidOutEditor()
        let transport = try #require(first(PlayPauseButton.self, in: editor.view))
        let filmstrip = try #require(first(TrimScrubberView.self, in: editor.view))

        editor.perform(.drawing)
        #expect(editor.isActive(.drawing))
        #expect(transport.isHidden, "the transport would sit on top of the canvas")
        #expect(filmstrip.isHidden)

        let canvas = try #require(first(PKCanvasView.self, in: editor.view))
        let video = try #require(editor.videoDrawingView.superview)
        let videoFrame = editor.view.convert(video.bounds, from: video)
        #expect(abs(canvas.frame.minY - videoFrame.minY) < 0.5
                && abs(canvas.frame.width - videoFrame.width) < 0.5
                && abs(canvas.frame.height - videoFrame.height) < 0.5,
                "strokes are authored against the video frame itself")
        canvas.drawing = topLeftStroke(in: canvas.bounds.size)

        let done = try #require(visibleButton(titled: L10n.done, in: editor.view))
        tap(done)

        #expect(!editor.isActive(.drawing))
        #expect(editor.recipe.drawing != nil)
        #expect(editor.videoDrawingView.image != nil, "the strokes stay over the video once applied")
        #expect(!editor.videoDrawingView.isHidden)
        #expect(!transport.isHidden)
        #expect(!filmstrip.isHidden)

        editor.undo()
        #expect(editor.recipe.drawing == nil)
        #expect(editor.videoDrawingView.image == nil, "undo takes the strokes off the preview too")
    }
}

#endif
