//
//  MediaModels.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import UIKit
import MediaEditor

/// The media chosen for editing.
enum EditorSource {
    case photo(UIImage)
    case video(URL)

    var isPhoto: Bool {
        if case .photo = self { return true }
        return false
    }

    /// The package's editor input type.
    var mediaItem: MediaItem {
        switch self {
        case let .photo(image): return .photo(image)
        case let .video(url): return .video(url)
        }
    }
}

/// The rendered result of an edit session.
enum MediaResult {
    case photo(UIImage)
    case video(URL)
}

extension EditorOutput {
    /// Bridges the package's output type to the example's result type.
    var asMediaResult: MediaResult {
        switch self {
        case let .photo(image): return .photo(image)
        case let .video(url): return .video(url)
        }
    }
}

/// Which editor the user picked on the choice screen.
enum EditorKind: Hashable {
    case standard
    /// The turnkey editor, re-skinned by the host: a custom appearance plus a
    /// host-supplied tool row.
    case branded
    case custom
}

/// The tools the custom editor can offer. The checklist screen lets the user
/// pick which ones the editor shows.
enum CustomTool: String, CaseIterable, Identifiable, Hashable {
    case rotate
    case flip
    case filters
    case reset

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .rotate: return "Rotate"
        case .flip: return "Flip"
        case .filters: return "Filters"
        case .reset: return "Reset"
        }
    }

    var systemImage: String {
        switch self {
        case .rotate: return "rotate.right"
        case .flip: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .filters: return "camera.filters"
        case .reset: return "arrow.counterclockwise"
        }
    }
}
