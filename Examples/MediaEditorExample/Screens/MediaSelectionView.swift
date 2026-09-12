//
//  MediaSelectionView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import PhotosUI
import UIKit

/// Loads media sources. Kept UI-free so the view only wires results to the
/// coordinator.
@MainActor
final class MediaSelectionViewModel: ObservableObject {
    @Published var libraryItem: PhotosPickerItem?

    var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func sampleImageSource() -> EditorSource { .photo(SampleImage.make()) }

    func sampleVideoSource() async -> EditorSource? {
        await SampleVideo.make().map { .video($0) }
    }

    func librarySource(from item: PhotosPickerItem?) async -> EditorSource? {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return nil }
        return .photo(image)
    }
}

/// Screen 1: pick a source. No preview — selecting immediately advances the flow.
struct MediaSelectionView: View {
    @EnvironmentObject private var coordinator: AppCoordinator
    @StateObject private var viewModel = MediaSelectionViewModel()
    @State private var showCamera = false

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "wand.and.stars")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .padding(.bottom, 8)
            Text("Choose media to edit")
                .font(.title3.weight(.semibold))
            Text("Pick a source to start.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Button {
                coordinator.select(viewModel.sampleImageSource())
            } label: {
                Label("Use Sample Image", systemImage: "photo.artframe").modifier(WideLabelStyle())
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task {
                    if let source = await viewModel.sampleVideoSource() { coordinator.select(source) }
                }
            } label: {
                Label("Use Sample Video", systemImage: "film").modifier(WideLabelStyle())
            }
            .buttonStyle(.bordered)

            PhotosPicker(selection: $viewModel.libraryItem, matching: .images, photoLibrary: .shared()) {
                Label("Choose from Library", systemImage: "photo.on.rectangle").modifier(WideLabelStyle())
            }
            .buttonStyle(.bordered)

            Button {
                showCamera = true
            } label: {
                Label("Take Photo", systemImage: "camera").modifier(WideLabelStyle())
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.cameraAvailable)

            if !viewModel.cameraAvailable {
                Text("Camera is unavailable on this device.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .navigationTitle("Media Editor")
        .onChange(of: viewModel.libraryItem) { _, newValue in
            Task {
                if let source = await viewModel.librarySource(from: newValue) { coordinator.select(source) }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in coordinator.select(.photo(image)) }
                .ignoresSafeArea()
        }
    }
}
