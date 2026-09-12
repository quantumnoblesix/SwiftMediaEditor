//
//  VideoTimelineTests.swift
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

/// Pinned so the decimal separator doesn't depend on the simulator's region.
private let posix = Locale(identifier: "en_US_POSIX")
private let fakeVideo = URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")

@MainActor
@Suite("PlaybackTimeLabel")
struct PlaybackTimeLabelTests {

    @Test("Short sources show tenths, truncated so elapsed never reads ahead")
    func tenthsTruncate() {
        #expect(PlaybackTimeLabel.format(5.7, style: .tenths, locale: posix) == "0:05.7")
        #expect(PlaybackTimeLabel.format(2.49, style: .tenths, locale: posix) == "0:02.4")
        #expect(PlaybackTimeLabel.format(2.9, style: .tenths, locale: posix) == "0:02.9",
                "2.9 × 10 is 28.999… in binary; it must not drop to 2.8")
        #expect(PlaybackTimeLabel.format(0, style: .tenths, locale: posix) == "0:00.0")
    }

    @Test("Longer sources show whole seconds, and hours when needed")
    func longerFormats() {
        #expect(PlaybackTimeLabel.format(125.9, style: .minutesSeconds, locale: posix) == "2:05")
        #expect(PlaybackTimeLabel.format(3725, style: .hoursMinutesSeconds, locale: posix) == "1:02:05")
    }

    @Test("The format is picked from the source's length")
    func styleFromDuration() {
        #expect(PlaybackTimeLabel.Style.forDuration(30) == .tenths)
        #expect(PlaybackTimeLabel.Style.forDuration(300) == .minutesSeconds)
        #expect(PlaybackTimeLabel.Style.forDuration(4000) == .hoursMinutesSeconds)
    }

    @Test("Bad input clamps to zero rather than printing nonsense")
    func clampsBadInput() {
        #expect(PlaybackTimeLabel.format(-3, style: .tenths, locale: posix) == "0:00.0")
        #expect(PlaybackTimeLabel.format(.nan, style: .tenths, locale: posix) == "0:00.0")
    }

    @Test("Hidden until the duration is known, then reads elapsed / total")
    func readout() {
        let label = PlaybackTimeLabel(appearance: EditorAppearance())
        label.locale = posix
        #expect(label.isHidden)

        label.configure(duration: 5.7)
        label.show(current: 2, total: 5.7)
        #expect(!label.isHidden)
        #expect(label.text == "0:02.0 / 0:05.7")
    }
}

@MainActor
@Suite("Video timeline in the editor")
struct VideoTimelineTests {

    /// An editor on a video, with the asset load stood in for — a fake URL never
    /// finishes loading.
    private func editor() throws -> (MediaEditorViewController, TrimScrubberView, PlaybackTimeLabel) {
        let editor = MediaEditorViewController(item: .video(fakeVideo))
        editor.loadViewIfNeeded()
        let scrubber = try #require(editor.view.subviews.compactMap { $0 as? TrimScrubberView }.first)
        let label = try #require(editor.view.subviews.compactMap { $0 as? PlaybackTimeLabel }.first)
        label.locale = posix
        editor.videoDuration = 10
        scrubber.configure(asset: AVURLAsset(url: fakeVideo), duration: 10)
        label.configure(duration: 10)
        return (editor, scrubber, label)
    }

    @Test("Dragging the left handle moves the elapsed time; the right handle, the total")
    func handlesDriveDifferentValues() throws {
        let (editor, scrubber, label) = try editor()
        editor.trimScrubber(scrubber, didChangeTrimFrom: 0, to: 10, movingEdge: .start)
        #expect(label.text == "0:00.0 / 0:10.0")

        editor.trimScrubber(scrubber, didChangeTrimFrom: 2, to: 10, movingEdge: .start)
        #expect(label.text == "0:02.0 / 0:10.0")

        editor.trimScrubber(scrubber, didChangeTrimFrom: 2, to: 6, movingEdge: .end)
        #expect(label.text == "0:02.0 / 0:06.0", "moving the out-point changes the total, not the elapsed time")
    }

    @Test("Pulling the right handle behind the playhead carries the elapsed time with it")
    func endHandleClampsPosition() throws {
        let (editor, scrubber, label) = try editor()
        editor.trimScrubber(scrubber, didChangeTrimFrom: 0, to: 10, movingEdge: .start)
        editor.trimScrubber(scrubber, didScrubTo: 8)
        #expect(label.text == "0:08.0 / 0:10.0")

        editor.trimScrubber(scrubber, didChangeTrimFrom: 0, to: 5, movingEdge: .end)
        #expect(label.text == "0:05.0 / 0:05.0")
    }

