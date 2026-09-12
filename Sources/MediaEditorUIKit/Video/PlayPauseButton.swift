//
//  PlayPauseButton.swift
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

/// The floating play/pause control centered over the video preview.
///
/// It behaves like the native player's transport: the control is only on screen
/// while playback is paused. Starting playback swaps the glyph to "pause" and
/// lets it bloom outward as it fades, leaving the frame unobstructed; pausing
/// springs it back in. While hidden it stops taking touches, so a tap in the
/// same spot falls through to the canvas and pauses instead.
///
/// VoiceOver and Switch Control can't tap the canvas, so while either is running
/// the control stays put through playback. With Reduce Motion on it fades
/// without blooming or springing.
@MainActor
final class PlayPauseButton: UIControl {

    /// The size of the circular control, used for its corner radius too.
    static let diameter: CGFloat = 68

    /// Whether the control reflects a playing (`true`) or paused state.
    private(set) var isPlaying = false

    private let background: UIVisualEffectView
    private let icon = UIImageView()
    private let appearance: EditorAppearance

    init(appearance: EditorAppearance) {
        self.appearance = appearance
        self.background = appearance.makeBarBackground(cornerRadius: PlayPauseButton.diameter / 2)
        super.init(frame: .zero)

        // The glass backing is decoration — touches belong to the control.
        background.isUserInteractionEnabled = false
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        icon.contentMode = .center
        icon.tintColor = appearance.tint
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isAccessibilityElement = true
        setPlaying(false, animated: false)

        for name in EditorAccessibility.assistiveTechnologyNotifications {
            NotificationCenter.default.addObserver(self, selector: #selector(assistiveTechnologyChanged),
                                                   name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.diameter, height: Self.diameter)
    }

    // A subtle press-in, since a plain UIControl gives no highlight of its own.
    override var isHighlighted: Bool {
        didSet {
            guard isHighlighted != oldValue, isUserInteractionEnabled,
                  !EditorAccessibility.prefersReducedMotion else { return }
            UIView.animate(withDuration: 0.12, delay: 0, options: [.allowUserInteraction]) {
                self.transform = self.isHighlighted ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
            }
        }
    }

    /// Reflects the player state: the glyph becomes "pause" while playing, and
    /// the control shows itself only when paused.
    func setPlaying(_ playing: Bool, animated: Bool) {
        isPlaying = playing
        let config = UIImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        icon.image = UIImage(systemName: playing ? "pause.fill" : "play.fill", withConfiguration: config)
        accessibilityLabel = playing ? L10n.pause : L10n.play
        // Activating Play starts the video; VoiceOver shouldn't talk over it.
        accessibilityTraits = playing ? .button : [.button, .startsMediaSession]
        setVisible(shouldBeVisible, animated: animated)
    }

    /// Paused — or playing while an assistive technology needs the control
    /// within reach.
    private var shouldBeVisible: Bool {
        !isPlaying || EditorAccessibility.isAssistiveTechnologyRunning
    }

    /// VoiceOver or Switch Control starting mid-playback brings the control back;
    /// stopping lets it get out of the way again.
    @objc private func assistiveTechnologyChanged() {
        setVisible(shouldBeVisible, animated: false)
    }

    // MARK: - Show / hide

    /// Scale the control grows into as it fades out — reads as the button
    /// releasing the frame rather than merely blinking away.
    private static let hiddenScale: CGFloat = 1.4
    /// Scale the control springs up from when it comes back.
    private static let enteringScale: CGFloat = 0.8

    private func setVisible(_ visible: Bool, animated: Bool) {
        // A hidden control must not swallow the tap that pauses playback.
        isUserInteractionEnabled = visible
        let reduceMotion = EditorAccessibility.prefersReducedMotion

        let settled = {
            self.alpha = visible ? 1 : 0
            self.transform = visible || reduceMotion
                ? .identity
                : CGAffineTransform(scaleX: Self.hiddenScale, y: Self.hiddenScale)
        }

        guard animated else {
            layer.removeAllAnimations()
            settled()
            return
        }

        if reduceMotion {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.allowUserInteraction],
                           animations: settled)
        } else if visible {
            transform = CGAffineTransform(scaleX: Self.enteringScale, y: Self.enteringScale)
            UIView.animate(withDuration: 0.34, delay: 0, usingSpringWithDamping: 0.62,
                           initialSpringVelocity: 0.4, options: [.allowUserInteraction],
                           animations: settled)
        } else {
            UIView.animate(withDuration: 0.3, delay: 0, options: [.curveEaseOut, .allowUserInteraction],
                           animations: settled)
        }
    }
}

#endif
