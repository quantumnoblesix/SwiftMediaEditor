//
//  MediaEditorView.swift
//  MediaEditorSwiftUI
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

// The turnkey editor UI is UIKit-based, so it builds for iOS and Mac
// Catalyst. On platforms without UIKit this file compiles to nothing and
// hosts use `MediaEditorCore` directly.
#if canImport(UIKit)

import SwiftUI
import MediaEditorCore
import MediaEditorUIKit

/// SwiftUI entry point for the editor. A thin wrapper over the UIKit
/// `MediaEditorViewController`, so SwiftUI and UIKit hosts share one editor.
///
/// ```swift
/// MediaEditorView(item: .photo(image)) { result in
///     switch result {
///     case let .saved(output, recipe): // persist output + recipe
///     case .cancelled: break
///     }
/// }
/// ```
public struct MediaEditorView: UIViewControllerRepresentable {
    private let item: MediaItem
    private let recipe: EditRecipe
    private let configuration: EditorConfiguration
    private let appearance: EditorAppearance
    private weak var toolbarProvider: (any MediaEditorToolbarProviding)?
    private let onFinish: (EditorResult) -> Void

    /// - Parameters:
    ///   - item: the photo or video to edit.
    ///   - recipe: a recipe to resume from, or `.identity` for a fresh session.
    ///   - configuration: the tools offered for photos and videos, the crop
    ///     presets, and the export settings.
    ///   - appearance: how the built-in chrome is styled.
    ///   - toolbarProvider: supplies a replacement tool row. Held weakly, so
    ///     keep your own reference — a `@State` object on the hosting view.
    ///   - onFinish: called with the result when the user saves or cancels. The
    ///     editor never dismisses itself, so end the presentation here.
    public init(
        item: MediaItem,
        recipe: EditRecipe = .identity,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        onFinish: @escaping (EditorResult) -> Void
    ) {
        self.item = item
        self.recipe = recipe
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.onFinish = onFinish
    }

    public func makeUIViewController(context: Context) -> MediaEditorViewController {
        context.coordinator.onFinish = onFinish
        let controller = MediaEditorViewController(item: item, recipe: recipe,
                                                   configuration: configuration,
                                                   appearance: appearance,
                                                   toolbarProvider: toolbarProvider)
        controller.onFinish = { [coordinator = context.coordinator] result in
            coordinator.onFinish(result)
        }
        return controller
    }

    public func updateUIViewController(_ controller: MediaEditorViewController, context: Context) {
        // Keep the coordinator's handler current so the result is delivered to the
        // latest SwiftUI state, not a snapshot captured at creation time.
        context.coordinator.onFinish = onFinish
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        var onFinish: (EditorResult) -> Void = { _ in }
    }
}

#endif
