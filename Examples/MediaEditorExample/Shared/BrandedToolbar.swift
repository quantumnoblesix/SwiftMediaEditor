//
//  BrandedToolbar.swift
//  MediaEditorExample
//
//  Created by Emanuele Corona.
//  Copyright © 2026 Emanuele Corona.
//  SPDX-License-Identifier: Apache-2.0
//

import UIKit
import MediaEditor

/// A host-supplied tool row, showing what `MediaEditorToolbarProviding` buys
/// you: a completely different layout — labelled pill buttons on a solid bar
/// instead of the package's floating glass row — while the editor keeps
/// providing the behaviour.
///
/// Note how little there is to it: build a control per action, call
/// `editor.perform(_:)` on tap, and read `editor.isEnabled(_:)` /
/// `isActive(_:)` when asked to refresh.
@MainActor
final class BrandedToolbar: NSObject, MediaEditorToolbarProviding {

    private var buttons: [EditorAction: UIButton] = [:]

    func makeToolbar(for actions: [EditorAction],
                     editor: MediaEditorViewController) -> UIView? {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .center
        row.distribution = .fillProportionally
        row.isLayoutMarginsRelativeArrangement = true
        row.layoutMargins = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.backgroundColor = UIColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 0.95)
        row.layer.cornerRadius = 18
        row.layer.cornerCurve = .continuous
        row.layer.borderWidth = 1
        row.layer.borderColor = UIColor.systemTeal.withAlphaComponent(0.5).cgColor

        for action in actions {
            var config = UIButton.Configuration.plain()
            config.title = title(for: action)
            config.image = action.defaultSymbolName.flatMap { UIImage(systemName: $0) }
            config.imagePlacement = .top
            config.imagePadding = 4
            config.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            config.titleTextAttributesTransformer = .init { attrs in
                var attrs = attrs
                attrs.font = .systemFont(ofSize: 10, weight: .semibold)
                return attrs
            }

            let button = UIButton(configuration: config)
            button.addAction(UIAction { [weak editor] _ in
                editor?.perform(action)
            }, for: .touchUpInside)
            buttons[action] = button
            row.addArrangedSubview(button)
        }
        return row
    }

    func updateToolbar(_ toolbar: UIView, editor: MediaEditorViewController) {
        for (action, button) in buttons {
            button.isEnabled = editor.isEnabled(action)
            button.alpha = button.isEnabled ? 1 : 0.3
            button.tintColor = editor.isActive(action) ? .systemTeal : .white
            button.configuration?.baseForegroundColor = button.tintColor
        }
    }

    private func title(for action: EditorAction) -> String {
        // Shorter labels than the package's own, to keep the pills narrow.
        switch action {
        case .toggleAudio: return "Audio"
        default: return action.localizedTitle
        }
    }
}
