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
///
/// Bind it to several items and it edits them as one session, with a
/// thumbnail strip to move between them:
///
/// ```swift
/// MediaEditorView(items: $items, selection: $selectedID,
///                 appearance: .messaging) { result in
///     send(result)
/// } bottomAccessory: { editor in
///     CaptionBar(text: $captions[editor.selectedItemID]) { editor.finish() }
/// }
/// ```
public struct MediaEditorView: UIViewControllerRepresentable {

    /// What the editor works on, and how it reports back.
    fileprivate enum Content {
        case single(item: MediaItem, recipe: EditRecipe, onFinish: (EditorResult) -> Void)
        case session(items: Binding<[MediaEditorItem]>, selection: Binding<UUID>,
                     onAddItems: (() -> Void)?, onFinish: (MediaEditorSessionResult) -> Void)
    }

    private let content: Content
    private let configuration: EditorConfiguration
    private let appearance: EditorAppearance
    private weak var toolbarProvider: (any MediaEditorToolbarProviding)?
    /// Type-erased, so `MediaEditorView` stays a plain type whether or not
    /// it carries an accessory.
    private let bottomAccessory: ((MediaEditorProxy) -> AnyView)?

    // MARK: - Single item

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
        self.content = .single(item: item, recipe: recipe, onFinish: onFinish)
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.bottomAccessory = nil
    }

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
    public init<BottomAccessory: View>(
        item: MediaItem,
        recipe: EditRecipe = .identity,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        onFinish: @escaping (EditorResult) -> Void,
        @ViewBuilder bottomAccessory: @escaping (MediaEditorProxy) -> BottomAccessory
    ) {
        self.content = .single(item: item, recipe: recipe, onFinish: onFinish)
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.bottomAccessory = { AnyView(bottomAccessory($0)) }
    }

    // MARK: - Session

    /// Edits several items as one session, with a thumbnail strip to move
    /// between them.
    ///
    /// The bindings go both ways. The editor writes the selection, removals,
    /// reorders and every committed recipe change back to them; set the
    /// selection or add and remove items yourself and the editor follows.
    ///
    /// - Parameters:
    ///   - items: what to edit, in strip order. Must not start empty.
    ///   - selection: the item on the canvas.
    ///   - configuration: the tools, export settings and finish mode —
    ///     `.recipesOnly` hands back recipes for `EditRenderer` to render
    ///     later.
    ///   - appearance: how the chrome and the strip are styled.
    ///   - toolbarProvider: supplies a replacement tool row. Held weakly.
    ///   - onAddItems: when set, the strip ends with a "+" cell that calls
    ///     this. Present a picker and append what the user picks to `items`.
    ///   - onFinish: called once with the session's result — on send, on
    ///     cancel, or when the user removes every item.
    public init(
        items: Binding<[MediaEditorItem]>,
        selection: Binding<UUID>,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        onAddItems: (() -> Void)? = nil,
        onFinish: @escaping (MediaEditorSessionResult) -> Void
    ) {
        self.content = .session(items: items, selection: selection, onAddItems: onAddItems, onFinish: onFinish)
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.bottomAccessory = nil
    }

    /// Edits several items as one session, with your own bar at the bottom —
    /// see ``init(items:selection:configuration:appearance:toolbarProvider:onAddItems:onFinish:)``.
    /// The strip sits directly above the bar.
    public init<BottomAccessory: View>(
        items: Binding<[MediaEditorItem]>,
        selection: Binding<UUID>,
        configuration: EditorConfiguration = .default,
        appearance: EditorAppearance = .default,
        toolbarProvider: (any MediaEditorToolbarProviding)? = nil,
        onAddItems: (() -> Void)? = nil,
        onFinish: @escaping (MediaEditorSessionResult) -> Void,
        @ViewBuilder bottomAccessory: @escaping (MediaEditorProxy) -> BottomAccessory
    ) {
        self.content = .session(items: items, selection: selection, onAddItems: onAddItems, onFinish: onFinish)
        self.configuration = configuration
        self.appearance = appearance
        self.toolbarProvider = toolbarProvider
        self.bottomAccessory = { AnyView(bottomAccessory($0)) }
    }

    // MARK: - Representable

    public func makeUIViewController(context: Context) -> MediaEditorViewController {
        let coordinator = context.coordinator
        coordinator.content = content

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

        let controller: MediaEditorViewController
        switch content {
        case let .single(item, recipe, _):
            controller = MediaEditorViewController(item: item, recipe: recipe,
                                                   configuration: configuration,
                                                   appearance: appearance,
                                                   toolbarProvider: toolbarProvider,
                                                   bottomAccessory: accessoryView)
            controller.onFinish = { [coordinator] result in
                if case let .single(_, _, onFinish) = coordinator.content { onFinish(result) }
            }
        case let .session(items, selection, onAddItems, _):
            controller = MediaEditorViewController(items: items.wrappedValue,
                                                   selectedItemID: selection.wrappedValue,
                                                   configuration: configuration,
                                                   appearance: appearance,
                                                   toolbarProvider: toolbarProvider,
                                                   bottomAccessory: accessoryView)
            coordinator.connect(controller)
            coordinator.syncAddItems(onAddItems != nil, on: controller)
        }
        if let host = coordinator.accessoryHost {
            controller.addChild(host)
            host.didMove(toParent: controller)
        }
        coordinator.controller = controller
        return controller
    }

    public func updateUIViewController(_ controller: MediaEditorViewController, context: Context) {
        // Keep the coordinator's handlers and bindings current, so results go to
        // the latest SwiftUI state, not a snapshot captured at creation time.
        let coordinator = context.coordinator
        coordinator.content = content
        if case let .session(_, _, onAddItems, _) = content {
            coordinator.syncAddItems(onAddItems != nil, on: controller)
            coordinator.applyHostChanges(to: controller)
        }
        if let bottomAccessory, let host = coordinator.accessoryHost {
            host.rootView = DarkAccessory(content: bottomAccessory(MediaEditorProxy(coordinator: coordinator)))
        }
    }

    /// SwiftUI removed the editor — swapped it out, or dismissed it. Stop its
    /// playback and any export rather than wait for it to deallocate.
    public static func dismantleUIViewController(_ controller: MediaEditorViewController,
                                                 coordinator: Coordinator) {
        controller.tearDown()
    }

    public func makeCoordinator() -> Coordinator { Coordinator(content: content) }

    @MainActor
    public final class Coordinator {
        fileprivate var content: Content
        fileprivate weak var controller: MediaEditorViewController?
        fileprivate var accessoryHost: UIHostingController<DarkAccessory<AnyView>>?
        /// Set while host changes are being applied, so the editor's own
        /// reports of them aren't written back to the bindings.
        private var isApplyingHostChanges = false

        fileprivate init(content: Content) {
            self.content = content
        }

        /// Writes the editor's changes back to the bindings.
        fileprivate func connect(_ controller: MediaEditorViewController) {
            controller.onItemsChange = { [weak self] items in
                guard let self, !isApplyingHostChanges, case let .session(binding, _, _, _) = content else { return }
                binding.wrappedValue = items
            }
            controller.onSelectionChange = { [weak self] id in
                guard let self, !isApplyingHostChanges, case let .session(_, selection, _, _) = content else { return }
                selection.wrappedValue = id
            }
            controller.onRecipeChange = { [weak self] id, recipe in
                guard let self, !isApplyingHostChanges, case let .session(binding, _, _, _) = content,
                      let index = binding.wrappedValue.firstIndex(where: { $0.id == id }) else { return }
                binding.wrappedValue[index].recipe = recipe
            }
            controller.onSessionFinish = { [weak self] result in
                guard let self, case let .session(_, _, _, onFinish) = content else { return }
                onFinish(result)
            }
        }

        /// Shows the strip's "+" cell when the host handles it. The editor holds
        /// a stable closure that calls whichever handler is current, so a
        /// SwiftUI update — every keystroke in a caption — doesn't reload the
        /// strip.
        fileprivate func syncAddItems(_ handled: Bool, on controller: MediaEditorViewController) {
            guard handled != (controller.onAddItems != nil) else { return }
            controller.onAddItems = handled ? { [weak self] in
                guard let self, case let .session(_, _, onAddItems, _) = content else { return }
                onAddItems?()
            } : nil
        }

        /// Brings the editor in line with items and a selection the host set:
        /// removes what the host removed, inserts what it added, and selects
        /// what it selected. The editor's own changes reach the bindings first,
        /// so they arrive here as no-ops.
        fileprivate func applyHostChanges(to controller: MediaEditorViewController) {
            guard case let .session(binding, selection, _, _) = content else { return }
            isApplyingHostChanges = true
            defer { isApplyingHostChanges = false }

            let hostItems = binding.wrappedValue
            let hostIDs = Set(hostItems.map(\.id))
            for item in controller.items where !hostIDs.contains(item.id) {
                controller.remove(item.id)
            }
            for (index, item) in hostItems.enumerated() where !controller.items.contains(where: { $0.id == item.id }) {
                controller.insert([item], at: index)
            }
            let wanted = selection.wrappedValue
            if wanted != controller.selectedItemID, controller.items.contains(where: { $0.id == wanted }) {
                controller.select(wanted)
            }
        }
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
/// `finish()`, for instance. Everything is a no-op, or `nil`, once the editor
/// is gone.
@MainActor
public struct MediaEditorProxy {
    private let resolve: () -> MediaEditorViewController?

    fileprivate init(coordinator: MediaEditorView.Coordinator) {
        resolve = { [weak coordinator] in coordinator?.controller }
    }

    /// The selected item's working recipe — every committed edit, never the
    /// half-applied state of an open tool.
    public var recipe: EditRecipe? { resolve()?.recipe }

    /// Whether a tool — crop, drawing or filters — has the screen.
    public var isToolActive: Bool { resolve()?.isToolActive ?? false }

    /// The session's items, with their current recipes.
    public var items: [MediaEditorItem] { resolve()?.items ?? [] }

    /// The item on the canvas.
    public var selectedItemID: UUID? { resolve()?.selectedItemID }

    /// Shows another item of the session.
    public func select(_ id: UUID) { resolve()?.select(id) }

    /// Removes an item from the session.
    public func remove(_ id: UUID) { resolve()?.remove(id) }

    /// Runs `action` exactly as the editor's own chrome would.
    public func perform(_ action: EditorAction) { resolve()?.perform(action) }

    /// Whether `action` can run right now.
    public func isEnabled(_ action: EditorAction) -> Bool { resolve()?.isEnabled(action) ?? false }

    /// Confirms the edits and ends the session through `onFinish`.
    public func finish() { resolve()?.finish() }

    /// Ends the session with `.cancelled`.
    public func cancel() { resolve()?.cancel() }
}

#endif
