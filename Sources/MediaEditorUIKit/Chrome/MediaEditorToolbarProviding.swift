//
//  MediaEditorToolbarProviding.swift
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

/// Supplies the editor's tool row, replacing the built-in one entirely.
///
/// Use this when restyling through ``EditorAppearance`` isn't enough — a
/// different layout, your own control types, a segmented picker, labels under
/// the glyphs, whatever the host's design calls for. The editor stays in charge
/// of *behaviour*; the provider only owns the view.
///
/// The contract is small:
///
/// 1. `makeToolbar(for:editor:)` is called once, while the editor's view loads.
///    It receives the actions that survived the configuration and media kind —
///    build a control per action and keep your own references to them.
/// 2. Call `editor.perform(_:)` when the user taps one.
/// 3. `updateToolbar(_:editor:)` fires whenever action state changes (undo
///    became available, the audio toggle flipped). Read `editor.isEnabled(_:)`
///    and `editor.isActive(_:)` and refresh.
///
/// The editor pins the returned view to the bottom safe area with a 12pt inset
/// and lets it size itself, so give it an intrinsic height or its own
/// constraints.
///
/// ```swift
/// final class MyToolbar: NSObject, MediaEditorToolbarProviding {
///     private var buttons: [EditorAction: UIButton] = [:]
///
///     func makeToolbar(for actions: [EditorAction],
///                      editor: MediaEditorViewController) -> UIView? {
///         let stack = UIStackView()
///         for action in actions {
///             let button = UIButton(type: .system)
///             button.setTitle(action.localizedTitle, for: .normal)
///             button.addAction(UIAction { [weak editor] _ in
///                 editor?.perform(action)
///             }, for: .touchUpInside)
///             buttons[action] = button
///             stack.addArrangedSubview(button)
///         }
///         return stack
///     }
///
///     func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController) {
///         for (action, button) in buttons {
///             button.isEnabled = editor.isEnabled(action)
///         }
///     }
/// }
/// ```
@MainActor
public protocol MediaEditorToolbarProviding: AnyObject {

    /// Builds the tool row for `actions`, or returns `nil` to keep the
    /// built-in bar. Called once, as the editor's view loads.
    func makeToolbar(for actions: [EditorAction],
                     editor: MediaEditorViewController) -> UIView?

    /// The editor's action state changed — refresh the controls. Also called
    /// once right after `makeToolbar(for:editor:)` for the initial state.
    func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController)

    /// Whether the editor should hide `toolbar` while a modal tool (crop,
    /// drawing, filters) is on screen. Defaults to `true`, matching the
    /// built-in bar; return `false` to keep a custom row visible throughout.
    func hidesToolbarInToolMode(_ toolbar: UIView) -> Bool
}

public extension MediaEditorToolbarProviding {
    func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController) {}
    func hidesToolbarInToolMode(_ toolbar: UIView) -> Bool { true }
}

#endif
