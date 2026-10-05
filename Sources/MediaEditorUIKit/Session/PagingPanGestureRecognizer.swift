//
//  PagingPanGestureRecognizer.swift
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
import UIKit.UIGestureRecognizerSubclass

/// A one-finger pan over empty canvas. While it pages a session between
/// items it only begins when the finger first moves more sideways than up or
/// down — a mostly vertical drag fails it straight away and is left to
/// whatever else wants it. Over zoomed-in media it pans in any direction.
final class PagingPanGestureRecognizer: UIPanGestureRecognizer {

    /// Whether the drag turns pages — horizontal only, and on its own —
    /// rather than panning zoomed-in media.
    var pagesItems = true

    /// Where the finger went down, in the window.
    private var start: CGPoint?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        maximumNumberOfTouches = 1
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        start = touches.first?.location(in: nil)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Decided before the pan's own movement threshold lets it begin.
        if pagesItems, state == .possible, let start, let location = touches.first?.location(in: nil) {
            let dx = abs(location.x - start.x), dy = abs(location.y - start.y)
            if max(dx, dy) > 4, dy > dx {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }

    override func reset() {
        super.reset()
        start = nil
    }
}

#endif
