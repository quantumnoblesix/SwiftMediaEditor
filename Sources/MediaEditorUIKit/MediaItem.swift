//
//  MediaItem.swift
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
import MediaEditorCore

/// The media handed to the editor.
public enum MediaItem: Sendable {
    /// A still image to edit.
    case photo(UIImage)
    /// A video referenced by file URL.
    case video(URL)

    /// Whether this is a photo or a video — what `EditorConfiguration` picks
    /// tools by.
    public var kind: MediaKind {
        switch self {
        case .photo: return .photo
        case .video: return .video
        }
    }

    /// Tools that make sense for this media kind.
    public var availableTools: EditorTools { .available(for: kind) }
}

/// The outcome of an editor session, delivered to the completion handler.
public enum EditorResult: Sendable {
    /// The user saved. Carries the rendered output and the recipe that produced
    /// it, so the host can persist the recipe for later re-editing.
    case saved(output: EditorOutput, recipe: EditRecipe)
    /// The user dismissed without saving.
    case cancelled
}

/// The rendered artifact returned on save.
public enum EditorOutput: Sendable {
    case photo(UIImage)
    /// A freshly encoded file in the system temporary directory.
    ///
    /// Ownership passes to the host: move or copy it somewhere durable before
    /// returning from the completion handler. The editor deletes exports that
    /// fail or are cancelled, but never one it has handed over — and the system
    /// may purge the temporary directory at any time.
    case video(URL)
}

#endif
