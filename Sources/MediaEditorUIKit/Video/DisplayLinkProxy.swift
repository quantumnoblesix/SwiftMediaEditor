//
//  DisplayLinkProxy.swift
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

/// Forwards `CADisplayLink` callbacks without retaining the editor.
///
/// A display link retains its target, and the run loop it's added to retains
/// the link — so aiming one straight at a view controller keeps that controller
/// (and, for the editor, its `AVPlayer` and the whole decode pipeline) alive for
/// the life of the process, still firing every frame. Invalidating on the way
/// out fixes the common path, but any dismissal that skips that teardown leaks
/// permanently and burns battery at up to 120 Hz on a controller nobody can see.
///
/// This proxy sits in between and holds the target weakly. `onTick` reports
/// whether the target is still there; once it isn't, the link invalidates itself
/// and the run loop lets go, so the leak can't outlive the editor even if
/// teardown never runs.
@MainActor
final class DisplayLinkProxy: NSObject {

    /// Called each frame. Return `false` once the target is gone, which stops
    /// and releases the link.
    var onTick: (() -> Bool)?

    @objc func tick(_ link: CADisplayLink) {
        if onTick?() != true {
            link.invalidate()
        }
    }
}

#endif
