//
//  ResultView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import AVKit

/// Screen 4: the final preview of the modified media. The nav bar's back button
/// (and the explicit "Back to Edit" button) return to the editor, which resumes
/// from the saved recipe.
struct ResultView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @EnvironmentObject private var session: MediaSession

    var body: some View {
        VStack(spacing: 20) {
            preview
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)

            Text("Edits: \(session.editCount)")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                coordinator.backToEditing()
            } label: {
                Label("Back to Edit", systemImage: "slider.horizontal.3").modifier(WideLabelStyle())
            }
            .buttonStyle(.borderedProminent)

            Button {
                coordinator.startOver()
            } label: {
                Label("Start Over", systemImage: "arrow.counterclockwise").modifier(WideLabelStyle())
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .navigationTitle("Result")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var preview: some View {
        switch session.result {
        case let .photo(image):
            Image(uiImage: image).resizable().scaledToFit()
        case let .video(url):
            VideoPlayer(player: AVPlayer(url: url))
        case nil:
            Color(.secondarySystemBackground)
        }
    }
}
