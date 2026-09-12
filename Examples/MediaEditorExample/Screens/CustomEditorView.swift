//
//  CustomEditorView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import CoreImage
import CoreImage.CIFilterBuiltins
import MediaEditor

/// A Core Image color filter applied on top of the geometry render — the "custom"
/// capability the package's turnkey editor doesn't offer.
enum PhotoFilter: CaseIterable, Equatable, Identifiable {
    case none, mono, sepia, invert, vibrant

    var id: Self { self }

    var titleKey: LocalizedStringKey {
        switch self {
        case .none: return "None"
        case .mono: return "Mono"
        case .sepia: return "Sepia"
        case .invert: return "Invert"
        case .vibrant: return "Vibrant"
        }
    }

    /// Applies the filter to a Core Image image, or returns it unchanged.
    func apply(to input: CIImage) -> CIImage {
        switch self {
        case .none:
            return input
        case .mono:
            let f = CIFilter.photoEffectMono(); f.inputImage = input
            return f.outputImage ?? input
        case .sepia:
            let f = CIFilter.sepiaTone(); f.inputImage = input; f.intensity = 0.9
            return f.outputImage ?? input
        case .invert:
            let f = CIFilter.colorInvert(); f.inputImage = input
            return f.outputImage ?? input
        case .vibrant:
            let f = CIFilter.vibrance(); f.inputImage = input; f.amount = 1
            return f.outputImage ?? input
        }
    }
}

/// The undo/redo unit for the custom editor: geometry recipe + color filter.
struct CustomEdit: Equatable {
    var recipe: EditRecipe
    var filter: PhotoFilter
}

/// Screen 3b view model — drives a bespoke photo editor entirely through the
/// package's public headless API (`PhotoRenderer` + `EditRecipe`) plus a Core
/// Image filter, with its own undo/redo via `EditHistory`.
@MainActor
final class CustomEditorViewModel: ObservableObject {
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var filter: PhotoFilter = .none
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    private let renderer = PhotoRenderer()
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let sourceCGImage: CGImage?
    private var history: EditHistory<CustomEdit>
    private var state: CustomEdit { didSet { render() } }

    var recipe: EditRecipe { state.recipe }

    init(image: UIImage, initialRecipe: EditRecipe) {
        sourceCGImage = image.cgImage
        let initial = CustomEdit(recipe: initialRecipe, filter: .none)
        history = EditHistory(initial: initial)
        state = initial
        render()
    }

    // MARK: - Intents

    func rotateLeft() { edit { $0.recipe.rotation.degrees -= 90 } }
    func rotateRight() { edit { $0.recipe.rotation.rotateClockwise90() } }
    func flipHorizontal() { edit { $0.recipe.flip.horizontal.toggle() } }
    func flipVertical() { edit { $0.recipe.flip.vertical.toggle() } }
    func select(filter: PhotoFilter) { edit { $0.filter = filter } }
    func reset() { commit(CustomEdit(recipe: .identity, filter: .none)) }

    func undo() { if let s = history.undo() { restore(s) } }
    func redo() { if let s = history.redo() { restore(s) } }

    func makeResult() -> MediaResult? { previewImage.map { .photo($0) } }

    // MARK: - State plumbing

    private func edit(_ transform: (inout CustomEdit) -> Void) {
        var next = state
        transform(&next)
        commit(next)
    }

    private func commit(_ next: CustomEdit) {
        history.push(next)
        restore(history.current)
    }

    private func restore(_ next: CustomEdit) {
        state = next
        filter = next.filter
        canUndo = history.canUndo
        canRedo = history.canRedo
    }

    private func render() {
        guard let sourceCGImage,
              let geometry = renderer.renderGeometry(cgImage: sourceCGImage, recipe: state.recipe) else { return }
        let filtered = state.filter.apply(to: CIImage(cgImage: geometry))
        if let cg = context.createCGImage(filtered, from: filtered.extent) {
            previewImage = UIImage(cgImage: cg)
        }
    }
}

/// Screen 3b: a custom photo editor with a distinct dark UI, built on the engine.
struct CustomEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var viewModel: CustomEditorViewModel
    private let tools: Set<CustomTool>

    init(source: EditorSource, initialRecipe: EditRecipe, tools: Set<CustomTool>) {
        self.tools = tools
        let image: UIImage = {
            if case let .photo(image) = source { return image }
            return UIImage()
        }()
        _viewModel = StateObject(wrappedValue: CustomEditorViewModel(image: image, initialRecipe: initialRecipe))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            if tools.contains(.filters) { filterStrip }
            toolRow
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
    }

    private var topBar: some View {
        HStack {
            Button("Cancel") { coordinator.cancelEditing() }
                .foregroundStyle(.white)
            Spacer()
            Text("Custom Editor").font(.headline).foregroundStyle(.white)
            Spacer()
            Button("Save") {
                if let result = viewModel.makeResult() {
                    coordinator.finishEditing(result: result, recipe: viewModel.recipe)
                }
            }
            .font(.headline)
            .foregroundStyle(.yellow)
        }
        .padding()
    }

    private var preview: some View {
        Group {
            if let image = viewModel.previewImage {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Color.black
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(PhotoFilter.allCases) { filter in
                    Button {
                        viewModel.select(filter: filter)
                    } label: {
                        Text(filter.titleKey)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(viewModel.filter == filter ? Color.yellow : Color.white.opacity(0.15),
                                        in: Capsule())
                            .foregroundStyle(viewModel.filter == filter ? .black : .white)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    private var toolRow: some View {
        HStack {
            if tools.contains(.rotate) {
                toolButton("rotate.left") { viewModel.rotateLeft() }
                toolButton("rotate.right") { viewModel.rotateRight() }
            }
            if tools.contains(.flip) {
                toolButton("arrow.left.and.right.righttriangle.left.righttriangle.right") { viewModel.flipHorizontal() }
                toolButton("arrow.up.and.down.righttriangle.up.righttriangle.down") { viewModel.flipVertical() }
            }
            if tools.contains(.reset) {
                toolButton("arrow.counterclockwise") { viewModel.reset() }
            }
            // Undo/redo are always available.
            toolButton("arrow.uturn.backward", enabled: viewModel.canUndo) { viewModel.undo() }
            toolButton("arrow.uturn.forward", enabled: viewModel.canRedo) { viewModel.redo() }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }

    private func toolButton(_ symbol: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }
}
