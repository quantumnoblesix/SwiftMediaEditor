//
//  EditorAction.swift
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

/// Everything the editor's chrome can trigger.
///
/// This is the vocabulary a custom toolbar speaks: ask the editor for
/// `toolbarActions`, draw a control per action, and call
/// `MediaEditorViewController.perform(_:)` when one is tapped. Reflect state
/// with `isEnabled(_:)` and `isActive(_:)`.
public enum EditorAction: String, Hashable, Sendable, CaseIterable {
    /// Enters the crop / straighten tool.
    case crop
    /// Rotates 90° clockwise. Only offered in the main row when `crop` is off,
    /// since the crop tool owns rotation otherwise.
    case rotate
    case flipHorizontal
    case flipVertical
    /// Enters the colour-filter tool (photos only).
    case filters
    /// Enters the PencilKit drawing tool.
    case drawing
    /// Adds a text overlay.
    case addText
    /// Adds an image overlay, via the photo picker.
    case addPhoto
    /// Toggles `EditRecipe.removeAudio` (videos with an audio track).
    case toggleAudio
    case undo
    case redo
    /// Ends the session — `cancel` discards, `done` renders and returns.
    case cancel
    case done

    /// The SF Symbol the built-in chrome draws for this action.
    ///
    /// `nil` for the two text actions, which render as titles rather than
    /// glyphs. Override any of these through `EditorAppearance.symbols`.
    public var defaultSymbolName: String? {
        switch self {
        case .crop:           return "crop.rotate"
        case .rotate:         return "rotate.right"
        case .flipHorizontal: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .flipVertical:   return "arrow.up.and.down.righttriangle.up.righttriangle.down"
        case .filters:        return "camera.filters"
        case .drawing:        return "scribble.variable"
        case .addText:        return "textformat"
        case .addPhoto:       return "photo"
        case .toggleAudio:    return "speaker.wave.2.fill"
        case .undo:           return "arrow.uturn.backward"
        case .redo:           return "arrow.uturn.forward"
        case .cancel, .done:  return nil
        }
    }

    /// A localized label, suitable for accessibility or a titled button.
    public var localizedTitle: String {
        switch self {
        case .crop:           return L10n.cropTitle
        case .rotate:         return L10n.rotate
        case .flipHorizontal: return L10n.flipHorizontal
        case .flipVertical:   return L10n.flipVertical
        case .filters:        return L10n.filtersTitle
        case .drawing:        return L10n.drawTitle
        case .addText:        return L10n.addText
        case .addPhoto:       return L10n.addPhoto
        case .toggleAudio:    return L10n.removeAudio
        case .undo:           return L10n.undo
        case .redo:           return L10n.redo
        case .cancel:         return L10n.cancel
        case .done:           return L10n.done
        }
    }
}

/// Where a bar button sits, so custom styling can tell the confirming action
/// apart from the dismissing one.
public enum EditorBarButtonRole: Hashable, Sendable {
    /// Dismisses without committing — "Cancel".
    case dismissing
    /// Commits — "Done" / "Apply". Rendered prominently by default.
    case confirming
}

#endif
