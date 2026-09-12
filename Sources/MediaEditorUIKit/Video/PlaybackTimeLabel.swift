//
//  PlaybackTimeLabel.swift
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

/// The "elapsed / total" readout above a video's filmstrip.
///
/// Both values are positions on the *source* timeline: elapsed is where the
/// preview is, total is where the kept range ends. That makes the trim handles
/// read naturally — dragging the in-point moves the elapsed time, dragging the
/// out-point moves the total.
///
/// Digits are monospaced so the text doesn't shimmy while it ticks, and one
/// format is picked from the source's length and used for both values, so they
/// line up.
@MainActor
final class PlaybackTimeLabel: UILabel {

    /// How much precision the readout shows.
    enum Style: Equatable, Sendable {
        /// `0:05.7` — for sources under a minute, where whole seconds are too
        /// coarse to trim by.
        case tenths
        /// `2:05`.
        case minutesSeconds
        /// `1:02:05`.
        case hoursMinutesSeconds

        /// The style for a source `seconds` long.
        static func forDuration(_ seconds: Double) -> Style {
            if seconds >= 3600 { return .hoursMinutesSeconds }
            if seconds >= 60 { return .minutesSeconds }
            return .tenths
        }
    }

    private(set) var style: Style = .tenths
    /// Whether the duration is known yet; the label stays hidden until it is.
    private(set) var isConfigured = false
    /// The locale numbers are formatted for — the decimal separator differs by
    /// region. Tests pin it.
    var locale: Locale = .autoupdatingCurrent {
        didSet { render() }
    }

    private var current: Double = 0
    private var total: Double = 0

    init(appearance: EditorAppearance) {
        super.init(frame: .zero)
        font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        textColor = appearance.tint
        textAlignment = .center
        accessibilityTraits.insert(.updatesFrequently)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Picks the format for a source `duration` seconds long and reveals the label.
    func configure(duration: Double) {
        style = .forDuration(duration)
        isConfigured = true
        isHidden = false
        render()
    }

    /// Shows `current` against `total`, both in source seconds.
    func show(current: Double, total: Double) {
        self.current = current
        self.total = total
        render()
    }

    private func render() {
        text = Self.format(current, style: style, locale: locale)
            + " / "
            + Self.format(total, style: style, locale: locale)
    }

    /// Formats `seconds`, truncating to the style's precision rather than
    /// rounding — an elapsed time must never read ahead of where playback is.
    nonisolated static func format(_ seconds: Double, style: Style, locale: Locale) -> String {
        let value = seconds.isFinite ? max(0, seconds) : 0
        // A hair of slack before truncating, so floating-point noise can't drop a
        // digit (2.9 × 10 is 28.999… in binary).
        let slack = 1e-6
        switch style {
        case .tenths:
            let tenths = Int64((value * 10 + slack).rounded(.down))
            return Duration.milliseconds(tenths * 100)
                .formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1, fractionalSecondsLength: 1))
                    .locale(locale))
        case .minutesSeconds:
            return Duration.seconds(Int64((value + slack).rounded(.down)))
                .formatted(.time(pattern: .minuteSecond).locale(locale))
        case .hoursMinutesSeconds:
            return Duration.seconds(Int64((value + slack).rounded(.down)))
                .formatted(.time(pattern: .hourMinuteSecond).locale(locale))
        }
    }
}

#endif
