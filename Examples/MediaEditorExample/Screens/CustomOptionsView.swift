//
//  CustomOptionsView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI

/// Shown before the custom editor: a checklist of tools to enable. The editor
/// then renders only the selected ones.
struct CustomOptionsView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @State private var selected: Set<CustomTool> = Set(CustomTool.allCases)

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(CustomTool.allCases) { tool in
                        Button {
                            toggle(tool)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: tool.systemImage)
                                    .frame(width: 28)
                                    .foregroundStyle(.tint)
                                Text(tool.titleKey)
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: selected.contains(tool) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(tool) ? Color.accentColor : Color.secondary)
                                    .imageScale(.large)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Select the tools to enable")
                }
            }

            Button {
                coordinator.startCustomEditor(tools: selected)
            } label: {
                Label("Open Editor", systemImage: "arrow.right.circle").modifier(WideLabelStyle())
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected.isEmpty)
            .padding()
        }
        .navigationTitle("Custom Options")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ tool: CustomTool) {
        if selected.contains(tool) {
            selected.remove(tool)
        } else {
            selected.insert(tool)
        }
    }
}
