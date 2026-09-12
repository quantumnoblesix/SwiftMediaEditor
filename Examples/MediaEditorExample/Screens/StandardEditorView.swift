//
//  StandardEditorView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import MediaEditor

/// Screen 3a: the package's turnkey editor, embedded as a full-screen step in
/// the flow. Its own Cancel/Done chrome drives the coordinator. Resumes from the
/// session's saved recipe when the user comes back from the result screen.
struct StandardEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let source: EditorSource
    let initialRecipe: EditRecipe

    var body: some View {
        MediaEditorView(
            item: source.mediaItem,
            recipe: initialRecipe,
            configuration: EditorConfiguration(videoExportPreset: .h264HighQuality)
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
