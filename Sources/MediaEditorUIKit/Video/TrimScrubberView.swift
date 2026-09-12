//
//  TrimScrubberView.swift
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
import AVFoundation

@MainActor
protocol TrimScrubberDelegate: AnyObject {
    /// The trim range changed (live). `start`/`end` are in seconds; `edge` is the
    /// handle being dragged, since moving the in-point and the out-point mean
    /// different things to the host.
    func trimScrubber(_ scrubber: TrimScrubberView, didChangeTrimFrom start: Double, to end: Double,
                      movingEdge edge: TrimScrubberView.Edge)
    /// The trim range change finished — commit to undo history.
    func trimScrubberDidCommit(_ scrubber: TrimScrubberView)
    /// The user scrubbed the playhead to `time` seconds (seek the preview).
    func trimScrubber(_ scrubber: TrimScrubberView, didScrubTo time: Double)
}

/// A filmstrip trim control: thumbnails across the asset, two draggable handles
/// bounding the kept range, and a playhead. Reports trim edits and scrubs.
///
/// The frame and handles take `EditorAppearance.trimColor` (falling back to the
/// accent), and each handle carries a chevron so it reads as something to drag.
@MainActor
final class TrimScrubberView: UIView {

    weak var delegate: TrimScrubberDelegate?

    private(set) var duration: Double = 0
    private(set) var trimStart: Double = 0
    private(set) var trimEnd: Double = 0

    private let filmstrip = UIStackView()
    // The frame and its draggable edges. Internal so tests can check their styling.
    let leftHandle = UIView()
    let rightHandle = UIView()
    let leftHandleIcon = UIImageView()
    let rightHandleIcon = UIImageView()
    let selectionBorder = UIView()
    private let appearance: EditorAppearance
    private let dimLeft = UIView()
    private let dimRight = UIView()
    /// The current-time marker. Internal so tests can check where it lands.
    let playhead = UIView()

    /// Wide enough to carry a chevron. Grabbing doesn't depend on it — the drag
    /// slop around each edge is wider still.
    private let handleWidth: CGFloat = 18
    private let minDuration: Double = 0.5

    private enum Drag { case none, left, right }

    /// Which end of the kept range a handle drag moves.
    enum Edge: Sendable { case start, end }
    private var drag: Drag = .none

    init(appearance: EditorAppearance) {
        self.appearance = appearance
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        clipsToBounds = true
        layer.cornerRadius = 8

        filmstrip.axis = .horizontal
        filmstrip.distribution = .fillEqually
        filmstrip.isUserInteractionEnabled = false
        addSubview(filmstrip)

        for dim in [dimLeft, dimRight] {
            dim.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            dim.isUserInteractionEnabled = false
            addSubview(dim)
        }

        selectionBorder.layer.borderWidth = 3
        // Matches the handles' rounding, so no square border corner peeks out
        // from behind a rounded grip.
        selectionBorder.layer.cornerRadius = 6
        selectionBorder.layer.cornerCurve = .continuous
        selectionBorder.isUserInteractionEnabled = false
        addSubview(selectionBorder)

        // Each handle is rounded on its outer edge only and carries a compact
        // chevron pointing outwards — the grip iOS Photos uses — so the ends of
        // the frame read as draggable rather than as decoration.
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 15, weight: .bold)
        let handles: [(UIView, UIImageView, String, CACornerMask)] = [
            (leftHandle, leftHandleIcon, "chevron.compact.left",
             [.layerMinXMinYCorner, .layerMinXMaxYCorner]),
            (rightHandle, rightHandleIcon, "chevron.compact.right",
             [.layerMaxXMinYCorner, .layerMaxXMaxYCorner]),
        ]
        for (handle, icon, symbol, outerCorners) in handles {
            handle.layer.cornerRadius = 6
            handle.layer.cornerCurve = .continuous
            handle.layer.maskedCorners = outerCorners
            icon.image = UIImage(systemName: symbol, withConfiguration: iconConfig)
            icon.contentMode = .center
            handle.addSubview(icon)
            addSubview(handle)
        }

