//
//  AppCoordinator.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import MediaEditor

/// The destinations pushed onto the navigation stack. The media itself lives in
/// `MediaSession`, so routes stay simple `Hashable` values.
enum Route: Hashable {
    case editorChoice
    case standardEditor
    case brandedEditor
    case customOptions
    case customEditor
    case result
}

/// Holds the media being worked on and tracks the modified result across the
/// flow. Injected as an `EnvironmentObject` so every screen reads the same state.
@MainActor
final class MediaSession: ObservableObject {
    @Published var source: EditorSource?
    /// The recipe of the last save, used to resume editing when coming back.
    @Published var recipe: EditRecipe = .identity
    @Published private(set) var result: MediaResult?
    /// How many times the media has been saved — the "kept track of" count.
    @Published private(set) var editCount = 0
    /// Tools the user enabled for the custom editor via the checklist.
    @Published var customTools: Set<CustomTool> = Set(CustomTool.allCases)

    func begin(with source: EditorSource) {
        self.source = source
        recipe = .identity
        result = nil
        editCount = 0
    }

    func record(result: MediaResult, recipe: EditRecipe) {
        self.result = result
        self.recipe = recipe
        editCount += 1
    }
}

/// Owns navigation. Views call intent methods (`select`, `openEditor`, …) and
/// never push routes directly, keeping flow logic in one place.
@MainActor
final class AppCoordinator: ObservableObject {
    @Published var path: [Route] = []
    let session = MediaSession()

    /// Media chosen → go to the editor-choice screen.
    func select(_ source: EditorSource) {
        session.begin(with: source)
        path.append(.editorChoice)
    }

    /// Editor chosen → the standard editor opens directly; the custom editor
    /// first shows a checklist of tools to enable.
    func openEditor(_ kind: EditorKind) {
        switch kind {
        case .standard: path.append(.standardEditor)
        case .branded:  path.append(.brandedEditor)
        case .custom:   path.append(.customOptions)
        }
    }

    /// Tools picked on the checklist → open the custom editor configured with them.
    func startCustomEditor(tools: Set<CustomTool>) {
        session.customTools = tools
        path.append(.customEditor)
    }

    /// Editing saved → record the result and present the final preview.
    func finishEditing(result: MediaResult, recipe: EditRecipe) {
        session.record(result: result, recipe: recipe)
        path.append(.result)
    }

    /// Editor cancelled → pop back to the editor-choice screen.
    func cancelEditing() { pop() }

    /// From the result preview, go back to the editor (state resumes from the
    /// saved recipe).
    func backToEditing() { pop() }

    /// Return all the way to media selection.
    func startOver() { path.removeAll() }

    private func pop() {
        if !path.isEmpty { path.removeLast() }
    }
}
