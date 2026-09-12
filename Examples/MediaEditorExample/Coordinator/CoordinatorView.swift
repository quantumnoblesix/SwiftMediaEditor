//
//  CoordinatorView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import MediaEditor

/// The app's root. Hosts the `NavigationStack` bound to the coordinator's path
/// and maps each `Route` to its screen. The coordinator and shared session are
/// injected into the environment for all screens.
struct CoordinatorView: View {
    @StateObject private var coordinator = AppCoordinator()

    var body: some View {
        NavigationStack(path: $coordinator.path) {
            MediaSelectionView()
                .navigationDestination(for: Route.self) { route in
                    let session = coordinator.session
                    let source = session.source ?? .photo(SampleImage.make())
                    switch route {
                    case .editorChoice:
                        EditorChoiceView(source: source)
                    case .standardEditor:
                        StandardEditorView(source: source, initialRecipe: session.recipe)
                    case .brandedEditor:
                        BrandedEditorView(source: source, initialRecipe: session.recipe)
                    case .customOptions:
                        CustomOptionsView()
                    case .customEditor:
                        CustomEditorView(source: source, initialRecipe: session.recipe, tools: session.customTools)
                    case .result:
                        ResultView()
                    }
                }
        }
        .environmentObject(coordinator)
        .environmentObject(coordinator.session)
        .onAppear { applyLaunchArguments() }
    }

    /// Demo / screenshot hooks: jump straight into part of the flow.
    private func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard coordinator.path.isEmpty else { return }
        if args.contains("-MEFlowImage") {
            coordinator.select(.photo(SampleImage.make()))
        } else if args.contains("-MEFlowStandard") {
            coordinator.select(.photo(SampleImage.make()))
            if args.contains("-MESeedStickers") {
                coordinator.session.recipe = EditRecipe(overlays: [
                    Overlay(content: .text(TextStyle(string: "AWESOME", fontSizeFraction: 0.12,
                                                     color: RGBAColor(red: 1, green: 0.8, blue: 0))),
                            transform: .init(center: .init(x: 0.5, y: 0.4), scale: 1.1, rotation: 0),
                            zIndex: 0),
                ])
            }
            coordinator.openEditor(.standard)
        } else if args.contains("-MEFlowCustom") {
            // Lands on the tool checklist.
            coordinator.select(.photo(SampleImage.make()))
            coordinator.openEditor(.custom)
        } else if args.contains("-MEFlowCustomEditor") {
            coordinator.select(.photo(SampleImage.make()))
            coordinator.openEditor(.custom)
            coordinator.startCustomEditor(tools: Set(CustomTool.allCases))
        } else if args.contains("-MEFlowCustomMinimal") {
            coordinator.select(.photo(SampleImage.make()))
            coordinator.openEditor(.custom)
            coordinator.startCustomEditor(tools: [.rotate, .reset])
        } else if args.contains("-MEFlowVideo") {
            Task {
                if let url = await SampleVideo.make() {
                    coordinator.select(.video(url))
                    if args.contains("-MEOpenEditor") { coordinator.openEditor(.standard) }
                }
            }
        }
    }
}