    @Test("Scrubbing updates the elapsed time, within the kept range")
    func scrubbingUpdatesElapsed() throws {
        let (editor, scrubber, label) = try editor()
        editor.trimScrubber(scrubber, didChangeTrimFrom: 2, to: 10, movingEdge: .start)
        editor.trimScrubber(scrubber, didChangeTrimFrom: 2, to: 6, movingEdge: .end)

        editor.trimScrubber(scrubber, didScrubTo: 4)
        #expect(label.text == "0:04.0 / 0:06.0")
        editor.trimScrubber(scrubber, didScrubTo: 9)
        #expect(label.text == "0:06.0 / 0:06.0", "past the out-point it stops at the out-point")
        editor.trimScrubber(scrubber, didScrubTo: 0)
        #expect(label.text == "0:02.0 / 0:06.0", "before the in-point it stops at the in-point")
    }

    @Test("Undo and redo bring the handles, loop range and readout back with the trim")
    func undoRestoresTrim() throws {
        let (editor, scrubber, label) = try editor()
        editor.trimScrubber(scrubber, didChangeTrimFrom: 0, to: 10, movingEdge: .end)
        editor.trimScrubber(scrubber, didChangeTrimFrom: 0, to: 6, movingEdge: .end)
        scrubber.setTrim(start: 0, end: 6)          // where the drag left the handles
        editor.trimScrubberDidCommit(scrubber)
        #expect(label.text == "0:00.0 / 0:06.0")

        editor.undo()
        #expect(label.text == "0:00.0 / 0:10.0")
        #expect(scrubber.trimEnd == 10, "the handle must move back too")

        editor.redo()
        #expect(label.text == "0:00.0 / 0:06.0")
        #expect(scrubber.trimEnd == 6)
    }

    // MARK: - Layout

    /// An editor laid out at phone size with a 16:9 video stood in for.
    private func laidOutEditor() throws -> MediaEditorViewController {
        let editor = MediaEditorViewController(item: .video(fakeVideo))
        editor.loadViewIfNeeded()
        editor.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        editor.videoOrientedSize = CGSize(width: 1920, height: 1080)
        editor.view.setNeedsLayout()
        editor.view.layoutIfNeeded()
        editor.view.layoutIfNeeded()     // re-centring the button schedules a second pass
        return editor
    }

    private func firstView(in root: UIView, where match: (UIView) -> Bool) -> UIView? {
        if match(root) { return root }
        for subview in root.subviews {
            if let found = firstView(in: subview, where: match) { return found }
        }
        return nil
    }

    @Test("The play/pause button is centred on the video, not on the preview area")
    func transportCentredOnVideo() throws {
        let editor = try laidOutEditor()
        let button = try #require(editor.view.subviews.first { $0 is PlayPauseButton })
        let video = try #require(firstView(in: editor.view) {
            $0.layer.sublayers?.contains { $0 is AVPlayerLayer } == true
        })
        let previewArea = try #require(video.superview)
        let previewFrame = editor.view.convert(previewArea.bounds, from: previewArea)
        let videoFrame = editor.view.convert(video.bounds, from: video)

        // Otherwise the test would pass with the button on the wrong centre too.
        #expect(abs(previewFrame.midY - videoFrame.midY) > 5,
                "precondition: the video and the preview area must not share a centre")
        #expect(abs(button.frame.midY - videoFrame.midY) < 1)
        #expect(abs(button.frame.midX - videoFrame.midX) < 1)
    }

    @Test("The readout sits between the video and the filmstrip")
    func readoutStacking() throws {
        let editor = try laidOutEditor()
        let label = try #require(editor.view.subviews.first { $0 is PlaybackTimeLabel })
        let filmstrip = try #require(editor.view.subviews.first { $0 is TrimScrubberView })
        let video = try #require(firstView(in: editor.view) {
            $0.layer.sublayers?.contains { $0 is AVPlayerLayer } == true
        })
        let videoFrame = editor.view.convert(video.bounds, from: video)

        #expect(label.frame.maxY <= filmstrip.frame.minY)
        #expect(videoFrame.maxY <= label.frame.minY, "the video must not run under the readout")
    }
}

#endif
