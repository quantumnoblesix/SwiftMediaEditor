//
//  BrandedEditorView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import MediaEditor

/// Screen 3c: the same turnkey editor, re-skinned by the host.
///
/// Two levels of customization are in play — `EditorAppearance` restyles the
/// chrome the package draws (tints, glyphs, the top bar), and `BrandedToolbar`
/// replaces the tool row outright.
struct BrandedEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let source: EditorSource
    let initialRecipe: EditRecipe

    /// Held by the view so the editor's weak reference stays alive.
    @State private var toolbar = BrandedToolbar()

    private var appearance: EditorAppearance {
        var appearance = EditorAppearance()
        appearance.accent = .systemTeal
        appearance.symbols[.crop] = "crop"
        appearance.symbols[.undo] = "arrow.counterclockwise"
        appearance.symbols[.redo] = "arrow.clockwise"
        return appearance
    }

    var body: some View {
        MediaEditorView(
            item: source.mediaItem,
            recipe: initialRecipe,
            configuration: EditorConfiguration(videoExportPreset: .h264HighQuality),
            appearance: appearance,
            toolbarProvider: toolbar
        ) { result in
            switch result {
            case let .saved(output, recipe):
                coordinator.finishEditing(result: output.asMediaResult, recipe: recipe)
            case .cancelled:
                coordinator.cancelEditing()
            }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }
}
