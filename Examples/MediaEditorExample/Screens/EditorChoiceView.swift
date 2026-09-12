//
//  EditorChoiceView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI

/// Screen 2: choose between the package's turnkey editor and a custom editor
/// built on the headless engine. Custom editing is offered for photos only.
struct EditorChoiceView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    let source: EditorSource

    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            card(
                title: "Standard Editor",
                subtitle: "The full-featured turnkey editor from the package.",
                systemImage: "slider.horizontal.3",
                prominent: true
            ) {
                coordinator.openEditor(.standard)
            }

            card(
                title: "Branded Editor",
                subtitle: "The same editor with a custom appearance and a host-supplied toolbar.",
                systemImage: "paintbrush",
                prominent: false
            ) {
                coordinator.openEditor(.branded)
            }

            card(
                title: "Custom Editor",
                subtitle: source.isPhoto
                    ? "A lightweight editor built on the headless engine."
                    : "Custom editing is available for photos only.",
                systemImage: "wrench.and.screwdriver",
                prominent: false,
                disabled: !source.isPhoto
            ) {
                coordinator.openEditor(.custom)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Choose an editor")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func card(title: LocalizedStringKey, subtitle: LocalizedStringKey,
                      systemImage: String, prominent: Bool, disabled: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .frame(width: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(prominent ? Color.accentColor.opacity(0.12) : Color(.secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}
