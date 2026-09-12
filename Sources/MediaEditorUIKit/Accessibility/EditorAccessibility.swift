//
//  EditorAccessibility.swift
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

/// The accessibility settings the editor adapts to, read in one place so tests
/// can stand in for the system.
@MainActor
enum EditorAccessibility {

    /// Replaces the system's Reduce Motion setting while non-`nil`. Tests only.
    static var reduceMotionOverride: Bool?
    /// Replaces "VoiceOver or Switch Control is running" while non-`nil`. Tests only.
    static var assistiveTechnologyOverride: Bool?

    /// Whether scaling and springing should give way to plain fades.
    static var prefersReducedMotion: Bool {
        reduceMotionOverride ?? UIAccessibility.isReduceMotionEnabled
    }

    /// Whether VoiceOver or Switch Control is running. A control that normally
    /// gets out of the way — the play button fading during playback — has to stay
    /// within reach then, because the gesture that brings it back isn't.
    static var isAssistiveTechnologyRunning: Bool {
        assistiveTechnologyOverride
            ?? (UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning)
    }

    /// The notifications that can change `isAssistiveTechnologyRunning`.
    static let assistiveTechnologyNotifications: [Notification.Name] = [
        UIAccessibility.voiceOverStatusDidChangeNotification,
        UIAccessibility.switchControlStatusDidChangeNotification,
    ]

    /// `font` scaled with Dynamic Type for `textStyle`, but no larger than
    /// `maximumPointSize` — the room the chrome around it has. Pair it with
    /// `adjustsFontForContentSizeCategory` so it follows later changes.
    static func scaledFont(_ font: UIFont, textStyle: UIFont.TextStyle, maximumPointSize: CGFloat) -> UIFont {
        UIFontMetrics(forTextStyle: textStyle).scaledFont(for: font, maximumPointSize: maximumPointSize)
    }
}

#endif
