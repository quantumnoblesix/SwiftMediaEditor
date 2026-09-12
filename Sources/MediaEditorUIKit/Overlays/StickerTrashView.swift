//
//  StickerTrashView.swift
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

/// The drop target that appears while a sticker is being moved.
///
/// It pops in just above the editor's bottom controls as soon as a drag begins,
/// and arms —
/// swelling with a spring, filling with the destructive colour, and switching to
/// a filled glyph — while the finger is over it. Releasing on an armed bin
/// deletes the sticker.
///
/// Purely visual: it never takes touches, because the sticker's own pan gesture
/// keeps tracking the finger the whole way. VoiceOver users delete through the
/// sticker's own Delete action instead, so the bin stays out of the
/// accessibility tree.
@MainActor
final class StickerTrashView: UIView {

    static let diameter: CGFloat = 60

    /// Whether the finger is over the bin, so releasing would delete.
    private(set) var isArmed = false
    /// Whether the bin is meant to be on screen. `isHidden` lags this while the
    /// exit animation runs.
    private(set) var isShown = false

    /// Resting scale while hidden, so the bin grows into place when it appears.
    private static let hiddenScale: CGFloat = 0.6
    /// How far the bin swells while armed.
    private static let armedScale: CGFloat = 1.3

    private let background: UIVisualEffectView
    private let armedFill = UIView()
    private let icon = UIImageView()

    init(appearance: EditorAppearance) {
        self.background = appearance.makeBarBackground(cornerRadius: Self.diameter / 2)
        super.init(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))

        isUserInteractionEnabled = false
        isAccessibilityElement = false

        for view in [background, armedFill, icon] as [UIView] {
            view.frame = bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        armedFill.backgroundColor = appearance.destructive
        armedFill.layer.cornerRadius = Self.diameter / 2
        armedFill.alpha = 0

        icon.contentMode = .center
        icon.tintColor = appearance.tint
        updateIcon()

        isHidden = true
        applyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Pops the bin in or out. `delay` lets a dropped sticker land before the
    /// bin leaves.
    func setVisible(_ visible: Bool, animated: Bool, delay: TimeInterval = 0) {
        isShown = visible
        if !visible { isArmed = false }
        if visible { isHidden = false }

        guard animated else {
            applyState()
            isHidden = !visible
            updateIcon()
            return
        }
        UIView.animate(withDuration: visible ? 0.35 : 0.22, delay: delay,
                       usingSpringWithDamping: visible ? 0.65 : 1, initialSpringVelocity: 0,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: { self.applyState() },
                       completion: { _ in
                           // A new drag may have summoned it again before this finished.
                           guard !self.isShown else { return }
                           self.isHidden = true
                           self.updateIcon()
                       })
    }

    /// Arms or disarms the bin as the finger crosses it.
    func setArmed(_ armed: Bool, animated: Bool) {
        guard armed != isArmed else { return }
        isArmed = armed
        updateIcon()
        guard animated else { applyState(); return }
        // An underdamped spring gives the swell a small overshoot — the bin
        // visibly reacts rather than just resizing.
        UIView.animate(withDuration: 0.3, delay: 0,
                       usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8,
                       options: [.beginFromCurrentState, .allowUserInteraction],
                       animations: { self.applyState() })
    }

    private func applyState() {
        alpha = isShown ? 1 : 0
        let scale = isShown ? (isArmed ? Self.armedScale : 1) : Self.hiddenScale
        transform = CGAffineTransform(scaleX: scale, y: scale)
        armedFill.alpha = isArmed ? 1 : 0
    }

    private func updateIcon() {
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
        icon.image = UIImage(systemName: isArmed ? "trash.fill" : "trash", withConfiguration: config)
    }
}

#endif
