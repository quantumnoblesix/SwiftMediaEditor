//
//  ChatEditorView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import MediaEditor

/// Screen 3d: the editor as a chat app's pre-send step.
///
/// `EditorAppearance.messaging` moves the tools into circular buttons across the
/// top, and the `bottomAccessory` supplies the composer: a caption field and a
/// send button. The editor has no Done button of its own here — sending is what
/// finishes the edit.
struct ChatEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let source: EditorSource
    let initialRecipe: EditRecipe

    @State private var caption = ""

    var body: some View {
        MediaEditorView(
            item: source.mediaItem,
            recipe: initialRecipe,
            configuration: EditorConfiguration(videoExportPreset: .h264HighQuality),
            appearance: .messaging
        ) { result in
            switch result {
            case let .saved(output, recipe):
                // A real app would send `caption` along with the media here.
                coordinator.finishEditing(result: output.asMediaResult, recipe: recipe)
            case .cancelled:
                coordinator.cancelEditing()
            }
        } bottomAccessory: { editor in
            CaptionComposer(caption: $caption) { editor.finish() }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }
}

/// A caption field and a send button, on the black band chat apps put under
/// the media.
private struct CaptionComposer: View {
    @Binding var caption: String
    let onSend: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            TextField("Add a caption…", text: $caption, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .foregroundStyle(.white)
                .background(Capsule().strokeBorder(.white.opacity(0.35)))

            Button(action: onSend) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(.green))
            }
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.black)
    }
}