        applyColors()
        // The border is a CGColor, which doesn't follow light/dark changes on its
        // own — and a host's trim colour may well be dynamic.
        registerForTraitChanges([UITraitUserInterfaceStyle.self], target: self,
                                action: #selector(applyColors))

        playhead.backgroundColor = .white
        playhead.layer.cornerRadius = 1
        playhead.isUserInteractionEnabled = false
        playhead.isHidden = true
        addSubview(playhead)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))
    }

    // MARK: - Colours

    /// The frame and handle colour: the appearance's `trimColor`, else its accent.
    var frameColor: UIColor { appearance.trimColor ?? appearance.accent }

    @objc private func applyColors() {
        let resolvedFrame = frameColor.resolvedColor(with: traitCollection)
        selectionBorder.layer.borderColor = resolvedFrame.cgColor
        leftHandle.backgroundColor = frameColor
        rightHandle.backgroundColor = frameColor

        let iconColor = appearance.trimHandleIconColor
            ?? Self.contrastingForeground(on: resolvedFrame)
        leftHandleIcon.tintColor = iconColor
        rightHandleIcon.tintColor = iconColor
    }

    /// Black on a light background, white on a dark one, by perceived luminance —
    /// so the chevrons stay legible on whatever trim colour a host picks.
    nonisolated static func contrastingForeground(on background: UIColor) -> UIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        guard background.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return .black }
        let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return luminance > 0.5 ? .black : .white
    }

    // MARK: - Configuration

    /// Sets the asset duration and initial trim (full range) and kicks off
    /// asynchronous thumbnail generation.
    func configure(asset: AVAsset, duration: Double) {
        self.duration = max(duration, 0.01)
        self.trimStart = 0
        self.trimEnd = self.duration
        setNeedsLayout()

        let assetBox = UnsafeSendable(asset)
        let total = self.duration
        Task {
            let thumbnails = await Self.makeThumbnails(assetBox: assetBox, duration: total)
            installThumbnails(thumbnails.map(\.value))
        }
    }

    private func installThumbnails(_ images: [UIImage]) {
        for image in images {
            let view = UIImageView(image: image)
            view.contentMode = .scaleAspectFill
            view.clipsToBounds = true
            filmstrip.addArrangedSubview(view)
        }
    }

    func setTrim(start: Double, end: Double) {
        trimStart = max(0, start)
        trimEnd = min(duration, end)
        setNeedsLayout()
    }

    /// Positions the playhead at `time` seconds.
    ///
    /// It's kept between the handles' inner edges. At the very start or end of
    /// the kept range its raw position falls under a handle, and since it's drawn
    /// above them it would paint a white stripe down the grip.
    func updatePlayhead(time: Double) {
        guard duration > 0, bounds.width > 0 else { return }
        playhead.isHidden = false
        let halfWidth: CGFloat = 1
        let lowest = x(for: trimStart) + handleWidth + halfWidth
        let highest = x(for: trimEnd) - handleWidth - halfWidth
        // A range narrower than the two grips has no room; sit between them.
        let centre = highest >= lowest
            ? min(max(x(for: time), lowest), highest)
            : (lowest + highest) / 2
        playhead.frame = CGRect(x: centre - halfWidth, y: 2, width: halfWidth * 2, height: bounds.height - 4)
    }

    // MARK: - Layout

    private func x(for time: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(time / duration) * bounds.width
    }

    private func time(forX x: CGFloat) -> Double {
        guard bounds.width > 0 else { return 0 }
        return Double(max(0, min(x, bounds.width)) / bounds.width) * duration
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        filmstrip.frame = bounds

        let startX = x(for: trimStart)
        let endX = x(for: trimEnd)
        let selection = CGRect(x: startX, y: 0, width: endX - startX, height: bounds.height)
        selectionBorder.frame = selection

        leftHandle.frame = CGRect(x: startX, y: 0, width: handleWidth, height: bounds.height)
        rightHandle.frame = CGRect(x: endX - handleWidth, y: 0, width: handleWidth, height: bounds.height)
        leftHandleIcon.frame = leftHandle.bounds
        rightHandleIcon.frame = rightHandle.bounds

        dimLeft.frame = CGRect(x: 0, y: 0, width: startX, height: bounds.height)
        dimRight.frame = CGRect(x: endX, y: 0, width: bounds.width - endX, height: bounds.height)
    }

    // MARK: - Gestures

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            drag = grabTarget(at: point)
        case .changed:
            switch drag {
            case .left:
                trimStart = min(max(0, time(forX: point.x)), trimEnd - minDuration)
                notifyChange(.start)
            case .right:
                trimEnd = max(min(duration, time(forX: point.x)), trimStart + minDuration)
                notifyChange(.end)
            case .none:
                delegate?.trimScrubber(self, didScrubTo: time(forX: point.x))
            }
            setNeedsLayout()
        case .ended, .cancelled, .failed:
            if drag != .none { delegate?.trimScrubberDidCommit(self) }
            drag = .none
        default:
            break
        }
    }

    private func grabTarget(at point: CGPoint) -> Drag {
        let slop: CGFloat = 22
        if abs(point.x - x(for: trimStart)) <= slop { return .left }
        if abs(point.x - x(for: trimEnd)) <= slop { return .right }
        return .none
    }

    private func notifyChange(_ edge: Edge) {
        delegate?.trimScrubber(self, didChangeTrimFrom: trimStart, to: trimEnd, movingEdge: edge)
    }

    // MARK: - Thumbnails

    /// Generates evenly spaced thumbnails off the main actor. The asset and
    /// resulting images are non-`Sendable`, so they cross the boundary in boxes.
    nonisolated private static func makeThumbnails(
        assetBox: UnsafeSendable<AVAsset>,
        duration: Double,
        count: Int = 8
    ) async -> [UnsafeSendable<UIImage>] {
        let generator = AVAssetImageGenerator(asset: assetBox.value)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 200, height: 200)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        var images: [UnsafeSendable<UIImage>] = []
        for i in 0..<count {
            let seconds = duration * Double(i) / Double(max(1, count - 1))
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            if let cg = try? await generator.image(at: time).image {
                images.append(UnsafeSendable(UIImage(cgImage: cg)))
            }
        }
        return images
    }
}

/// Carries a non-`Sendable` value across a concurrency boundary. Used for the
/// asset and generated thumbnails, which are only read on one side at a time.
struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

#endif
