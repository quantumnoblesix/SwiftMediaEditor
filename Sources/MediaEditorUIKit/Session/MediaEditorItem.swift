//
//  MediaEditorItem.swift
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

/// Where an item of an editing session comes from.
public enum MediaSource: Sendable {
    /// An already-decoded photo — what `MediaItem.photo` holds.
    case photo(UIImage)
    /// A photo on disk. It's decoded at full size only while it's the selected
    /// item, and released when it stops being selected; thumbnails are
    /// downsampled straight from the file. Prefer this for large selections:
    /// ten camera photos decoded up front is hundreds of megabytes.
    case photoFile(URL)
    /// A video referenced by file URL.
    case video(URL)
    /// Something the editor can't edit — an animated GIF, a document, audio. It
    /// stays in the session and the strip, but offers no tools: the canvas shows
    /// `preview()` instead, and its recipe stays `.identity`.
    case passthrough(thumbnail: UIImage?, preview: @MainActor @Sendable () -> UIView)

    /// Wraps a single-item `MediaItem`.
    public init(_ item: MediaItem) {
        switch item {
        case let .photo(image): self = .photo(image)
        case let .video(url):   self = .video(url)
        }
    }

    /// Whether this is a photo or a video, or `nil` for passthrough content.
    public var kind: MediaKind? {
        switch self {
        case .photo, .photoFile: return .photo
        case .video:             return .video
        case .passthrough:       return nil
        }
    }

    /// Whether the editor's tools can work on it.
    public var isEditable: Bool { kind != nil }
}

/// One entry of an editing session: the media and the edits made to it.
public struct MediaEditorItem: Identifiable, Sendable {
    public let id: UUID
    public var source: MediaSource
    /// The edits to resume from. The editor keeps it current as the user works
    /// — always a committed recipe, never the half-applied state of an open
    /// tool.
    public var recipe: EditRecipe

    public init(id: UUID = UUID(), source: MediaSource, recipe: EditRecipe = .identity) {
        self.id = id
        self.source = source
        self.recipe = recipe
    }
}

/// What a session hands back for one of its items.
public struct MediaEditorItemResult: Sendable {
    /// The item with its final recipe.
    public let item: MediaEditorItem
    /// The rendered result, or `nil` when there's nothing to render: with
    /// `MediaEditorFinishMode.recipesOnly`, for passthrough items, and for an
    /// identity recipe — upload the original untouched.
    ///
    /// A video output is a file in the temporary directory whose ownership
    /// passes to the host, as with `EditorOutput.video`.
    public let output: EditorOutput?

    public init(item: MediaEditorItem, output: EditorOutput?) {
        self.item = item
        self.output = output
    }
}

/// How a multi-item session ended.
public enum MediaEditorSessionResult: Sendable {
    /// The user dismissed the editor, or removed every item.
    case cancelled
    /// The user confirmed. One result per item, in strip order.
    case saved([MediaEditorItemResult])
}

#endif
