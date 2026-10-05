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
///
/// Pass a `bottomAccessory` to pin your own bar under the editor — a caption
/// field and a send button, as in a chat app. It receives a
/// ``MediaEditorProxy`` to drive the editor; call `finish()` from the send
/// button, since the editor drops its own Done button when an accessory is
/// installed:
///
/// ```swift
/// MediaEditorView(item: .photo(image), appearance: .messaging) { result in
///     send(result, caption: caption)
/// } bottomAccessory: { editor in
///     CaptionBar(text: $caption) { editor.finish() }
/// }
/// ```
public struct MediaEditorView<BottomAccessory: View>: UIViewControllerRepresentable {
    private let item: MediaItem
    private let recipe: EditRecipe
    private let configuration: EditorConfiguration
    private let appearance: EditorAppearance
    private weak var toolbarProvider: (any MediaEditorToolbarProviding)?
    private let onFinish: (EditorResult) -> Void
    private let bottomAccessory: ((MediaEditorProxy) -> BottomAccessory)?

    /// - Parameters:
    ///   - item: the photo or video to edit.
    ///   - recipe: a recipe to resume from, or `.identity` for a fresh session.
    ///   - configuration: the tools offered for photos and videos, the crop
    ///     presets, and the export settings.
    ///   - appearance: how the built-in chrome is styled, including where the
    ///     tool row sits.
    ///   - toolbarProvider: supplies a replacement tool row. Held weakly, so
    ///     keep your own reference — a `@State` object on the hosting view.
    ///   - onFinish: called with the result when the user saves or cancels. The
    ///     editor never dismisses itself, so end the presentation here.
    ///   - bottomAccessory: a bar pinned full-width under the editor that rides
    ///     up with the keyboard. Its content is kept above the home indicator
    ///     while a `.background` still fills under it, so only add your own
    ///     padding. It is re-evaluated whenever this view updates, so it can
    ///     read and bind your state.
    public init(
        item: MediaItem,
        recipe: EditRecipe = .identity,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        onFinish: @escaping (EditorResult) -> Void,
        @ViewBuilder bottomAccessory: @escaping (MediaEditorProxy) -> BottomAccessory
    ) {
        self.item = item
        self.recipe = recipe
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.onFinish = onFinish
        self.bottomAccessory = bottomAccessory
    }

    public func makeUIViewController(context: Context) -> MediaEditorViewController {
        let coordinator = context.coordinator
        coordinator.onFinish = onFinish

        var accessoryView: UIView?
        if let bottomAccessory {
            let host = UIHostingController(rootView: DarkAccessory(content: bottomAccessory(MediaEditorProxy(coordinator: coordinator))))
            host.view.backgroundColor = .clear
            // Size to the SwiftUI content. The editor pins the bar to the
            // bottom edge and above the keyboard, so SwiftUI only pads for the
            // home indicator — backgrounds still run under it.
            host.sizingOptions = .intrinsicContentSize
            host.safeAreaRegions = .container
            coordinator.accessoryHost = host
            accessoryView = host.view
        }

        let controller = MediaEditorViewController(item: item, recipe: recipe,
                                                   configuration: configuration,
                                                   appearance: appearance,
                                                   toolbarProvider: toolbarProvider,
                                                   bottomAccessory: accessoryView)
        controller.onFinish = { [coordinator] result in
            coordinator.onFinish(result)
        }
        if let host = coordinator.accessoryHost {
            controller.addChild(host)
            host.didMove(toParent: controller)
        }
        coordinator.controller = controller
        return controller
    }

    public func updateUIViewController(_ controller: MediaEditorViewController, context: Context) {
        // Keep the coordinator's handler current so the result is delivered to the
        // latest SwiftUI state, not a snapshot captured at creation time.
        let coordinator = context.coordinator
        coordinator.onFinish = onFinish
        if let bottomAccessory, let host = coordinator.accessoryHost {
            host.rootView = DarkAccessory(content: bottomAccessory(MediaEditorProxy(coordinator: coordinator)))
        }
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    public final class Coordinator {
        var onFinish: (EditorResult) -> Void = { _ in }
        fileprivate weak var controller: MediaEditorViewController?
        fileprivate var accessoryHost: UIHostingController<DarkAccessory<BottomAccessory>>?
    }
}

public extension MediaEditorView where BottomAccessory == EmptyView {
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
    init(
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
        self.bottomAccessory = nil
    }
}

/// Pins the accessory to the dark scheme the editor always uses. A hosting
/// controller nested under a representable takes its environment from the
/// SwiftUI screen around the editor, not from the editor's UIKit trait
/// override, so a light-mode app would otherwise get a light caption bar.
struct DarkAccessory<Content: View>: View {
    let content: Content

    var body: some View {
        content.environment(\.colorScheme, .dark)
    }
}

/// Drives the editor from a SwiftUI `bottomAccessory` — the send button calls
/// `finish()`, for instance. It does nothing once the editor is gone.
@MainActor
public struct MediaEditorProxy {
    private let resolve: () -> MediaEditorViewController?

    fileprivate init<A: View>(coordinator: MediaEditorView<A>.Coordinator) {
        resolve = { [weak coordinator] in coordinator?.controller }
    }

    /// Runs `action` exactly as the editor's own chrome would.
    public func perform(_ action: EditorAction) { resolve()?.perform(action) }

    /// Whether `action` can run right now.
    public func isEnabled(_ action: EditorAction) -> Bool { resolve()?.isEnabled(action) ?? false }

    /// Renders the edit and ends the session with `.saved` through `onFinish`.
    public func finish() { resolve()?.finish() }

    /// Ends the session with `.cancelled`.
    public func cancel() { resolve()?.cancel() }
}

#endif
