//
//  RotationDialView.swift
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

@MainActor
protocol RotationDialDelegate: AnyObject {
    /// The angle changed (live) to `degrees`.
    func rotationDial(_ dial: RotationDialView, didChangeTo degrees: Double)
    /// The drag finished — commit to undo history.
    func rotationDialDidCommit(_ dial: RotationDialView)
}

/// A horizontal ruler for free-angle straightening, à la the iOS Photos crop
/// tool. Drag to rotate; a fixed center pointer marks the current angle.
@MainActor
final class RotationDialView: UIView {

    weak var delegate: RotationDialDelegate?

    private(set) var degrees: Double = 0 {
        didSet {
            setNeedsDisplay()
            label.text = "\(Int(degrees.rounded()))°"
        }
    }

    /// Maximum straighten in each direction.
    let range: Double = 45
    private let pxPerDegree: CGFloat = 6
    private let label = UILabel()
    private var panStartDegrees: Double = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw

        label.text = "0°"
        label.textColor = .systemYellow
        label.font = EditorAccessibility.scaledFont(.systemFont(ofSize: 13, weight: .semibold),
                                                   textStyle: .footnote, maximumPointSize: 15)
        label.adjustsFontForContentSizeCategory = true
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
        ])

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:))))

        // The ruler only answers to dragging, so VoiceOver gets one adjustable
        // element instead: swipe up or down to straighten a degree at a time.
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = L10n.straighten
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setDegrees(_ value: Double) {
        degrees = min(max(value, -range), range)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            panStartDegrees = degrees
        case .changed:
            let dx = gesture.translation(in: self).x
            // Drag the ruler right → the pointer reads a smaller angle.
            degrees = min(max(panStartDegrees - Double(dx / pxPerDegree), -range), range)
            delegate?.rotationDial(self, didChangeTo: degrees)
        case .ended, .cancelled, .failed:
            delegate?.rotationDialDidCommit(self)
        default:
            break
        }
    }

    // MARK: - Accessibility

    override var accessibilityValue: String? {
        get { "\(Int(degrees.rounded()))°" }
        set {}
    }

    override func accessibilityIncrement() { step(up: true) }
    override func accessibilityDecrement() { step(up: false) }

    /// Moves to the next whole degree and commits it, as a finished drag would.
    private func step(up: Bool) {
        let next = up ? degrees.rounded(.down) + 1 : degrees.rounded(.up) - 1
        let target = min(max(next, -range), range)
        guard target != degrees else { return }
        degrees = target
        delegate?.rotationDial(self, didChangeTo: degrees)
        delegate?.rotationDialDidCommit(self)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let center = bounds.midX
        let tickTop = bounds.height * 0.45
        let bottom = bounds.height - 2

        ctx.setLineWidth(1)
        var d = -Int(range)
        while d <= Int(range) {
            let x = center + CGFloat(Double(d) - degrees) * pxPerDegree
            if x >= 0, x <= bounds.width {
                let major = d % 10 == 0
                ctx.setStrokeColor(UIColor.white.withAlphaComponent(major ? 0.9 : 0.4).cgColor)
                let top = major ? tickTop - 6 : tickTop
                ctx.move(to: CGPoint(x: x, y: top))
                ctx.addLine(to: CGPoint(x: x, y: bottom))
                ctx.strokePath()
            }
            d += 1
        }

        // Fixed center pointer.
        ctx.setFillColor(UIColor.systemYellow.cgColor)
        let w: CGFloat = 8
        ctx.move(to: CGPoint(x: center - w / 2, y: tickTop - 8))
        ctx.addLine(to: CGPoint(x: center + w / 2, y: tickTop - 8))
        ctx.addLine(to: CGPoint(x: center, y: tickTop))
        ctx.closePath()
        ctx.fillPath()
    }
}

#endif
