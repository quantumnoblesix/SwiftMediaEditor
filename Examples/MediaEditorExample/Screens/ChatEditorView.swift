//
//  ChatEditorView.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import SwiftUI
import PhotosUI
import MediaEditor

/// Screen 3d: the editor as a chat app's pre-send step, for several items.
///
/// `EditorAppearance.messaging` moves the tools into circular buttons across the
/// top; the session's thumbnail strip moves between the items; the
/// `bottomAccessory` supplies the composer — a caption for each item and a send
/// button. The editor has no Done button of its own here: sending finishes the
/// session, which hands back recipes only (`.recipesOnly`), and the items are
/// then rendered one after another with `EditRenderer` — as a chat app would
/// after closing the screen.
struct ChatEditorView: View {
    @EnvironmentObject private var coordinator: AppCoordinator

    @State private var items: [MediaEditorItem]
    @State private var selection: UUID
    /// A caption for each item, as WhatsApp keeps them.
    @State private var captions: [UUID: String] = [:]
    @State private var isPicking = false
    @State private var picked: [PhotosPickerItem] = []
    /// Set while the items are rendered after sending: "Sending 2 of 4".
    @State private var sendingProgress: (index: Int, count: Int)?

    init(source: EditorSource, initialRecipe: EditRecipe) {
        let first = MediaEditorItem(source: MediaSource(source.mediaItem), recipe: initialRecipe)
        var items = [first]
        // A photo on disk, decoded only while it's selected.
        if let url = Self.writeSample(SampleImage.make(size: CGSize(width: 1200, height: 900))) {
            items.append(MediaEditorItem(source: .photoFile(url)))
        }
        // Something the editor can't edit, kept in the session as it is.
        items.append(MediaEditorItem(source: .passthrough(thumbnail: nil, preview: { Self.documentPreview() })))
        _items = State(initialValue: items)
        _selection = State(initialValue: first.id)
    }

    private var configuration: EditorConfiguration {
        var configuration = EditorConfiguration(videoExportPreset: .h264HighQuality)
        configuration.finishMode = .recipesOnly
        return configuration
    }

    var body: some View {
        MediaEditorView(
            items: $items,
            selection: $selection,
            configuration: configuration,
            appearance: .messaging,
            onAddItems: { isPicking = true }
        ) { result in
            switch result {
            case let .saved(results):
                Task { await send(results) }
            case .cancelled:
                coordinator.cancelEditing()
            }
        } bottomAccessory: { editor in
            CaptionComposer(caption: caption(for: selection)) { editor.finish() }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .photosPicker(isPresented: $isPicking, selection: $picked, matching: .images)
        .onChange(of: picked) { _, newValue in
            Task { await add(newValue) }
        }
        .overlay {
            if let sendingProgress {
                ProgressView("Sending \(sendingProgress.index) of \(sendingProgress.count)")
                    .padding(24)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            // The sample video is generated asynchronously, so it joins late.
            if let url = await SampleVideo.make(), !items.contains(where: { if case .video = $0.source { true } else { false } }) {
                items.insert(MediaEditorItem(source: .video(url)), at: min(1, items.count))
            }
        }
    }

    private func caption(for id: UUID) -> Binding<String> {
        Binding(get: { captions[id, default: ""] }, set: { captions[id] = $0 })
    }

    /// Adds what the user picked to the session; the editor selects the first.
    private func add(_ selection: [PhotosPickerItem]) async {
        var added: [MediaEditorItem] = []
        for item in selection {
            if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                added.append(MediaEditorItem(source: .photo(image)))
            }
        }
        picked = []
        items.append(contentsOf: added)
        if let first = added.first { self.selection = first.id }
    }

    /// Renders the edited items one after another — never in parallel, which
    /// would multiply peak memory — and sends the originals of the rest.
    private func send(_ results: [MediaEditorItemResult]) async {
        let renderer = EditRenderer(configuration: configuration)
        var sent: [MediaResult] = []
        for (index, result) in results.enumerated() {
            sendingProgress = (index + 1, results.count)
            // A real app would upload `captions[result.item.id]` alongside.
            if let output = try? await renderer.render(result.item) {
                sent.append(output.asMediaResult)
            } else if let original = result.item.source.originalResult {
                sent.append(original)                 // nothing to render: send as is
            }
        }
        sendingProgress = nil
        coordinator.finishSending(results: sent)
    }

    /// Stands in for content the editor can't edit — a PDF, say.
    @MainActor
    private static func documentPreview() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "doc.richtext",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 64)))
        icon.tintColor = .white
        let name = UILabel()
        name.text = "Itinerary.pdf"
        name.font = .preferredFont(forTextStyle: .headline)
        name.textColor = .white
        let note = UILabel()
        note.text = "Sent as is"
        note.font = .preferredFont(forTextStyle: .subheadline)
        note.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [icon, name, note])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = UIView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    private static func writeSample(_ image: UIImage) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MediaEditor-sample-\(UUID().uuidString).jpg")
        guard let data = image.jpegData(compressionQuality: 0.9), (try? data.write(to: url)) != nil else { return nil }
        return url
    }
}

private extension MediaSource {
    /// The media as picked, for an item sent without edits.
    var originalResult: MediaResult? {
        switch self {
        case let .photo(image): return .photo(image)
        case let .photoFile(url): return UIImage(contentsOfFile: url.path).map(MediaResult.photo)
        case let .video(url): return .video(url)
        case .passthrough: return nil
        }
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
