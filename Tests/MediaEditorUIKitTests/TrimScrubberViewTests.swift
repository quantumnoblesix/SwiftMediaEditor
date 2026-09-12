//
//  TrimScrubberViewTests.swift
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

@MainActor
@Suite("TrimScrubberView")
struct TrimScrubberViewTests {

    private func scrubber(_ appearance: EditorAppearance = EditorAppearance()) -> TrimScrubberView {
        let view = TrimScrubberView(appearance: appearance)
        view.frame = CGRect(x: 0, y: 0, width: 360, height: 60)
        view.layoutIfNeeded()
        return view
    }

    /// Compares colours by resolved components, since system colours are dynamic
    /// and not reliably `==` across instances.
    private func same(_ lhs: UIColor?, _ rhs: UIColor,
                      in traits: UITraitCollection = UITraitCollection(userInterfaceStyle: .dark)) -> Bool {
        guard let lhs else { return false }
        // Separate locals: passing several elements of one array `inout` at once
        // breaks Swift's exclusive-access rule.
        func components(_ color: UIColor) -> [CGFloat] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            color.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [red, green, blue, alpha]
        }
        return zip(components(lhs), components(rhs)).allSatisfy { abs($0 - $1) < 0.01 }
    }

    // MARK: - Colour

    @Test("Out of the box the trimmer keeps its yellow, which is the accent")
    func defaultIsAccent() {
        let view = scrubber()
        #expect(same(view.frameColor, .systemYellow))
        #expect(same(view.leftHandle.backgroundColor, .systemYellow))
    }

    @Test("With no trim colour set, the trimmer follows a recoloured accent")
    func followsAccent() throws {
        var appearance = EditorAppearance()
        appearance.accent = .systemTeal
        let view = scrubber(appearance)

        #expect(same(view.leftHandle.backgroundColor, .systemTeal))
        #expect(same(view.rightHandle.backgroundColor, .systemTeal))
        let border = try #require(view.selectionBorder.layer.borderColor)
        #expect(same(UIColor(cgColor: border), .systemTeal, in: view.traitCollection))
    }

    @Test("An explicit trim colour wins over the accent")
    func explicitTrimColorWins() {
        var appearance = EditorAppearance()
        appearance.accent = .systemTeal
        appearance.trimColor = .systemPink
        let view = scrubber(appearance)
        #expect(same(view.leftHandle.backgroundColor, .systemPink))
        #expect(same(view.rightHandle.backgroundColor, .systemPink))
    }

    // MARK: - Handle icons

    @Test("Each handle carries a chevron, centred in it")
    func handlesCarryChevrons() {
        let view = scrubber()
        for (handle, icon) in [(view.leftHandle, view.leftHandleIcon), (view.rightHandle, view.rightHandleIcon)] {
            #expect(icon.superview === handle)
            #expect(icon.image?.isSymbolImage == true)
            #expect(icon.frame == handle.bounds)
            #expect(icon.contentMode == .center)
        }
    }

    @Test("Chevrons stay legible: dark on a light frame, light on a dark one")
    func chevronsContrastWithFrame() {
        var light = EditorAppearance()
        light.trimColor = .systemYellow
        #expect(same(scrubber(light).leftHandleIcon.tintColor, .black))

        var dark = EditorAppearance()
        dark.trimColor = UIColor(red: 0.05, green: 0.1, blue: 0.35, alpha: 1)
        #expect(same(scrubber(dark).rightHandleIcon.tintColor, .white))

        #expect(same(TrimScrubberView.contrastingForeground(on: .white), .black))
        #expect(same(TrimScrubberView.contrastingForeground(on: .black), .white))
    }

    @Test("An explicit chevron colour wins over the automatic contrast")
    func explicitIconColorWins() {
        var appearance = EditorAppearance()
        appearance.trimColor = .systemYellow
        appearance.trimHandleIconColor = .systemRed
        let view = scrubber(appearance)
        #expect(same(view.leftHandleIcon.tintColor, .systemRed))
        #expect(same(view.rightHandleIcon.tintColor, .systemRed))
    }

    // MARK: - Playhead

    @Test("The playhead stays between the grips instead of drawing over them")
    func playheadStaysBetweenHandles() {
        let view = scrubber()
        view.configure(asset: AVURLAsset(url: URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")),
                       duration: 10)
        view.setTrim(start: 2, end: 8)
        view.layoutIfNeeded()
        let slack: CGFloat = 0.001          // floating-point positions

        view.updatePlayhead(time: 2)        // start of the kept range
        #expect(view.playhead.frame.minX >= view.leftHandle.frame.maxX - slack,
                "at the start it would otherwise sit on the left grip")

        view.updatePlayhead(time: 8)        // end of the kept range
        #expect(view.playhead.frame.maxX <= view.rightHandle.frame.minX + slack,
                "at the end it would otherwise sit on the right grip")

        view.updatePlayhead(time: 5)        // mid-range is where it really is
        #expect(abs(view.playhead.frame.midX - 180) < 1)
    }

    // MARK: - Editor wiring

    @Test("The editor hands its appearance to the trimmer")
    func editorThemesTheTrimmer() throws {
        var appearance = EditorAppearance()
        appearance.trimColor = .systemGreen
        let editor = MediaEditorViewController(
            item: .video(URL(fileURLWithPath: "/tmp/mediaeditor-nonexistent.mov")),
            appearance: appearance)
        editor.loadViewIfNeeded()

        let trimmer = try #require(editor.view.subviews.first { $0 is TrimScrubberView } as? TrimScrubberView)
        #expect(same(trimmer.leftHandle.backgroundColor, .systemGreen))
    }
}

#endif
